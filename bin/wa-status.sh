#!/usr/bin/env bash
# Read-only WhatsApp "what's new" poller for the Whatsmarchy Omarchy bar widget.
#
# Reads wacli's local SQLite mirror (wacli.db) with a read-only connection and
# reports which allowed chats have messages the user has not acknowledged in
# this widget yet. It never connects to WhatsApp, never opens session.db, and
# never writes to the wacli store.
#
# Contract: always exits 0, always emits exactly one JSON object on stdout.
#   success -> {"ok":true,"mode":"..","paused":..,"syncRunning":..,
#               "truncated":..,"totalNew":N,"chatCount":N,"topSender":"..",
#               "chats":[..]}
#   failure -> {"ok":false,"error":".."}
#
# A failure must never be rendered as "0 new messages": the widget
# distinguishes ok=false (shows a fault marker) from ok=true with totalNew=0.
#
# Usage: wa-status.sh [previewLimit] [includeChannels:0|1]
set -uo pipefail
umask 077

# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { printf '{"ok":false,"error":"jq is not installed"}\n'; exit 0; }
require_cmd sqlite3

PREVIEW_LIMIT="${1:-4}"
INCLUDE_CHANNELS="${2:-0}"
is_uint "$PREVIEW_LIMIT" || PREVIEW_LIMIT=4
(( PREVIEW_LIMIT > 20 )) && PREVIEW_LIMIT=20
[[ "$INCLUDE_CHANNELS" == "1" ]] || INCLUDE_CHANNELS=0

# Hard cap on rows pulled out of SQLite per poll. Well above any realistic
# backlog the widget would display, low enough that a store with a year of
# group history can't turn one poll into a multi-second query.
SCAN_LIMIT=500

STORE_DIR="$(resolve_store_dir)" \
  || emit_error "wacli store not found (looked in \$WACLI_STORE_DIR, ~/.local/state/wacli, ~/.wacli) — is wacli installed and paired?"
DB="$STORE_DIR/wacli.db"
[[ -r "$DB" ]] || emit_error "cannot read $DB"

assert_config_safe
CONFIG="$(read_config)"
MODE="$(printf '%s' "$CONFIG" | jq -r '.mode')"

# --- is anything actually feeding the database? -----------------------------
# wacli.db only grows while `wacli sync --follow` is running. Without it the
# widget would sit at a permanently stale count and look like it works, so the
# state is reported explicitly and surfaced in the panel.
sync_running=false
HEARTBEAT="$STORE_DIR/HEARTBEAT"
if [[ -f "$HEARTBEAT" ]]; then
  hb_mtime="$(stat -c '%Y' -- "$HEARTBEAT" 2>/dev/null)"
  if is_uint "${hb_mtime:-}" && (( $(date +%s) - hb_mtime < 300 )); then
    sync_running=true
  fi
fi
if [[ "$sync_running" == false ]] && command -v pgrep >/dev/null 2>&1; then
  # -x pins the process name to exactly `wacli` so this can't match the
  # widget's own scripts or an editor with "wacli sync" in a buffer title.
  if pgrep -u "$(id -u)" -a -x wacli 2>/dev/null | grep -q ' sync'; then
    sync_running=true
  fi
fi

# --- first run --------------------------------------------------------------
# A fresh install must not open with several thousand "new" messages from the
# entire synced history. The first poll stamps a watermark at now and reports
# a quiet widget; everything after that timestamp counts normally.
SEEN_ALL="$(printf '%s' "$CONFIG" | jq -r '.seenAll')"
if [[ "$SEEN_ALL" == "0" ]]; then
  now="$(date +%s)"
  CONFIG="$(printf '%s' "$CONFIG" | jq -c --argjson n "$now" '.seenAll = $n')"
  write_config "$CONFIG" || emit_error "cannot write $(config_path)"
  SEEN_ALL="$now"
fi
is_uint "$SEEN_ALL" || emit_error "corrupt watermark in $(config_path)"

if [[ "$MODE" == "paused" ]]; then
  jq -cn --arg m "$MODE" --argjson s "$sync_running" \
    '{ok:true, mode:$m, paused:true, syncRunning:$s, truncated:false, totalNew:0, chatCount:0, topSender:"", chats:[]}'
  exit 0
fi

# Only scan back as far as the oldest watermark in play. Per-chat watermarks
# are applied in the jq pass below; this is purely a cheap SQL-side bound.
MIN_TS="$(printf '%s' "$CONFIG" | jq -r '[.seenAll] + ([.seen[]] // []) | min | floor')"
is_uint "$MIN_TS" || MIN_TS="$SEEN_ALL"

