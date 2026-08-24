#!/usr/bin/env bash
# Shared helpers for the Whatsmarchy poller and action scripts.
#
# Sourced, never executed. Every function here is expected to be usable from a
# script running under `set -uo pipefail` with `umask 077`.

# The validators below use ranges like [A-Za-z0-9]. Under a UTF-8 locale those
# collate loosely — fr_FR.UTF-8 matches "é", "İ" and friends inside [A-Za-z].
# Nothing dangerous collates in (no quote, slash, or whitespace does), but these
# patterns are meant to be byte-exact, so the collation is pinned rather than
# left to whatever locale the desktop session happens to carry.
export LC_ALL=C

# --- JSON output ------------------------------------------------------------
# Both entry points share one contract: exit 0, print exactly one JSON object.
# A widget that has to distinguish "script crashed" from "no messages" on
# stderr is a widget that will eventually render a wrong count.

json_string() {
  # Encode "$1" as a JSON string. Falls back to a quoted constant rather than
  # emitting invalid JSON if jq is somehow missing mid-run.
  printf '%s' "${1-}" | jq -Rs . 2>/dev/null || printf '"internal"'
}

emit_error() {
  printf '{"ok":false,"error":%s}\n' "$(json_string "${1-unknown error}")"
  exit 0
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || emit_error "$1 is not installed"
}

# --- wacli store ------------------------------------------------------------
# Layout (docs/install.md): $WACLI_STORE_DIR, else ~/.local/state/wacli on
# Linux, else the legacy ~/.wacli. `wacli.db` holds messages/chats/contacts;
# `session.db` holds the WhatsApp keys and is deliberately never touched here.

