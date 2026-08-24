import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.boyoyooo.whatsmarchy"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  // --- mirrored host state --------------------------------------------------
  readonly property bool   everLoaded:  hostWidget ? hostWidget.everLoaded === true : false
  readonly property bool   fetching:    hostWidget ? hostWidget.fetching === true : false
  readonly property string errorText:   hostWidget ? hostWidget.errorText : ""
  readonly property string mode:        hostWidget ? hostWidget.mode : "all"
  readonly property bool   paused:      hostWidget ? hostWidget.paused === true : false
  readonly property bool   syncRunning: hostWidget ? hostWidget.syncRunning === true : false
  readonly property int    totalNew:    hostWidget ? hostWidget.totalNew : 0
  readonly property bool   truncated:   hostWidget ? hostWidget.truncated === true : false
  readonly property var    chats:       hostWidget ? hostWidget.chats : []
  readonly property string widgetLabel: hostWidget ? hostWidget.widgetLabel : ""
  readonly property string ctlScript:   hostWidget ? hostWidget.ctlScript : ""
  readonly property color  accentColor: hostWidget ? hostWidget.accentColor : "#25d366"
  readonly property color  alertColor:  hostWidget ? hostWidget.alertColor : "#e5534b"

  readonly property string iconDm:       "\u{F0361}"
  readonly property string iconGroup:    "\u{F0B79}"
  readonly property string iconPlay:     "\u{F040A}"
  readonly property string iconImage:    "\u{F02E9}"
  readonly property string iconDoc:      "\u{F0219}"
  readonly property string iconMic:      "\u{F036C}"
  readonly property string iconSend:     "\u{F048A}"
  readonly property string iconOpen:     "\u{F03CC}"
  readonly property string iconSettings: "\u{F0493}"
  readonly property string iconMarkRead: "\u{F012C}"
  readonly property string iconRefresh:  "\u{F0450}"
  readonly property string iconWhatsApp: "\u{F05A3}"

  // --- panel-local UI state -------------------------------------------------
  property string expandedJid: ""
  // markSeen() refreshes the poller immediately, and the poller only returns
  // chats with unread messages — so the chat the user just opened vanishes
  // from hostWidget.chats within the same second, closing the view before it
  // can be read. This snapshot keeps it rendered until the user collapses it
  // or the panel closes, regardless of what the live poll says.
  property var    expandedSnapshot: null
  readonly property var displayChats: {
    if (root.expandedJid === "") return root.chats
    for (var i = 0; i < root.chats.length; i++) {
      if (root.chats[i].jid === root.expandedJid) return root.chats
    }
    if (root.expandedSnapshot && root.expandedSnapshot.jid === root.expandedJid)
      return root.chats.concat([root.expandedSnapshot])
    return root.chats
  }
  property bool   settingsOpen: false
  property string actionError: ""
  // Keyed by "<jid>|<msgId>" so an id colliding across chats can't cross wires.
  property var    mediaPaths: ({})
  property string busyKey: ""
  property var    allowList: []
  property bool   hideMuted: false
  // Marking read for real (see mark_read_remote in wa-ctl.sh) briefly stops
  // and restarts the sync service — a few seconds, not instant. This gates
  // an overlay so a click elsewhere mid-flight can't race it.
  //
  // A counter, not a bool: three independent processes can each be marking
  // something read at once (per-row click, "mark all", auto-mark after a
  // reply). Two overlapping, with one flipping a shared bool to false while
  // the other is still running, left the overlay stuck forever whenever
  // that happened — the bool never went back to true because nothing
  // "started" it a second time from the other's perspective either.
  property int    markReadPending: 0
  readonly property bool markReadBusy: root.markReadPending > 0

  // --- voice reply state ----------------------------------------------------
  // Panel-scoped rather than per-delegate: there is one microphone, so there is
  // one recording, and the Process that owns it lives out here next to sendProc
  // rather than inside a Repeater delegate that can be destroyed mid-take.
  property bool   voiceAvailable: false
  property string voiceDetail: ""
  property int    voiceMaxSeconds: 120
  // idle -> recording -> preview -> sending. There is deliberately no edge from
  // recording straight to sending: the point of this feature is that you hear
  // what you recorded before anyone else does.
  property string voiceState: "idle"
  property string voiceJid: ""
  // Kept alongside the JID because the banner lives outside the chat list and
  // has no delegate to read a name off — by design: the chat it names may well
  // have left the list by the time the recording stops.
  property string voiceName: ""
  property string voiceToken: ""
  property int    voiceSeconds: 0
  // "ok" | "silent" | "unknown". Three states, not a boolean: a level check that
  // could not run must not be indistinguishable from one that passed.
  property string voiceLevel: "ok"
  property bool   voiceDiscardOnStop: false
  property bool   voiceAbandonOnSend: false

  function msgKey(jid, id) { return String(jid) + "|" + String(id) }

  // A local path becomes a file: URL. Percent-encoding matters: a store path
  // with a space, '#' or '?' would otherwise be truncated or misread as a
  // fragment/query and silently load the wrong file (or nothing).
  function fileUrl(path) {
    return "file://" + encodeURI(String(path)).replace(/#/g, "%23").replace(/\?/g, "%3F")
  }

  // Mutating a `property var` object in place does not fire its change signal,
  // so every update goes through a fresh copy. Bindings that read these maps
  // would otherwise keep showing the pre-update value.
  function withEntry(obj, key, value) {
    var next = ({})
    for (var k in obj) next[k] = obj[k]
    next[key] = value
    return next
  }

  function open()  { root.controller.show() }
  function close() { root.controller.hide() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  onOpenedChanged: {
    if (root.opened) {
      root.actionError = ""
      configProc.reload()
      voiceStatusProc.probe()
    } else {
      // Before anything else: a panel the user has dismissed must not leave a
      // microphone running behind it.
      root.cancelVoice()
      root.expandedJid = ""
      root.expandedSnapshot = null
      root.settingsOpen = false
    }
  }

  // A recording belongs to the conversation it was started in. Collapsing that
  // chat or opening another one abandons the draft rather than quietly
  // recording on into a row nobody can see.
  onExpandedJidChanged: {
    if (root.voiceState !== "idle" && root.voiceJid !== root.expandedJid) root.cancelVoice()
  }

  // Keeps "2 min ago" honest while the panel sits open between polls.
  property int nowTick: 0
  Timer { interval: 20000; running: root.opened; repeat: true; onTriggered: root.nowTick++ }

  function agoText(epoch) {
    root.nowTick // dependency: re-evaluate on each tick
    if (!epoch) return ""
    var secs = Math.max(0, Math.round(Date.now() / 1000) - epoch)
    if (secs < 60)    return "now"
    if (secs < 3600)  return Math.round(secs / 60) + "m"
    if (secs < 86400) return Math.round(secs / 3600) + "h"
    return Math.round(secs / 86400) + "d"
  }

  function mmss(secs) {
    var s = Math.max(0, Math.round(secs))
    var r = s % 60
    return Math.floor(s / 60) + ":" + (r < 10 ? "0" : "") + r
  }

  function mediaGlyph(m) {
    if (!m) return ""
    if (m.isVoice) return root.iconMic
    switch (String(m.mediaType)) {
      case "image": case "sticker": return root.iconImage
      case "video": case "gif":     return root.iconPlay
      case "audio":                 return root.iconMic
      default:                      return root.iconDoc
    }
  }

  function mediaLabel(m) {
    if (!m) return ""
    if (m.isVoice) return "Voice message"
    switch (String(m.mediaType)) {
      case "image":    return "Photo"
      case "sticker":  return "Sticker"
      case "video":    return "Video"
      case "gif":      return "GIF"
      case "audio":    return "Audio"
      case "document": return m.filename ? String(m.filename) : "Document"
      case "location": return "Location"
      default:         return "Attachment"
    }
  }

  // --- action plumbing ------------------------------------------------------
  // Every mutating call goes through wa-ctl.sh, which validates its own
  // arguments; the panel never builds a wacli command line itself.
  // Returns whether the action actually started. A caller that incremented
  // some counter (or set some "in flight" state) before calling this must
  // check the return value and undo that increment when it is false — the
  // callback is the only place such state normally gets released, and it
  // never fires for a request this guard rejects.
  function runAction(args, onDone) {
    if (actionProc.running) {
      // One action at a time. Silently swallowing the click would look like the
      // button is broken, which is worse than saying why nothing happened.
      root.actionError = "Still working on the previous action…"
      return false
    }
    root.actionError = ""
    actionProc.pending = onDone || null
    actionProc.command = [root.ctlScript].concat(args)
    actionProc.running = true
    return true
  }

  Process {
    id: actionProc
    running: false
    property var pending: null
    stdout: StdioCollector {
      onStreamFinished: {
        var cb = actionProc.pending
        actionProc.pending = null
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        // The callback now always fires, success or failure — it is the only
        // hook some callers have to release state they set up before calling
        // runAction (markSeen's markReadPending, playVoice/openAttachment's
        // busyKey). A callback that only cares about success checks
        // payload.ok itself; none of the current ones need to.
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "action failed")
          root.busyKey = ""
        }
        if (cb) cb(payload)
      }
    }
  }

  Process {
    id: configProc
    running: false
    function reload() { if (!configProc.running) configProc.running = true }
    command: [root.ctlScript, "config-get"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var p = JSON.parse(this.text)
          if (p && p.ok === true) {
            if (Array.isArray(p.allow)) root.allowList = p.allow
            root.hideMuted = p.hideMuted === true
          }
        } catch (e) { /* leave the previous list rather than blanking it */ }
      }
    }
  }

  // Emitted after a reply lands, so the delegate that owns the (repeater-
  // scoped) input can clear itself. The Process below lives at panel scope and
  // cannot reach any individual delegate's TextField by id.
  signal replySent(string jid)

  // Sends the reply body over stdin, never as an argument: the text is the
  // user's private message and has no business in /proc/<pid>/cmdline.
  Process {
    id: sendProc
    running: false
    stdinEnabled: false
    property string body: ""
    property string jid: ""
    onStarted: {
      write(sendProc.body)
      sendProc.body = ""
      // Closing stdin is what lets wa-ctl.sh's `cat` return; without it the
      // send would hang until the process was killed.
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        root.busyKey = ""
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "send failed")
          return
        }
        root.actionError = ""
        root.replySent(sendProc.jid)
        // Replying is a deliberate, completed action — unlike just opening a
        // chat, there is no draft left to lose, so auto-marking it read here
        // doesn't reintroduce the problem expandedSnapshot exists to avoid.
        root.autoMarkSeenAfterSend(sendProc.jid)
      }
    }
  }

  Process {
    id: allowProc
    running: false
    stdinEnabled: false
    property string body: "[]"
    onStarted: {
      write(allowProc.body)
      stdinEnabled = false
    }
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true)
          root.actionError = String((payload && payload.error) || "could not save the allow list")
        if (root.hostWidget) root.hostWidget.refresh()
      }
    }
  }

  function saveAllow(values) {
    if (allowProc.running) return
    var arr = []
    for (var i = 0; i < values.length; i++) arr.push(String(values[i]))
    root.allowList = arr
    allowProc.body = JSON.stringify(arr)
    allowProc.command = [root.ctlScript, "set-allow"]
    allowProc.stdinEnabled = true
    allowProc.running = true
  }

  function setMode(newMode) {
    runAction(["set-mode", newMode], function () {
      if (root.hostWidget) root.hostWidget.refresh()
    })
  }

  function setHideMuted(value) {
    runAction(["set-hide-muted", value ? "true" : "false"], function (payload) {
      if (payload && payload.ok === true) {
        root.hideMuted = payload.hideMuted === true
        if (root.hostWidget) root.hostWidget.refresh()
      }
    })
  }

  // "How much the bar shows" is an Omarchy-native per-widget setting
  // (shell.json), not something wa-ctl.sh's own config touches — set through
  // the same CLI a user would otherwise have to type themselves.
  function setBarDetail(value) {
    if (barDetailProc.running) return
    barDetailProc.command = ["omarchy", "bar", "set", root.moduleName, "barDetail", value]
    barDetailProc.running = true
  }

  Process {
    id: barDetailProc
    running: false
  }

  // onComplete (optional) fires after this call's own cleanup, success or
  // failure either way — markAllSeen chains through it to run one mark-seen
  // at a time rather than trying to batch them.
  function markSeen(jid, ts, onComplete) {
    root.markReadPending++
    var started = runAction(["mark-seen", String(jid), String(Math.round(ts))], function () {
      root.markReadPending--
      // A deliberate "mark as read" must remove the chat even if it was the
      // expanded one — expandedSnapshot exists to survive an *involuntary*
      // drop (a slip while composing), not to override an explicit dismissal.
      if (jid === root.expandedJid) {
        root.expandedJid = ""
        root.expandedSnapshot = null
      }
      if (root.hostWidget) root.hostWidget.refresh()
      if (onComplete) onComplete()
    })
    // runAction's "one action at a time" guard rejected this one — its
    // callback (the only place the increment above would be undone) will
    // never fire, so undo it here instead of leaving the overlay stuck up.
    if (!started) {
      root.markReadPending--
      if (onComplete) onComplete()
    }
  }

  // Separate from markSeen()/actionProc on purpose: a reply send completing
  // and a manual per-row click can land at the same moment, and routing both
  // through the shared "one action at a time" actionProc meant the second
  // one's request was silently dropped by that guard — including its
  // callback, which was the only thing that would have decremented
  // markReadPending again. The overlay then never went away.
  function autoMarkSeenAfterSend(jid) {
    // If a previous auto-mark is still in flight, autoMarkProc.running = true
    // below would be a no-op — the process wouldn't actually restart for this
    // jid, but nothing would ever decrement the increment this call is about
    // to make. Skipping it here (rather than incrementing and relying on a
    // decrement that will never come) is what keeps the counter honest.
    if (autoMarkProc.running) return
    root.markReadPending++
    // Not Date.now(): that would also mark read (and send a real WhatsApp
    // read receipt for) any message that arrived after the chat was opened
    // but before Send was pressed — content the user never actually saw.
    // expandedSnapshot.lastTs is the newest message that was on screen when
    // this chat was opened, which is what "I replied, so I've seen this far"
    // actually means. Falls back to now only if that snapshot is missing.
    var ts = (root.expandedSnapshot && root.expandedSnapshot.jid === jid)
      ? root.expandedSnapshot.lastTs : Date.now() / 1000
    if (jid === root.expandedJid) {
      root.expandedJid = ""
      root.expandedSnapshot = null
    }
    autoMarkProc.command = [root.ctlScript, "mark-seen", String(jid), String(Math.round(ts))]
    autoMarkProc.running = true
  }

  Process {
    id: autoMarkProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        root.markReadPending--
        if (root.hostWidget) root.hostWidget.refresh()
      }
    }
  }

  // "Mark everything as read" batching this into one script call (a JID list
  // over stdin, piped through a shell function) was observed to hang
  // indefinitely in live use — two extra forked processes (cat, and a
  // subshell for the function) both depending on the same stdin EOF
  // propagating through, which sometimes just didn't happen. Chaining plain
  // markSeen() calls one at a time — the exact path a manual per-row click
  // already takes, proven reliable — trades batching for something that
  // actually finishes. Each step still does its own stop/start of the sync
  // service, so this runs one full cycle per chat, not in parallel.
  property var markAllQueue: []

  function markAllSeen() {
    if (root.markAllQueue.length > 0) return
    root.markAllQueue = root.chats.map(function (c) {
      return { jid: String(c.jid), ts: c.lastTs }
    })
    root._markAllStep()
  }

  function _markAllStep() {
    if (root.markAllQueue.length === 0) return
    var item = root.markAllQueue.shift()
    root.markSeen(item.jid, item.ts, root._markAllStep)
  }

  function openWebApp() { runAction(["webapp"], null) }

  function sendReply(jid, text) {
    if (sendProc.running) return
    var body = String(text || "").trim()
    if (body === "") return
    root.busyKey = "send"
    sendProc.jid = String(jid)
    sendProc.body = body
    sendProc.command = [root.ctlScript, "send", String(jid)]
    sendProc.stdinEnabled = true
    sendProc.running = true
  }

  function playVoice(jid, id) {
    root.busyKey = root.msgKey(jid, id)
    runAction(["play", String(jid), String(id)], function () { root.busyKey = "" })
  }

  function openAttachment(jid, id) {
    root.busyKey = root.msgKey(jid, id)
    runAction(["open", String(jid), String(id)], function () { root.busyKey = "" })
  }

  // --- voice reply ----------------------------------------------------------
  // Same rule as the text reply: a human starts it, a human stops it, and a
  // human presses Send after listening back. Nothing here records or sends on
  // its own, and no state machine edge exists that would let it.

  Process {
    id: voiceStatusProc
    running: false
    function probe() { if (!voiceStatusProc.running) voiceStatusProc.running = true }
    command: [root.ctlScript, "voice-status"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var p = JSON.parse(this.text)
          root.voiceAvailable = !!(p && p.ok === true && p.available === true)
          root.voiceDetail = String((p && (p.detail || p.recorder)) || "")
          if (p && typeof p.maxSeconds === "number" && p.maxSeconds > 0)
            root.voiceMaxSeconds = p.maxSeconds
        } catch (e) {
          root.voiceAvailable = false
          root.voiceDetail = ""
        }
      }
    }
  }

  // Stopping is "close this process's stdin" — the same pipe the text reply
  // uses to hand over its body, here used only for its EOF. Nothing is ever
  // written to it. Making stop mean "the pipe closed" is what guarantees the
  // microphone cannot outlive the panel: if Quickshell tears this Process down,
  // the recorder ends for exactly the same reason a Stop click ends it.
  Process {
    id: recordProc
    running: false
    stdinEnabled: false
    stdout: StdioCollector {
      onStreamFinished: {
        var discard = root.voiceDiscardOnStop
        root.voiceDiscardOnStop = false
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "recording failed")
          root.resetVoice()
          return
        }
        if (discard) {
          // Cancelled while the tape was still running. wa-ctl.sh had already
          // committed the file by then, so it has to be deleted rather than
          // merely forgotten about.
          root.discardRecording(String(payload.token))
          root.resetVoice()
          return
        }
        root.voiceToken = String(payload.token || "")
        // The encoded length, not the UI's own count: a suspended input device
        // takes a moment to wake, and the honest number is the one that came
        // back with the file.
        if (typeof payload.seconds === "number") root.voiceSeconds = payload.seconds
        root.voiceLevel = payload.silent === true ? "silent"
                        : (payload.silent === false ? "ok" : "unknown")
        root.voiceState = root.voiceToken !== "" ? "preview" : "idle"
      }
    }
  }

  Process {
    id: voiceSendProc
    running: false
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        var abandoned = root.voiceAbandonOnSend
        if (!payload || payload.ok !== true) {
          root.actionError = String((payload && payload.error) || "voice note send failed")
          if (abandoned) {
            // The draft's row is gone, so nobody is left to press Send again.
            // Restoring "preview" here would strand the state machine in a
            // state no visible row can leave, and the microphone button (which
            // requires "idle") would never come back.
            if (root.voiceToken !== "") root.discardRecording(root.voiceToken)
            root.resetVoice()
          } else {
            // wa-ctl.sh keeps the recording when a send fails, so Send is worth
            // pressing again.
            root.voiceState = "preview"
            root.voiceAbandonOnSend = false
          }
          return
        }
        root.actionError = ""
        root.resetVoice()
      }
    }
  }

  // Counts the take, and enforces the same ceiling wa-ctl.sh does so the
  // display can never sit at a number the recorder has already stopped at.
  Timer {
    interval: 1000
    repeat: true
    running: root.voiceState === "recording"
    onTriggered: {
      root.voiceSeconds++
      if (root.voiceSeconds >= root.voiceMaxSeconds) root.stopVoice()
    }
  }

  // A send with no answer would otherwise pin voiceState at "sending" forever,
  // and the microphone button — which requires "idle" — would stay disabled in
  // every chat with no way back short of restarting the shell. The send itself
  // is not cancelled: wacli may still deliver it, so the recording is discarded
  // rather than re-offered, exactly as an explicit abandon does.
  Timer {
    interval: 60000
    repeat: false
    running: root.voiceState === "sending"
    onTriggered: {
      if (root.voiceState !== "sending") return
      root.actionError = "The voice note is taking too long to send. wacli may still deliver it — check WhatsApp before recording it again."
      root.voiceAbandonOnSend = true
      root.voiceState = "idle"
      root.voiceJid = ""
      root.voiceName = ""
      root.voiceSeconds = 0
      root.voiceLevel = "ok"
    }
  }

  // Discards get their own process rather than runAction's single slot. A
  // discard is the deletion of microphone audio and must not be refused because
  // a thumbnail fetch happened to be in flight: cancelVoice clears the token
  // immediately afterwards, so a dropped call would strand the file with
  // nothing left able to name it. Queued, the same shape as the thumbnail
  // queue, so two in a row cannot drop one either.
  property var voiceDiscardQueue: []

  function discardRecording(token) {
    if (!token) return
    var q = root.voiceDiscardQueue.slice()
    q.push(String(token))
    root.voiceDiscardQueue = q
    pumpDiscards()
  }

  function pumpDiscards() {
    if (discardProc.running) return
    if (root.voiceDiscardQueue.length === 0) return
    var q = root.voiceDiscardQueue.slice()
    var token = q.shift()
    root.voiceDiscardQueue = q
    discardProc.command = [root.ctlScript, "voice-discard", token]
    discardProc.running = true
  }

  Process {
    id: discardProc
    running: false
    // Nothing to surface: the user asked for this file to go away, and a
    // failure to unlink it is not something they can act on.
    stdout: StdioCollector { onStreamFinished: { } }
    onRunningChanged: if (!running) Qt.callLater(root.pumpDiscards)
  }

  function resetVoice() {
    root.voiceState = "idle"
    root.voiceJid = ""
    root.voiceName = ""
    root.voiceToken = ""
    root.voiceSeconds = 0
    root.voiceLevel = "ok"
    root.voiceDiscardOnStop = false
    root.voiceAbandonOnSend = false
  }

  function startVoice(jid, name) {
    if (root.voiceState !== "idle" || recordProc.running || sendProc.running) return
    root.actionError = ""
    root.voiceJid = String(jid)
    // Markup stripped at the source, like the bar label: this reaches a Text
    // and a name is chosen by whoever is messaging you.
    root.voiceName = String(name || jid).replace(/[<>&]/g, " ").replace(/[\r\n\t]+/g, " ")
    root.voiceToken = ""
    root.voiceSeconds = 0
    root.voiceLevel = "ok"
    root.voiceDiscardOnStop = false
    root.voiceAbandonOnSend = false
    root.voiceState = "recording"
    recordProc.command = [root.ctlScript, "voice-record", String(root.voiceMaxSeconds)]
    // Opened before the process starts: the pipe is the stop switch, and a
    // recorder launched without one sees EOF immediately and captures nothing.
    recordProc.stdinEnabled = true
    recordProc.running = true
  }

  function stopVoice() {
    if (root.voiceState !== "recording") return
    recordProc.stdinEnabled = false
  }

  function cancelVoice() {
    // A send already in flight is not cancelled: wacli may have delivered it
    // already, and its own docs say not to retry such a send. It is left to
    // finish — but the draft it belongs to is gone, and the flag tells the
    // handler not to restore a preview row that has no chat to live in.
    if (root.voiceState === "sending") {
      root.voiceAbandonOnSend = true
      return
    }
    if (root.voiceState === "recording") {
      // The file does not exist yet; the flag tells the stdout handler to throw
      // away whatever wa-ctl.sh is about to hand back.
      root.voiceDiscardOnStop = true
      recordProc.stdinEnabled = false
      return
    }
    if (root.voiceState === "preview" && root.voiceToken !== "")
      root.discardRecording(root.voiceToken)
    root.resetVoice()
  }

  function playVoiceDraft() {
    if (root.voiceState !== "preview" || root.voiceToken === "") return
    root.runAction(["voice-play", root.voiceToken], null)
  }

  function sendVoice() {
    if (root.voiceState !== "preview" || root.voiceToken === "") return
    if (voiceSendProc.running) return
    root.voiceState = "sending"
    voiceSendProc.command = [root.ctlScript, "voice-send", root.voiceJid, root.voiceToken]
    voiceSendProc.running = true
  }

  // --- thumbnail queue ------------------------------------------------------
  // One resolver at a time: a chat with a dozen photos should not fan out into
  // a dozen concurrent wacli downloads the moment its row is expanded.
  property var thumbQueue: []

  function queueThumb(jid, id) {
    var key = root.msgKey(jid, id)
    if (root.mediaPaths[key] !== undefined) return
    for (var i = 0; i < root.thumbQueue.length; i++)
      if (root.thumbQueue[i].key === key) return
    var q = root.thumbQueue.slice()
    q.push({ key: key, jid: String(jid), id: String(id) })
    root.thumbQueue = q
    pumpThumbs()
  }

  function pumpThumbs() {
    if (thumbProc.running) return
    if (root.thumbQueue.length === 0) return
    var q = root.thumbQueue.slice()
    var job = q.shift()
    root.thumbQueue = q
    thumbProc.key = job.key
    thumbProc.command = [root.ctlScript, "media", job.jid, job.id]
    thumbProc.running = true
  }

  Process {
    id: thumbProc
    running: false
    property string key: ""
    stdout: StdioCollector {
      onStreamFinished: {
        var payload = null
        try { payload = JSON.parse(this.text) } catch (e) { payload = null }
        // "" records a definitive failure so the queue does not retry this
        // attachment on every repaint.
        root.mediaPaths = root.withEntry(root.mediaPaths, thumbProc.key,
          (payload && payload.ok === true) ? String(payload.path) : "")
      }
    }
    onRunningChanged: if (!running) Qt.callLater(root.pumpThumbs)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // --- header ---------------------------------------------------------
        Item {
          width: parent.width
          height: Math.max(titleCol.implicitHeight, headerActions.implicitHeight)

          Column {
            id: titleCol
            // Centered on the full header width (matching "WHO MAY NOTIFY
            // ME" and the other section headers below), not just the space
            // left of headerActions. The title text is short enough that
            // this doesn't collide with the icons on the right.
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            spacing: Style.space(2)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: root.widgetLabel !== "" ? root.widgetLabel : "Whatsmarchy"
              color: root.barForeground
              font.family: root.bar ? root.bar.fontFamily : Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: {
                if (!root.everLoaded) return "loading…"
                if (root.errorText !== "") return "unavailable"
                if (root.paused) return "notifications paused"
                if (root.totalNew === 0) return "nothing new"
                return root.totalNew + (root.truncated ? "+" : "")
                  + (root.totalNew === 1 && !root.truncated ? " new message" : " new messages")
              }
              color: root.totalNew > 0 && root.errorText === "" && !root.paused
                ? root.accentColor
                : Util.alpha(root.barForeground, 0.6)
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            PanelActionButton {
              iconText: root.iconMarkRead
              tooltipText: "Mark everything as read"
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              visible: root.totalNew > 0
              enabled: !root.markReadBusy
              onClicked: root.markAllSeen()
            }
            PanelActionButton {
              id: refreshBtn
              iconText: root.iconRefresh
              tooltipText: "Refresh"
              foreground: root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: if (root.hostWidget) root.hostWidget.refresh()

              RotationAnimator {
                target: refreshBtn
                from: 0; to: 360
                duration: 700
                loops: Animation.Infinite
                running: root.fetching
              }
            }
            PanelActionButton {
              iconText: root.iconSettings
              tooltipText: "Who may notify me"
              foreground: root.settingsOpen ? root.accentColor : root.barForeground
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: root.settingsOpen = !root.settingsOpen
            }
            PanelActionButton {
              iconText: root.iconWhatsApp
              tooltipText: "Open WhatsApp"
              foreground: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.icon
              onClicked: root.openWebApp()
            }
          }
        }

        // --- faults ----------------------------------------------------------
        Text {
          width: parent.width
          visible: root.errorText !== ""
          text: root.errorText
          textFormat: Text.PlainText
          color: root.alertColor
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: root.actionError !== ""
          text: root.actionError
          textFormat: Text.PlainText
          color: root.alertColor
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.bodySmall
        }

        // A stopped sync is the difference between "no new messages" and "no
        // news reaching this machine". Saying so beats a silently frozen count.
        Text {
          width: parent.width
          visible: root.everLoaded && root.errorText === "" && !root.syncRunning
          text: "wacli sync is not running — this list is frozen. Start it with:  systemctl --user start whatsmarchy-sync"
          textFormat: Text.PlainText
          color: "#e0a458"
          wrapMode: Text.WordWrap
          font.pixelSize: Style.font.caption
        }

        // --- settings: who may notify me -------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.settingsOpen

          PanelSeparator { width: parent.width; foreground: root.barForeground; strength: 0.08 }
          PanelSectionHeader {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "WHO MAY NOTIFY ME"
            foreground: root.barForeground
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)
            Repeater {
              model: [
                { value: "paused", label: "Paused" },
                { value: "all",    label: "Everyone" },
                { value: "custom", label: "Chosen chats" }
              ]
              delegate: Button {
                required property var modelData
                text: modelData.label
                bordered: true
                selected: root.mode === modelData.value
                foreground: root.barForeground
                accent: root.accentColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.setMode(modelData.value)
              }
            }
          }

          MultiSelect {
            id: allowSelect
            width: parent.width
            visible: root.mode === "custom"
            label: ""
            showLabel: false
            // Seeded, not bound: MultiSelect assigns to its own `values` when
            // a row is toggled, which would break a declarative binding on the
            // first click and then silently ignore later reloads.
            Component.onCompleted: allowSelect.values = root.allowList
            Connections {
              target: root
              function onAllowListChanged() {
                if (!allowProc.running) allowSelect.values = root.allowList
              }
            }
            // Populated live from wacli's synced chats, so the picker always
            // reflects the real address book rather than a hard-coded list.
            // Held empty until the host widget has been injected: MultiSelect
            // refreshes on Component.onCompleted, which runs before the Loader
            // that owns this panel hands it a hostWidget. With an empty
            // ctlScript that spawns `["", "recipients"]` and leaves the picker
            // stuck showing an options-command error. Assigning the real
            // command later re-fires onOptionsCommandChanged, so the list still
            // loads on its own.
            optionsCommand: root.ctlScript !== "" ? [root.ctlScript, "recipients"] : []
            placeholderText: "Search contacts and groups…"
            emptyText: "No synced chats yet — let wacli sync run first"
            noSelectionText: "No chats selected — nothing will notify you"
            foreground: root.barForeground
            accent: root.accentColor
            fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
            onChanged: function (values) { root.saveAllow(values) }
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground; strength: 0.08 }
          PanelSectionHeader {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "HIDE MUTED CHATS"
            foreground: root.barForeground
          }

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(6)
            Repeater {
              model: [
                { value: true,  label: "YES" },
                { value: false, label: "NO" }
              ]
              delegate: Button {
                required property var modelData
                text: modelData.label
                bordered: true
                selected: root.hideMuted === modelData.value
                foreground: root.barForeground
                accent: root.accentColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.setHideMuted(modelData.value)
              }
            }
          }

          Text {
            width: parent.width
            text: "Don't show new messages from chats currently muted in WhatsApp."
            textFormat: Text.PlainText
            color: Util.alpha(root.barForeground, 0.6)
            wrapMode: Text.WordWrap
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground; strength: 0.08 }
          PanelSectionHeader {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "WHAT THE BAR SHOWS"
            foreground: root.barForeground
          }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: [
                { value: "Icon only",                          label: "Icon only" },
                { value: "Count only",                         label: "Count only" },
                { value: "Sender and count",                   label: "Sender and count" },
                { value: "Message preview (nothing to hide)",  label: "Message preview" }
              ]
              delegate: Button {
                required property var modelData
                width: parent.width
                text: modelData.label
                bordered: true
                selected: root.hostWidget && root.hostWidget.barDetail === modelData.value
                foreground: root.barForeground
                accent: root.accentColor
                fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                fontSize: Style.font.bodySmall
                onClicked: root.setBarDetail(modelData.value)
              }
            }

            Text {
              width: parent.width
              text: "\"Message preview\" puts the latest message text on screen — anyone nearby can read it."
              color: Util.alpha(root.barForeground, 0.6)
              wrapMode: Text.WordWrap
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            visible: !root.voiceAvailable
            text: "Recording a voice reply is unavailable: " + root.voiceDetail + "."
            textFormat: Text.PlainText
            color: "#e0a458"
            wrapMode: Text.WordWrap
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { width: parent.width; foreground: root.barForeground; strength: 0.08 }
        }

        // --- chat list --------------------------------------------------------
        Text {
          // Full panel width — titleCol above now centers on this same
          // width too, so this lines up with it (and with the section
          // headers below) without needing to match a narrower box anymore.
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          visible: root.everLoaded && root.errorText === "" && root.displayChats.length === 0
          text: root.paused ? "Notifications are paused." : "You're all caught up."
          color: Util.alpha(root.barForeground, 0.5)
          font.pixelSize: Style.font.bodySmall
          topPadding: Style.space(10)
          bottomPadding: Style.space(10)
        }

        Flickable {
          id: chatScroll
          width: parent.width
          visible: root.displayChats.length > 0
          // Bounded so a busy morning cannot grow the panel past the screen;
          // beyond that the list scrolls instead.
          height: Math.min(chatColumn.implicitHeight, Style.space(430))
          contentWidth: width
          contentHeight: chatColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds

          QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }

          Column {
            id: chatColumn
            // Explicit width so every delegate below can safely bind
            // `width: parent.width` without making this Column's own width
            // depend on its children's width.
            width: chatScroll.width
            spacing: Style.space(4)

            Repeater {
              model: root.displayChats

              delegate: Column {
                id: chatItem
                required property var modelData
                readonly property bool expanded: root.expandedJid === modelData.jid
                property bool justSent: false
                width: chatColumn.width
                spacing: Style.space(4)

                Timer {
                  id: sentFlashTimer
                  interval: 1100
                  onTriggered: chatItem.justSent = false
                }

                // Optimistic: flashes the moment the user commits (click or
                // Enter), not once sendProc's async round-trip completes —
                // waiting for the reply made the confirmation feel laggy.
                function submitReply() {
                  if (replyText.text.trim() === "") return
                  chatItem.justSent = true
                  sentFlashTimer.restart()
                  root.sendReply(chatItem.modelData.jid, replyText.text)
                }

                Rectangle {
                  width: parent.width
                  height: chatRow.implicitHeight + Style.space(14)
                  radius: Style.space(6)
                  color: chatItem.expanded
                    ? Util.alpha(root.barForeground, 0.08)
                    : (chatHover.hovered ? Util.alpha(root.barForeground, 0.05) : "transparent")

                  HoverHandler { id: chatHover }
                  MouseArea {
                    anchors.fill: parent
                    onClicked: {
                      if (chatItem.expanded) {
                        // Second click on an already-open chat hands off to the
                        // official app. WhatsApp Web has no stable deep link to
                        // a specific conversation (wa.me only starts a *new*
                        // chat, and does nothing at all for groups), so this
                        // lands on the inbox — a documented limitation, not a
                        // bug to work around.
                        root.openWebApp()
                      } else {
                        root.expandedJid = chatItem.modelData.jid
                        root.expandedSnapshot = chatItem.modelData
                        // Land the cursor in the reply field on open: besides
                        // saving a click before typing, this is what makes a
                        // system-wide dictation hotkey (e.g. Omarchy's voxtype)
                        // work here for free — it types into whatever field
                        // currently has focus, so quick reply needs nothing
                        // dictation-specific of its own.
                        Qt.callLater(function() { replyText.forceActiveFocus() })
                        // Opening a chat no longer marks it seen — it used to,
                        // which meant a slip while composing (closing the
                        // panel by mistake before sending) dropped the chat
                        // from the "new" list for good, with no way back to
                        // it short of hunting it down in WhatsApp Web. A chat
                        // now only clears via "Mark everything as read".
                        var msgs = chatItem.modelData.messages || []
                        for (var i = 0; i < msgs.length; i++) {
                          var m = msgs[i]
                          if (String(m.mediaType) === "image" || String(m.mediaType) === "sticker")
                            root.queueThumb(chatItem.modelData.jid, m.id)
                        }
                      }
                    }
                  }

                  Row {
                    id: chatRow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      text: String(chatItem.modelData.kind) === "group" ? root.iconGroup : root.iconDm
                      color: Util.alpha(root.barForeground, 0.65)
                      font.family: root.bar ? root.bar.fontFamily : Style.font.family
                      font.pixelSize: Style.font.icon
                    }
                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      // Explicit width taken from the row's own geometry, not
                      // from sibling `width` values, so nothing here can form a
                      // width cycle with the enclosing Row.
                      width: chatRow.width - Style.space(8) * 4 - Style.font.icon
                             - countBadge.implicitWidth - timeText.implicitWidth
                             - markReadBtn.implicitWidth
                      text: String(chatItem.modelData.name)
                      // Contact and group names are chosen by whoever is
                      // messaging you. Text defaults to AutoText, which would
                      // render "<b>Bank</b>" as bold and let an <img> tag pull
                      // in a local file. Every attacker-controlled string in
                      // this panel is pinned to PlainText.
                      textFormat: Text.PlainText
                      color: root.barForeground
                      font.pixelSize: Style.font.body
                      font.bold: true
                      elide: Text.ElideRight
                    }
                    Rectangle {
                      id: countBadge
                      anchors.verticalCenter: parent.verticalCenter
                      implicitWidth: Math.max(badgeText.implicitWidth + Style.space(10), Style.space(20))
                      implicitHeight: badgeText.implicitHeight + Style.space(4)
                      radius: height / 2
                      color: root.accentColor
                      Text {
                        id: badgeText
                        anchors.centerIn: parent
                        text: chatItem.modelData.count > 99 ? "99+" : String(chatItem.modelData.count)
                        color: "#0b1f14"
                        font.pixelSize: Style.font.caption
                        font.bold: true
                      }
                    }
                    Text {
                      id: timeText
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.agoText(chatItem.modelData.lastTs)
                      color: Util.alpha(root.barForeground, 0.45)
                      font.pixelSize: Style.font.caption
                    }
                    Button {
                      id: markReadBtn
                      anchors.verticalCenter: parent.verticalCenter
                      // Per-row, not just "mark everything as read": without
                      // this, opening one chat to reply (which no longer
                      // auto-clears it — see the click handler above) left no
                      // way to dismiss just that one once handled, short of
                      // clearing the whole list.
                      iconText: root.iconMarkRead
                      tooltipText: "Mark this chat as read"
                      bordered: true
                      foreground: root.barForeground
                      accent: root.accentColor
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      fontSize: Style.font.caption
                      enabled: !root.markReadBusy
                      onClicked: root.markSeen(chatItem.modelData.jid, chatItem.modelData.lastTs)
                    }
                  }
                }

                // --- expanded preview ---------------------------------------
                Column {
                  width: parent.width
                  visible: chatItem.expanded
                  spacing: Style.space(8)
                  leftPadding: Style.space(8)
                  rightPadding: Style.space(8)
                  bottomPadding: Style.space(8)

                  Repeater {
                    model: chatItem.expanded ? (chatItem.modelData.messages || []) : []

                    delegate: Column {
                      id: msgItem
                      required property var modelData
                      readonly property string key: root.msgKey(chatItem.modelData.jid, modelData.id)
                      readonly property bool busy: root.busyKey === key
                      readonly property string thumb: {
                        var p = root.mediaPaths[key]
                        return (p !== undefined && p !== "") ? p : ""
                      }
                      // Explicit: the enclosing Column has a real width, and
                      // the Texts below bind to *this* width.
                      width: chatColumn.width - Style.space(16)
                      spacing: Style.space(3)

                      Text {
                        width: parent.width
                        visible: String(chatItem.modelData.kind) === "group" && String(msgItem.modelData.sender) !== ""
                        text: String(msgItem.modelData.sender)
                        textFormat: Text.PlainText
                        color: Util.alpha(root.accentColor, 0.9)
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        width: parent.width
                        visible: String(msgItem.modelData.text) !== ""
                        text: String(msgItem.modelData.text)
                        textFormat: Text.PlainText
                        color: root.barForeground
                        wrapMode: Text.WordWrap
                        maximumLineCount: 6
                        elide: Text.ElideRight
                        font.pixelSize: Style.font.bodySmall
                      }

                      // Image / sticker: real thumbnail once the file is local.
                      Image {
                        width: Math.min(implicitWidth, parent.width)
                        visible: msgItem.thumb !== ""
                          && (String(msgItem.modelData.mediaType) === "image"
                              || String(msgItem.modelData.mediaType) === "sticker")
                        source: msgItem.thumb !== "" ? root.fileUrl(msgItem.thumb) : ""
                        fillMode: Image.PreserveAspectFit
                        // Both axes are capped. With only a height cap, Qt
                        // scales the other axis proportionally, so a 200000x20
                        // image still decodes to ~1.5 megapixels wide — a
                        // decompression bomb from anyone who can send a photo.
                        // wa-ctl.sh separately refuses to hand over a file over
                        // its byte ceiling, so the decoder never sees one.
                        sourceSize.width: Style.space(340)
                        sourceSize.height: Style.space(150)
                        asynchronous: true
                        cache: false
                      }

                      // Everything else: a glyph, a label, and the actions that
                      // actually apply to that kind of attachment.
                      Row {
                        width: parent.width
                        spacing: Style.space(6)
                        visible: msgItem.modelData.hasMedia === true

                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.mediaGlyph(msgItem.modelData)
                          color: Util.alpha(root.barForeground, 0.7)
                          font.family: root.bar ? root.bar.fontFamily : Style.font.family
                          font.pixelSize: Style.font.icon
                        }
                        Text {
                          anchors.verticalCenter: parent.verticalCenter
                          // mediaLabel can be a WhatsApp-supplied filename.
                          text: root.mediaLabel(msgItem.modelData)
                          textFormat: Text.PlainText
                          color: Util.alpha(root.barForeground, 0.7)
                          font.pixelSize: Style.font.caption
                          elide: Text.ElideRight
                        }
                        Button {
                          anchors.verticalCenter: parent.verticalCenter
                          // Audio only: the underlying player (spawn_player in
                          // wa-ctl.sh) deliberately runs mpv/ffplay with video
                          // output suppressed, since that is exactly what a
                          // voice note wants. Video played the same way was
                          // just silent — right audio pipeline, wrong player
                          // mode for anything with a picture.
                          visible: String(msgItem.modelData.mediaType) === "audio"
                          text: msgItem.busy ? "…" : "Play"
                          iconText: root.iconPlay
                          bordered: true
                          foreground: root.barForeground
                          accent: root.accentColor
                          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                          fontSize: Style.font.caption
                          onClicked: root.playVoice(chatItem.modelData.jid, msgItem.modelData.id)
                        }
                        Button {
                          anchors.verticalCenter: parent.verticalCenter
                          // Video and gif hand off to the system's default
                          // handler (same path as documents/images) instead
                          // of a dedicated in-panel player — simplest fix that
                          // actually shows a picture.
                          visible: String(msgItem.modelData.mediaType) === "document"
                                   || String(msgItem.modelData.mediaType) === "image"
                                   || String(msgItem.modelData.mediaType) === "video"
                                   || String(msgItem.modelData.mediaType) === "gif"
                          text: "Open"
                          bordered: true
                          foreground: root.barForeground
                          accent: root.accentColor
                          fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                          fontSize: Style.font.caption
                          onClicked: root.openAttachment(chatItem.modelData.jid, msgItem.modelData.id)
                        }
                      }
                    }
                  }

                  // --- quick reply: text, plus the button that starts a
                  // voice one. The recorder's own controls deliberately do NOT
                  // live here: this delegate is destroyed whenever the chat
                  // drops out of the poller's payload, which happens on the
                  // very next poll after mark-seen. Stop and Cancel have to
                  // outlive that, so they sit at panel scope with the Process.
                  Row {
                    id: replyRow
                    width: chatColumn.width - Style.space(16)
                    spacing: Style.space(6)

                    // A single-line TextField can't grow, so a long reply
                    // scrolled out of view while typing. QtQuick.Controls'
                    // TextField is fixed-height by design — this wraps a
                    // TextArea instead, styled to match qs.Ui's TextField
                    // (same border/fill treatment), growing up to a cap and
                    // then scrolling internally.
                    Flickable {
                      id: replyFlick
                      anchors.top: parent.top
                      // micBtn's share is conditional: a Row gives an invisible
                      // child neither width nor spacing, so subtracting for one
                      // that isn't there would leave a permanent gap at the end
                      // of the row.
                      width: replyRow.width - sendBtn.implicitWidth - webBtn.implicitWidth
                             - (micBtn.visible ? micBtn.implicitWidth + Style.space(6) : 0)
                             - Style.space(6) * 2
                      // Grows with the text up to a ~4-line cap, then scrolls
                      // internally. An earlier attempt at this looked like it
                      // wasn't recalculating implicitHeight, so it was pinned
                      // to a fixed ~4-line box; the real cause was the broken
                      // wrapMode below (no wrapping means the text is always
                      // one line, so implicitHeight never grows). Pinning it
                      // also left the field's bordered background — sized to
                      // the TextArea, not to this Flickable — floating at the
                      // top of a 76px slot, which is what put the buttons out
                      // of line with the visible input.
                      height: Math.max(Style.space(28),
                                       Math.min(Style.space(76), replyText.implicitHeight))
                      contentWidth: width
                      contentHeight: Math.max(height, replyText.implicitHeight)
                      clip: true
                      boundsBehavior: Flickable.StopAtBounds

                      readonly property var _borderSpec:
                        Border.controlSpec(replyText.activeFocus ? "focus" : "normal", root.barForeground, root.accentColor)

                      QQC.TextArea {
                        id: replyText
                        width: replyFlick.width
                        // TextEdit, not TextArea: QtQuick.Controls is imported
                        // qualified (as QQC), so the bare name `TextArea` does
                        // not exist here and `TextArea.WordWrap` threw a
                        // ReferenceError, silently leaving wrapMode at its
                        // NoWrap default. TextArea derives from TextEdit and
                        // shares the enum, and TextEdit comes in unqualified
                        // with `import QtQuick`.
                        wrapMode: TextEdit.WordWrap
                        placeholderText: "Reply…"
                        color: root.barForeground
                        placeholderTextColor: Qt.darker(root.barForeground, 1.6)
                        selectionColor: Style.selectionFillFor(root.barForeground, root.accentColor)
                        font.family: Style.font.family
                        font.pixelSize: Style.font.body
                        leftPadding: Style.spacing.controlPaddingX + Border.left(replyFlick._borderSpec)
                        rightPadding: Style.spacing.controlPaddingX + Border.right(replyFlick._borderSpec)
                        topPadding: Style.spacing.inputPaddingY + Border.top(replyFlick._borderSpec)
                        bottomPadding: Style.spacing.inputPaddingY + Border.bottom(replyFlick._borderSpec)
                        enabled: !sendProc.running
                        background: BorderSurface {
                          color: Style.controlFill(replyText.activeFocus, replyText.hovered, root.barForeground, root.accentColor)
                          borderSpec: replyFlick._borderSpec
                          radius: Style.cornerRadius
                        }
                        // Return sends; Shift+Return inserts a literal newline
                        // for a genuinely multi-paragraph reply.
                        Keys.onReturnPressed: function (event) {
                          if (event.modifiers & Qt.ShiftModifier) { event.accepted = false }
                          else { chatItem.submitReply(); event.accepted = true }
                        }
                        Keys.onEnterPressed: function (event) {
                          if (event.modifiers & Qt.ShiftModifier) { event.accepted = false }
                          else { chatItem.submitReply(); event.accepted = true }
                        }
                      }

                      Connections {
                        target: root
                        function onReplySent(jid) {
                          if (jid === String(chatItem.modelData.jid)) replyText.text = ""
                        }
                      }
                    }
                    Button {
                      id: micBtn
                      // Top-aligned rather than centered: replyFlick is now a
                      // fixed ~4-line box, and centering left these floating
                      // in the middle of it, well below the first line of text.
                      anchors.top: parent.top
                      // Hidden rather than shown-and-failing when there is no
                      // recorder or no Opus encoder available.
                      visible: root.voiceAvailable
                      iconText: root.iconMic
                      tooltipText: "Record a voice note (you can listen back before it sends)"
                      bordered: true
                      enabled: root.voiceState === "idle" && !sendProc.running
                      foreground: root.barForeground
                      accent: root.accentColor
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      fontSize: Style.font.icon
                      onClicked: root.startVoice(chatItem.modelData.jid, chatItem.modelData.name)
                    }
                    Button {
                      id: sendBtn
                      anchors.top: parent.top
                      // Briefly swaps to a checkmark on success — sending had no
                      // visible confirmation before, whether triggered by this
                      // button or by pressing Enter in the field.
                      iconText: chatItem.justSent ? root.iconMarkRead : root.iconSend
                      tooltipText: "Send"
                      bordered: true
                      enabled: !sendProc.running
                      foreground: chatItem.justSent ? root.accentColor : root.barForeground
                      accent: root.accentColor
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      fontSize: Style.font.icon
                      onClicked: chatItem.submitReply()

                      Behavior on foreground { ColorAnimation { duration: 150 } }
                    }
                    Button {
                      id: webBtn
                      anchors.top: parent.top
                      iconText: root.iconOpen
                      tooltipText: "Open WhatsApp Web (opens the inbox — WhatsApp has no per-chat link)"
                      bordered: true
                      foreground: root.barForeground
                      accent: root.accentColor
                      fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
                      fontSize: Style.font.icon
                      onClicked: root.openWebApp()
                    }
                  }
                }
              }
            }
          }
        }

        // --- voice reply, at panel scope -------------------------------------
        // Outside the chat list on purpose. The recorder's Process lives at
        // panel scope, and its controls have to share that lifetime: a chat
        // delegate is destroyed the moment the chat leaves the poller's
        // payload — which mark-seen causes on the very next poll — and a Stop
        // button that can vanish while the microphone is still open is the one
        // failure this feature must not have.
        Column {
          id: voiceArea
          width: parent.width
          spacing: Style.space(4)
          visible: root.voiceState !== "idle"

          PanelSeparator { width: parent.width; foreground: root.barForeground; strength: 0.08 }

          Row {
            id: recordingRow
            width: voiceArea.width
            spacing: Style.space(8)
            visible: root.voiceState === "recording"

            Rectangle {
              id: recDot
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(10)
              height: Style.space(10)
              radius: width / 2
              color: root.alertColor
              SequentialAnimation on opacity {
                running: recordingRow.visible
                loops: Animation.Infinite
                NumberAnimation { to: 0.2; duration: 550; easing.type: Easing.InOutQuad }
                NumberAnimation { to: 1.0; duration: 550; easing.type: Easing.InOutQuad }
              }
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: recordingRow.width - recDot.width - stopBtn.implicitWidth
                     - recCancelBtn.implicitWidth - Style.space(8) * 3
              // voiceName is a contact or group name, so it is pinned like every
              // other attacker-controlled string in this panel.
              text: "Recording to " + root.voiceName + "  "
                    + root.mmss(root.voiceSeconds) + " / " + root.mmss(root.voiceMaxSeconds)
              textFormat: Text.PlainText
              color: root.barForeground
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
            Button {
              id: stopBtn
              anchors.verticalCenter: parent.verticalCenter
              text: "Stop"
              bordered: true
              foreground: root.barForeground
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.stopVoice()
            }
            Button {
              id: recCancelBtn
              anchors.verticalCenter: parent.verticalCenter
              text: "Cancel"
              bordered: true
              foreground: root.barForeground
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.cancelVoice()
            }
          }

          // Preview. Nothing has been sent at this point and nothing will be
          // until Send is pressed here.
          Row {
            id: previewRow
            width: voiceArea.width
            spacing: Style.space(6)
            visible: root.voiceState === "preview" || root.voiceState === "sending"

            Button {
              id: previewPlayBtn
              anchors.verticalCenter: parent.verticalCenter
              text: "Play"
              iconText: root.iconPlay
              bordered: true
              foreground: root.barForeground
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.playVoiceDraft()
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: previewRow.width - previewPlayBtn.implicitWidth
                     - previewCancelBtn.implicitWidth - previewSendBtn.implicitWidth
                     - Style.space(6) * 3
              text: "Voice note to " + root.voiceName + " · " + root.mmss(root.voiceSeconds)
              textFormat: Text.PlainText
              color: Util.alpha(root.barForeground, 0.7)
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
            Button {
              id: previewCancelBtn
              anchors.verticalCenter: parent.verticalCenter
              text: "Cancel"
              tooltipText: "Discard this recording"
              bordered: true
              enabled: root.voiceState === "preview"
              foreground: root.barForeground
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.cancelVoice()
            }
            Button {
              id: previewSendBtn
              anchors.verticalCenter: parent.verticalCenter
              text: root.voiceState === "sending" ? "…" : "Send"
              iconText: root.iconSend
              bordered: true
              enabled: root.voiceState === "preview"
              foreground: root.barForeground
              accent: root.accentColor
              fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
              fontSize: Style.font.caption
              onClicked: root.sendVoice()
            }
          }

          // A recording made from a monitor or a muted device is
          // indistinguishable from a good one until someone plays it. Saying so
          // here beats finding out after it has been sent. "Could not tell" is
          // its own message rather than silence, so a failed measurement never
          // reads as a clean recording.
          Text {
            width: voiceArea.width
            visible: root.voiceState === "preview" && root.voiceLevel !== "ok"
            text: root.voiceLevel === "silent"
              ? "This recording sounds silent — your default input device may be a monitor rather than a microphone."
              : "Could not check whether this recording captured any sound. Play it before sending."
            textFormat: Text.PlainText
            color: "#e0a458"
            wrapMode: Text.WordWrap
            font.pixelSize: Style.font.caption
          }
        }
      }

      // Blocks input while a real read receipt is in flight (see
      // markReadBusy) — the sync service is briefly down during that window,
      // and a click landing on something else mid-restart is exactly the
      // kind of race this exists to prevent.
      Rectangle {
        anchors.fill: parent
        visible: root.markReadBusy
        color: Util.alpha("#000000", 0.35)

        MouseArea { anchors.fill: parent; onClicked: function () {} }

        Row {
          anchors.centerIn: parent
          spacing: Style.space(8)

          Text {
            id: markReadSpinner
            anchors.verticalCenter: parent.verticalCenter
            text: root.iconRefresh
            color: root.barForeground
            font.family: root.bar ? root.bar.fontFamily : Style.font.family
            font.pixelSize: Style.font.icon

            RotationAnimator {
              target: markReadSpinner
              from: 0; to: 360
              duration: 800
              loops: Animation.Infinite
              running: root.markReadBusy
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "Marking as read…"
            color: root.barForeground
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