if [[ "$INCLUDE_CHANNELS" == "1" ]]; then
  KIND_FILTER="'dm','group','newsletter'"
else
  KIND_FILTER="'dm','group'"
fi

# MIN_TS / SCAN_LIMIT / PREVIEW_LIMIT are the only interpolated values and each
# has been checked to be a bare unsigned integer; KIND_FILTER is a fixed
# literal chosen from two hard-coded alternatives. No caller-controlled string
# reaches the SQL text.
SQL="
SELECT COALESCE(json_group_array(json_object(
  'chatJid',   chat_jid,
  'chatName',  chat_name,
  'kind',      kind,
  'id',        msg_id,
  'ts',        ts,
  'sender',    sender,
  'text',      body,
  'mediaType', mtype,
  'mime',      mime,
  'filename',  fname,
  'localPath', lpath,
  'mutedUntil', muted_until,
  'chatUnread', chat_unread
)), '[]')
FROM (
  SELECT
    m.chat_jid AS chat_jid,
    m.msg_id   AS msg_id,
    m.ts       AS ts,
    substr(COALESCE(NULLIF(m.sender_name,''), NULLIF(ct.push_name,''), NULLIF(ct.full_name,''),
             NULLIF(ct.first_name,''), ''), 1, $SQL_NAME_MAX)                    AS sender,
    substr(COALESCE(NULLIF(m.text,''), NULLIF(m.media_caption,''), NULLIF(m.display_text,''), ''), 1, $SQL_FIELD_MAX) AS body,
    substr(COALESCE(m.media_type,''), 1, $SQL_NAME_MAX) AS mtype,
    substr(COALESCE(m.mime_type,''),  1, $SQL_NAME_MAX) AS mime,
    substr(COALESCE(m.filename,''),   1, $SQL_PATH_MAX) AS fname,
    substr(COALESCE(m.local_path,''), 1, $SQL_PATH_MAX) AS lpath,
    -- chats.name has proven unreliable for groups — seen holding the chat's
    -- own bare JID (right after a fresh pairing) and, separately, a message
    -- sender's push_name (wacli apparently misattributing it at write time)
    -- instead of the group's real name. groups.name has been correct every
    -- time it has been checked, so for a group it is checked first, ahead of
    -- chats.name rather than only as a fallback; chats.name still leads for
    -- a DM, where there is no groups-table entry to prefer over it.
    substr(COALESCE(NULLIF(g.name,''), NULLIF(NULLIF(c.name,''), m.chat_jid), NULLIF(cc.push_name,''),
             NULLIF(cc.full_name,''), NULLIF(cc.business_name,''), m.chat_jid), 1, $SQL_NAME_MAX) AS chat_name,
    c.kind AS kind,
    c.muted_until AS muted_until,
    c.unread AS chat_unread
  FROM messages m
  JOIN chats c        ON c.jid  = m.chat_jid
  LEFT JOIN contacts ct ON ct.jid = m.sender_jid
  LEFT JOIN contacts cc ON cc.jid = m.chat_jid
  LEFT JOIN groups g    ON g.jid  = m.chat_jid
  WHERE m.from_me = 0
    AND m.ts > $MIN_TS
    AND m.deleted_at IS NULL
    AND m.revoked = 0
    AND m.deleted_for_me = 0
    AND m.payload_purged_at IS NULL
    AND m.reaction_to_id IS NULL
    -- A message stamped in the future would sit permanently above every
    -- watermark and could never be cleared; 5 minutes of slack absorbs
    -- ordinary clock skew between this machine and WhatsApp's servers.
    AND m.ts <= strftime('%s','now') + 300
    AND m.chat_jid <> 'status@broadcast'
    AND c.kind IN ($KIND_FILTER)
  ORDER BY m.ts DESC
  LIMIT $SCAN_LIMIT
);
"

# -readonly opens the connection SQLITE_OPEN_READONLY: the poller physically
# cannot mutate wacli's mirror, even if a future query were wrong. The query
# text goes in over stdin rather than as an argument, so it never appears in
# this process's /proc/<pid>/cmdline while the read is in flight.
# Bounded so this can never hang the poller indefinitely — the bar widget's
# refresh() no-ops while a poll is in flight (one at a time), so a single
# stuck sqlite3 call would permanently wedge every future poll, including a
# manual click on the refresh button, until the shell itself was reloaded.
# The per-field substr() caps above bound each row; this head -c is
# belt-and-braces on the total, in case SCAN_LIMIT rows of near-max-size
# fields ever add up to more than this shell should hold at once — `rows`
# lands in this same command substitution either way, so the cap has to sit
# on the read, not on what's done with it afterwards. pipefail (set at the
# top of this script) still surfaces a real sqlite3/timeout failure through
# `head`, which itself always exits 0.
rows="$(printf '%s' "$SQL" | timeout 8s sqlite3 -readonly -noheader -batch -- "$DB" 2>&1 | head -c "$SQL_OUTPUT_MAX")"
sqlite_status=$?
if (( sqlite_status != 0 )); then
  emit_error "sqlite read failed: ${rows:-unknown error}"