resolve_store_dir() {
  local candidate
  for candidate in "${WACLI_STORE_DIR:-}" "$HOME/.local/state/wacli" "$HOME/.wacli"; do
    [[ -n "$candidate" ]] || continue
    [[ -f "$candidate/wacli.db" ]] || continue
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

# --- plugin config ----------------------------------------------------------
# Lives outside the plugin folder so a `git pull` on the plugin can never
# clobber it, and so the repo can never accidentally carry a contact list.
#
# Shape:
#   { "mode": "paused|all|custom",
#     "allow": ["<jid>", ...],
#     "hideMuted": false,
#     "seen":  { "<jid>": <unix seconds> },
#     "seenAll": <unix seconds> }

config_path() {
  printf '%s' "${WHATSMARCHY_CONFIG:-$HOME/.config/omarchy/whatsmarchy/config.json}"
}

config_defaults='{"mode":"all","allow":[],"hideMuted":false,"seen":{},"seenAll":0}'

# --- size caps ----------------------------------------------------------
# Everything below ultimately comes from either a hand-editable config file
# or WhatsApp-controlled data (message text, contact/business names,
# filenames) relayed through wacli's SQLite mirror. None of those sources is
# bounded by anything on this machine — a corrupted config or a single
# oversized field from a chat could otherwise be loaded whole into a bash
# command substitution (which has no size limit of its own) and exhaust the
# poller or wedge the long-lived shell. These are generous ceilings for any
# real preview/list use, not a tuned "legitimate maximum".
CONFIG_MAX_BYTES=262144    # 256 KiB cap on how much of config.json is ever read
SQL_FIELD_MAX=4000         # per-field cap for message/body text pulled from SQLite
SQL_NAME_MAX=256           # per-field cap for names/labels (sender, chat, contact)
SQL_PATH_MAX=512           # per-field cap for filenames/paths/mime strings
SQL_OUTPUT_MAX=4194304     # 4 MiB cap on total sqlite3 stdout, belt-and-braces on top
                           # of the per-field caps above and each query's row LIMIT

# --- trusted read of the config file ----------------------------------------
# This file decides which chats may notify and which JIDs later reach a `wacli`
# argument list, so "is this really our config?" has to be answered about the
# *bytes we are about to parse*, not about a path we looked at beforehand.
#
# Every path-based answer is a guess with an expiry date. `[[ -L $path ]]`,
# `stat -c '%a %U' $path`, even `[[ -f /dev/fd/$fd ]]` after a plain
# `exec {fd}<$path` — each of those resolves the path a second time, or
# describes only where the resolution *landed*. In a same-user threat model
# (another process running as this user: a compromised app, a careless script,
# anything that shares the session bus) the path can be replaced between any
# two of those steps. A plain open() also follows a trailing symlink, so a
# replacement symlink can quietly substitute a different regular file — one
# that passes every "is it a regular file, owned by you, mode 600" test,
# because it genuinely is all three; it simply isn't *this plugin's* config.
#
# So the whole decision is taken on one file descriptor:
#
#   O_NOFOLLOW  — the kernel refuses the open with ELOOP if the final path
#                 component is a symlink. Not an lstat() beforehand (that is
#                 the same two-lookup race in a different costume): the flag
#                 is part of the open() the file is actually read from.
#   O_NONBLOCK  — a FIFO or a device left at that path opens instead of
#                 parking this process in the kernel forever, so the type
#                 check below gets to run and reject it.
#   fstat(fd)   — owner, mode, size and type of the object behind *this*
#                 descriptor. Nothing is re-resolved, so there is no window
#                 left between the check and the read.
#   read(fd)    — the same descriptor, bounded by CONFIG_MAX_BYTES.
#
# Bash cannot pass open flags on a redirection, hence the interpreter. python3
# is used when present and perl otherwise (Arch ships perl in `base`); the two
# implementations enforce byte-for-byte the same rules, and either one is
# still wrapped in `timeout` as a backstop.
#
# Exit status: 0 = trustworthy bytes on stdout; 3 = no config file at all (a
# fresh install, not a fault); anything else = refused, with a one-line human
# reason on stderr and nothing on stdout.
config_slurp() {
  local path
  path="$(config_path)"
  if command -v python3 >/dev/null 2>&1; then
    timeout 2s python3 -c '
import errno, os, stat, sys
path, cap = sys.argv[1], int(sys.argv[2])
def refuse(msg):
    sys.stderr.write(msg + "\n")
    raise SystemExit(1)
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
except OSError as e:
    if e.errno == errno.ENOENT:
        raise SystemExit(3)
    if e.errno == errno.ELOOP:
        refuse("it is a symlink")
    refuse("cannot open it (" + errno.errorcode.get(e.errno, str(e.errno)) + ")")
buf = b""
try:
    st = os.fstat(fd)
    if not stat.S_ISREG(st.st_mode):
        refuse("it is not a regular file")
    if st.st_uid != os.getuid():
        refuse("it is owned by uid " + str(st.st_uid) + ", not by you")
    if st.st_mode & 0o077:
        refuse("it is readable or writable by group/others - chmod 600 it")
    if st.st_size > cap:
        refuse("it is larger than " + str(cap) + " bytes")
    # One byte past the cap is enough to tell "exactly at the ceiling" from
    # "grew while we were reading it"; a truncated prefix is never used.
    while len(buf) <= cap:
        chunk = os.read(fd, 65536)
        if not chunk:
            break
        buf += chunk
finally:
    os.close(fd)
if len(buf) > cap:
    refuse("it is larger than " + str(cap) + " bytes")
sys.stdout.buffer.write(buf)
' "$path" "$CONFIG_MAX_BYTES"
  elif command -v perl >/dev/null 2>&1; then
    timeout 2s perl -e '
use strict; use warnings; use Errno;
use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK);
sub refuse { print STDERR $_[0], "\n"; exit 1 }
my ($path, $cap) = @ARGV;
my $fh;
unless (sysopen($fh, $path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)) {
  exit 3 if $!{ENOENT};
  refuse("it is a symlink") if $!{ELOOP};
  refuse("cannot open it ($!)");
}
my @st = stat($fh) or refuse("cannot fstat it");
refuse("it is not a regular file") unless ($st[2] & 0170000) == 0100000;
refuse("it is owned by uid $st[4], not by you") if $st[4] != $<;
refuse("it is readable or writable by group/others - chmod 600 it") if $st[2] & 0077;
refuse("it is larger than $cap bytes") if $st[7] > $cap;
my $buf = "";
while (length($buf) <= $cap) {
  my $n = sysread($fh, $buf, 65536, length($buf));
  refuse("read failed ($!)") unless defined $n;
  last if $n == 0;
}
refuse("it is larger than $cap bytes") if length($buf) > $cap;
binmode(STDOUT);
print STDOUT $buf;
' -- "$path" "$CONFIG_MAX_BYTES"
  else
    printf 'no python3 or perl available to open it without following symlinks\n' >&2
    return 1
  fi
}

# Called once from the *main shell* of each entry point, before any read_config.
#
# This is the friendly half of the check, not the authoritative one: it runs
# the exact same fd-based verification as read_config (same function, same
# rules) purely so that a persistently wrong config — a symlink someone left
# behind, a file restored from a backup as root, a stray `chmod 644` — is
# reported as `{"ok":false,"error":"…"}` the user can act on, instead of the
# widget silently falling back to defaults and notifying for every chat.
#
# It cannot be what makes the read safe: it is a separate invocation, and
# anything it observed could be replaced before read_config runs. What makes
# the read safe is that read_config re-verifies through the descriptor it
# reads from. Deliberately not folded into read_config either — that runs
# inside a command substitution, where an emit_error would only kill the
# subshell and its `{"ok":false}` JSON would be captured as if it were the
# config. A refusal has to reach stdout as the script's whole answer.
assert_config_safe() {
  local path reason rc
  path="$(config_path)"
  # Purely to keep a fresh install quiet. Not a security check (nothing is
  # decided from it), so its own raciness costs nothing: config_slurp reports
  # an absent file the same way, and read_config re-checks regardless.
  [[ -e "$path" || -L "$path" ]] || return 0
  # stderr carries the reason, stdout (the file's contents) is discarded — this
  # call exists only for its verdict.
  reason="$(config_slurp 2>&1 >/dev/null)"
  rc=$?
  case "$rc" in
    0 | 3) return 0 ;;
    124)   emit_error "config file could not be read within 2s: $path" ;;
    *)     emit_error "refusing to use the config file — ${reason:-unreadable}: $path" ;;
  esac
}