fi
printf '%s' "$rows" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || emit_error "unexpected query result from $DB"

# If the scan hit its own ceiling, the counts below are a floor, not a total.
# Reporting the capped number as if it were exact would understate a real
# backlog silently — the widget renders "500+" instead once this is set.
scanned="$(printf '%s' "$rows" | jq 'length')"
truncated=false
[[ "$scanned" == "$SCAN_LIMIT" ]] && truncated=true

# The config reaches jq through a pipe (--slurpfile on a process substitution),
# never through --argjson. A jq argument lives in /proc/<pid>/cmdline and is
# readable by every other process running as this user for as long as the call
# takes — and this config holds the allow-list and the seen map, which are the
# phone numbers of the people the user talks to. Only non-sensitive scalars
# stay on the command line.
printf '%s' "$rows" | jq -c \
  --slurpfile cfgFile <(printf '%s' "$CONFIG") \
  --argjson limit "$PREVIEW_LIMIT" \
  --argjson syncRunning "$sync_running" \
  --argjson truncated "$truncated" '
  ($cfgFile[0])    as $cfg
  | ($cfg.seenAll) as $seenAll
  | ($cfg.seen)  as $seen
  | ($cfg.mode)  as $mode
  | ($cfg.hideMuted) as $hideMuted
  | ($cfg.allow | map({key: ., value: true}) | from_entries) as $allowSet
  # Per-chat watermark: the chat has its own timestamp once it has been
  # acknowledged, otherwise the global one set on first run.
  #
  # chatUnread (the read/unread flag wacli itself keeps, meant to mirror
  # WhatsApp real-world state) is deliberately NOT used to gate this anymore.
  # It proved unreliable
  # in both directions: stuck at "unread" after a real phone read (the known
  # app-state sync gap from pairing), and — worse — observed flipping an
  # unrelated chat to "read" during a mark-read reconnect cycle, making a
  # different, still-unread conversation vanish from the list with no click
  # on it at all. The local watermark above has been correct every single
  # time throughout extensive testing; chatUnread has not.
  | map(select(.ts > ($seen[.chatJid] // $seenAll)))
  | map(select($mode == "all" or ($allowSet[.chatJid] // false)))
  # muted_until is 0 when audible, -1 for an indefinite mute, or the expiry
  # timestamp for a timed mute. Comparing against now makes expired chats
  # reappear without requiring a config change or rescan.
  | map(select(($hideMuted | not)
               or (.mutedUntil == 0)
               or (.mutedUntil > 0 and .mutedUntil <= now)))
  | group_by(.chatJid)
  | map(
      (. | sort_by(.ts)) as $msgs
      | {
          jid:    $msgs[0].chatJid,
          name:   ($msgs[-1].chatName // $msgs[0].chatJid),
          kind:   ($msgs[0].kind // "dm"),
          count:  ($msgs | length),
          lastTs: ($msgs[-1].ts),
          messages: [ $msgs[-($limit):][] | {
            id:        .id,
            ts:        .ts,
            sender:    .sender,
            text:      .text,
            mediaType: .mediaType,
            mime:      .mime,
            filename:  .filename,
            localPath: .localPath,
            hasMedia:  ((.mediaType // "") | IN("image","video","gif","audio","document","sticker")),
            # wacli stores voice notes and plain audio attachments alike as
            # media_type=audio; only the OGG/Opus mime marks a PTT recording.
            isVoice:   (((.mediaType // "") == "audio")
                        and (((.mime // "") | ascii_downcase) | test("ogg|opus")))
          } ]
        }
    )
  | sort_by(-.lastTs)
  | { ok: true,
      mode: $mode,
      paused: false,
      syncRunning: $syncRunning,
      truncated: $truncated,
      totalNew:  (map(.count) | add // 0),
      chatCount: length,
      topSender: (if length > 0 then .[0].name else "" end),
      chats: . }
' 2>/dev/null || emit_error "could not build status payload"