read_config() {
  # Always prints a complete, well-typed config object: a hand-edited file
  # with a missing key or a wrong type must degrade to the default for that
  # key rather than propagate `null` into the widget's counting logic. A file
  # this plugin cannot vouch for — absent, oversized, wrong owner, wrong mode,
  # a symlink, a FIFO — is treated exactly like an unreadable one and the
  # defaults are used, because a caller inside a command substitution has no
  # way to raise an error (see assert_config_safe above, which is what makes
  # the ordinary cases loud).
  #
  # config_slurp is the single place the trust decision is made, and it makes
  # it on the descriptor it reads from: O_NOFOLLOW + fstat, no second path
  # lookup anywhere in between. See its header for why nothing path-based is
  # sufficient here.
  local raw
  raw="$(config_slurp 2>/dev/null)" || raw=""
  printf '%s' "${raw:-$config_defaults}" | jq -c --argjson d "$config_defaults" '
    (if type == "object" then . else {} end) as $c
    | {
        mode:    (if ($c.mode | type) == "string" and (["paused","all","custom"] | index($c.mode)) != null
                  then $c.mode else $d.mode end),
        allow:   (if ($c.allow | type) == "array" then [$c.allow[] | select(type == "string")] else [] end),
        hideMuted: (if ($c.hideMuted | type) == "boolean" then $c.hideMuted else false end),
        seen:    (if ($c.seen | type) == "object" then ($c.seen | with_entries(select(.value | type == "number"))) else {} end),
        seenAll: (if ($c.seenAll | type) == "number" then $c.seenAll else 0 end)
      }
  ' 2>/dev/null || printf '%s' "$config_defaults"
}

write_config() {
  # Atomic replace via a same-directory temp file, so a crash mid-write can
  # never leave a half-written config that read_config would silently reset
  # (which would drop the whole allow-list and start notifying for everyone).
  # The `mv` at the end is a rename(2), which replaces a symlink sitting at the
  # destination instead of writing through it — so a swapped config path can
  # never redirect this write into some other file the user owns.
  local path dir tmp payload="$1"
  path="$(config_path)"
  dir="$(dirname -- "$path")"
  # `mkdir -p` is perfectly happy with a symlink to a directory, and the chmod
  # right below — plus every config written afterwards — would then land on its
  # target. Same refusal ensure_voice_dir makes in wa-ctl.sh, for the same
  # reason. This one is defence in depth rather than a guarantee: like any
  # path-based test it can be raced, and the directory components above the
  # file cannot be pinned from a shell at all. What actually protects the read
  # side is that read_config re-verifies owner and mode on the descriptor it
  # reads from, wherever that descriptor ended up coming from.
  [[ -L "$dir" ]] && return 1
  mkdir -p -- "$dir" 2>/dev/null || return 1
  chmod 700 -- "$dir" 2>/dev/null
  printf '%s' "$payload" | jq -e . >/dev/null 2>&1 || return 1
  tmp="$(mktemp "$dir/config.XXXXXX")" || return 1
  chmod 600 -- "$tmp" 2>/dev/null
  printf '%s\n' "$payload" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$path" || { rm -f -- "$tmp"; return 1; }
  return 0
}

# --- validation -------------------------------------------------------------
# Everything that reaches an `exec` argument is checked against an allow-list
# pattern first. These values originate in a QML click handler, but they are
# derived from WhatsApp-controlled data (JIDs, message IDs, file names), so
# they are treated as untrusted input throughout.

is_jid() {
  # user@s.whatsapp.net, 1203630...@g.us, ...@lid, ...@newsletter, ...@broadcast
  [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}@[a-z][a-z.]{0,31}$ ]]
}

is_msg_id() {
  # WhatsApp message IDs are hex-ish/base32-ish; keep it strict and printable.
  # The first character may not be "-": `wacli media download --id -o` would
  # otherwise hand a flag-shaped value to a Go flag parser. spf13/pflag happens
  # to consume it as a value today, but that is upstream's choice, not a
  # guarantee. "=" is allowed because base64-ish IDs really do carry padding.
  [[ "${1-}" =~ ^[A-Za-z0-9_][A-Za-z0-9_=-]{0,127}$ ]]
}

is_uint() {
  [[ "${1-}" =~ ^[0-9]{1,19}$ ]]
}

is_rec_token() {
  # Handle for an outgoing voice recording this plugin made itself. The panel
  # never learns the file's path — it gets this token back and hands it to
  # play/send/discard, which rebuild the path from a fixed directory. A token
  # that cannot express a separator or a dot cannot escape that directory, so
  # "send this recording" can never become "send this arbitrary file".
  [[ "${1-}" =~ ^[A-Za-z0-9]{6,32}$ ]]
}
