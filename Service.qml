import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The plugin's data layer, instantiated once per shell as its `service`
// entry point. Every bar widget (one per monitor) and every open panel reads
// this one instance, so player polling and library fetches never run more
// than once per shell. All Pocket Casts and mpv traffic goes through
// bin/pocketcasts-bridge, which prints one JSON object per call.
Item {
  id: root

  property var shell: null
  property var settings: ({})
  // A widget-local instance, built only under a shell without service
  // support, stays inert once a shared one exists.
  property bool active: true

  readonly property string pluginDir: decodeURIComponent(Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")).replace(/\/$/, "")
  readonly property string bridge: pluginDir + "/bin/pocketcasts-bridge"

  // ---- Trust boundary. Nothing here starts a program through the session
  //      PATH or hands it the session environment. The bridge runs under an
  //      absolute Python found once at startup (`python3 -I`, never the
  //      script's own interpreter line) in a cleared environment. See
  //      Model.js's "Trusted executables and closed environments".
  function sessionValues(names) {
    var values = {}
    for (var i = 0; i < names.length; i++) values[names[i]] = Quickshell.env(names[i])
    return values
  }
  readonly property var bridgeEnvironment: Model.closedEnvironment(sessionValues(Model.bridgeEnvironmentNames), Model.bridgeEnvironmentNames, Model.trustedPathEnvironment)
  readonly property var pythonProbeEnvironment: Model.closedEnvironment({}, [], Model.trustedPathEnvironment)

  property string python: ""
  property string pythonError: ""
  property bool _pythonProbing: false
  property int _pythonAttempt: 0
  property int _pythonProbeWaits: 0
  property var _pythonProbeObject: null
  property int _pythonCandidate: 0
  property var _queuedCalls: []

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  readonly property int skipBackSeconds: Math.max(1, Number(setting("skipBack", 10)) || 10)
  readonly property int skipForwardSeconds: Math.max(1, Number(setting("skipForward", 30)) || 30)
  readonly property bool autoplay: setting("autoplay", true) !== false

  // ---- Connection state (from `pocketcasts-bridge status`)
  property bool probed: false
  property bool probing: false
  property bool authenticated: false
  property bool needsReauth: false
  property string email: ""
  property bool mpvInstalled: true
  property bool mprisInstalled: false
  property string lastError: ""
  // The last episode loaded, remembered by the bridge across shell restarts
  // so the bar chip has a cover before the first poll.
  property var lastItem: ({})

  // ---- Sign-in
  property bool loginRunning: false
  property string loginError: ""

  // ---- Player
  property var player: ({ active: false })
  property bool playerLoading: false
  property string playerError: ""
  property double playerFetchedAt: 0
  property real localPosition: 0
  readonly property bool playerActive: player && player.active === true
  readonly property bool isPlaying: playerActive && player.playing === true
  readonly property bool buffering: playerActive && player.buffering === true
  readonly property var nowItem: player && player.item ? player.item : null
  readonly property string nowUuid: nowItem && nowItem.uuid ? nowItem.uuid : ""
  readonly property real duration: player && player.duration ? Number(player.duration) : 0
  readonly property int volume: player && player.volume !== undefined ? Number(player.volume) : 100
  readonly property real speed: player && player.speed ? Number(player.speed) : 1

  // ---- Lists
  property var upNext: []
  property bool upNextLoading: false
  property string upNextError: ""
  property double upNextLoadedAt: 0

  property var inProgress: []
  property bool inProgressLoading: false
  property string inProgressError: ""
  property double inProgressLoadedAt: 0

  property var newReleases: []
  property bool newReleasesLoading: false
  property string newReleasesError: ""
  property double newReleasesLoadedAt: 0

  property var podcasts: []
  property bool podcastsLoading: false
  property string podcastsError: ""
  property double podcastsLoadedAt: 0

  // ---- Show page (a podcast's episodes)
  property var detail: null
  property int _detailSerial: 0

  // ---- Short-lived action feedback
  property string actionStatus: ""
  property string actionError: ""
  property bool actionRunning: false

  // Panels tell the service when they're visible so polling can speed up.
  property int openPanels: 0
  readonly property bool panelOpen: openPanels > 0

  readonly property bool busy: probing || upNextLoading || inProgressLoading || newReleasesLoading || podcastsLoading || (detail && detail.loading === true)

  readonly property int staleMs: 300000

  // ------------------------------------------------------------ process --

  // Each bridge call gets its own short-lived Process so a player poll never
  // waits behind a list fetch. The callback receives the parsed envelope.
  // `secret` is the one exception to "no stdin": sign-in hands the email and
  // password over a pipe so they never appear in a command line.
  Component {
    id: bridgeProcess

    Process {
      id: proc
      property var callback: null
      property string secret: ""
      running: false
      clearEnvironment: true
      environment: root.bridgeEnvironment
      stdinEnabled: secret !== ""
      stdout: StdioCollector { id: outCollector; waitForEnd: true }
      stderr: StdioCollector { id: errCollector; waitForEnd: true }
      onStarted: {
        if (secret === "") return
        write(secret)
        secret = ""
        stdinEnabled = false
      }
      onExited: function(exitCode, exitStatus) {
        var text = String(outCollector.text || "")
        var err = String(errCollector.text || "")
        var result
        try {
          result = JSON.parse(text)
        } catch (e) {
          var detail = text.trim() !== "" ? text.trim() : err.trim()
          result = { ok: false, code: exitCode === 0 ? "parse" : "crash", error: Model.conciseError(detail, "pocketcasts-bridge returned nothing") }
        }
        if (result && result.ok === false && result.error) result.error = Model.conciseError(result.error)
        var cb = proc.callback
        proc.callback = null
        if (cb) cb(result)
        proc.destroy()
      }
    }
  }

  function call(args, callback, secret) {
    if (!active) return null
    if (python === "" && pythonError === "") {
      // Calls made before the interpreter is known wait for the probe.
      var queued = _queuedCalls
      queued.push({ args: args, callback: callback, secret: secret || "" })
      _queuedCalls = queued
      resolvePython()
      return null
    }
    var command = python === "" ? [] : Model.bridgeCommand(python, bridge, args)
    if (command.length === 0) {
      // Fail closed: no trusted interpreter means no bridge call at all.
      var failure = { ok: false, code: "no_python", error: pythonError || "Could not build the pocketcasts-bridge command" }
      if (callback) Qt.callLater(function() { callback(failure) })
      return null
    }
    var proc = bridgeProcess.createObject(root, { command: command, callback: callback, secret: secret || "" })
    if (!proc) return null
    proc.running = true
    return proc
  }

  function resolvePython() {
    if (python !== "" || pythonError !== "" || _pythonProbing) return
    _pythonCandidate = 0
    probeNextPython()
  }

  // Walk the absolute candidates in order; the first that starts and reports
  // a usable Python 3 is the bridge's interpreter for the life of the shell.
  // Each attempt is its own Process tagged with its number, so a late exit
  // from an abandoned attempt can never settle a later one.
  function probeNextPython() {
    var command = []
    while (command.length === 0 && _pythonCandidate < Model.pythonCandidates.length) {
      command = Model.pythonProbeCommand(Model.pythonCandidates[_pythonCandidate])
      if (command.length === 0) _pythonCandidate++
    }
    if (command.length === 0) {
      _pythonProbing = false
      pythonError = "No Python 3 found in " + Model.trustedBinaryDirectories.join(", ")
        + " — the Pocket Casts plugin will not run python3 from your PATH"
      flushQueuedCalls()
      return
    }
    _pythonProbing = true
    _pythonAttempt++
    _pythonProbeWaits = 0
    var probe = pythonProbeProcess.createObject(root, { command: command, attempt: _pythonAttempt })
    if (!probe) { settlePythonProbe(_pythonAttempt, false, -1); return }
    _pythonProbeObject = probe
    pythonProbeWatchdog.restart()
    probe.running = true
  }

  function settlePythonProbe(attempt, started, exitCode) {
    if (!_pythonProbing || attempt !== _pythonAttempt) return
    pythonProbeWatchdog.stop()
    _pythonProbeObject = null
    if (started && exitCode === 0) {
      _pythonProbing = false
      python = Model.pythonCandidates[_pythonCandidate]
      flushQueuedCalls()
      return
    }
    _pythonCandidate++
    probeNextPython()
  }

  function flushQueuedCalls() {
    var queued = _queuedCalls
    _queuedCalls = []
    for (var i = 0; i < queued.length; i++) call(queued[i].args, queued[i].callback, queued[i].secret)
  }

  Component {
    id: pythonProbeProcess

    Process {
      id: probeProc
      property int attempt: 0
      property bool started: false
      running: false
      clearEnvironment: true
      environment: root.pythonProbeEnvironment
      onStarted: started = true
      onExited: function(exitCode) {
        root.settlePythonProbe(probeProc.attempt, probeProc.started, exitCode)
        probeProc.destroy()
      }
    }
  }

  // Quickshell emits no exit at all for a candidate that does not exist, so
  // an attempt that has not even started after three seconds is a miss. One
  // that started (a slow first run at login) gets up to half a minute more.
  Timer {
    id: pythonProbeWatchdog
    interval: 3000
    repeat: false
    onTriggered: {
      var probe = root._pythonProbeObject
      if (probe && probe.started && ++root._pythonProbeWaits < 10) { restart(); return }
      root.settlePythonProbe(root._pythonAttempt, false, -1)
      if (probe) { probe.running = false; probe.destroy() }
    }
  }

  // Auth-shaped errors flip the connection state so the panel shows the
  // sign-in card instead of a wall of identical errors.
  function absorbAuthError(result) {
    if (!result || result.ok !== false) return false
    if (result.code === "signed_out") { authenticated = false; return true }
    if (result.code === "reauth") { authenticated = false; needsReauth = true; return true }
    return false
  }

  function flash(text, isError) {
    if (isError) { actionError = text; actionStatus = "" }
    else { actionStatus = text; actionError = "" }
    actionStatusTimer.restart()
  }

  Timer {
    id: actionStatusTimer
    interval: 3500
    repeat: false
    onTriggered: { root.actionStatus = ""; root.actionError = "" }
  }

  // ------------------------------------------------------------- status --

  function refresh() {
    if (!active || probing) return
    probing = true
    call(["status"], function(result) {
      root.probing = false
      root.probed = true
      if (!result.ok) {
        root.lastError = result.error
        return
      }
      root.lastError = ""
      var d = result.data
      root.authenticated = d.authenticated === true
      root.needsReauth = d.needsReauth === true
      root.email = d.email || ""
      root.mpvInstalled = d.mpv !== ""
      root.mprisInstalled = d.mpris === true
      root.lastItem = d.last || {}
      if (root.authenticated || d.running === true) root.refreshPlayer()
      if (root.authenticated) root.loadUpNextIfStale()
    })
  }

  function refreshIfStale() {
    if (!probed) { refresh(); return }
    refreshPlayer()
    if (authenticated) loadUpNextIfStale()
    else refresh()
  }

  // ------------------------------------------------------------- sign-in --

  function login(emailText, password) {
    var address = String(emailText || "").trim()
    if (address === "" || String(password || "") === "") {
      loginError = "Enter your Pocket Casts email and password."
      return false
    }
    if (loginRunning) return false
    loginRunning = true
    loginError = ""
    var payload = JSON.stringify({ email: address, password: String(password) }) + "\n"
    call(["login"], function(result) {
      root.loginRunning = false
      if (!result.ok) {
        root.loginError = result.error
        return
      }
      root.loginError = ""
      root.needsReauth = false
      root.authenticated = true
      root.email = result.data.email || address
      root.flash("Signed in as " + root.email, false)
      root.invalidateLists()
      root.refresh()
    }, payload)
    return true
  }

  function signOut() {
    call(["logout"], function(result) {
      root.authenticated = false
      root.needsReauth = false
      root.email = ""
      root.player = ({ active: false })
      root.lastItem = ({})
      root.upNext = []
      root.inProgress = []
      root.newReleases = []
      root.podcasts = []
      root.detail = null
      root.invalidateLists()
      root.refresh()
    })
  }

  function invalidateLists() {
    upNextLoadedAt = 0
    inProgressLoadedAt = 0
    newReleasesLoadedAt = 0
    podcastsLoadedAt = 0
  }

  // ------------------------------------------------------------- player --

  function refreshPlayer() {
    if (!active || playerLoading) return
    playerLoading = true
    var args = ["player"]
    if (!autoplay) args.push("--no-autoplay")
    call(args, function(result) {
      root.playerLoading = false
      if (!result.ok) {
        if (root.absorbAuthError(result)) return
        root.playerError = result.error
        return
      }
      root.playerError = ""
      root.applyPlayer(result.data)
    })
  }

  function applyPlayer(next) {
    var previousUuid = nowUuid
    player = next || { active: false }
    playerFetchedAt = Date.now()
    localPosition = Number(player.position) || 0
    if (nowItem && (nowItem.artPath || nowItem.art)) lastItem = nowItem
    // A new episode started (autoplay, or another device's queue): the queue
    // and the in-progress list have both changed under us.
    if (nowUuid !== "" && previousUuid !== "" && nowUuid !== previousUuid) {
      upNextLoadedAt = 0
      inProgressLoadedAt = 0
      if (panelOpen) loadUpNext()
    }
  }

  // Interpolate the position between polls so the slider moves every second.
  Timer {
    interval: 1000
    repeat: true
    running: root.isPlaying && !root.buffering
    onTriggered: {
      var elapsed = (Date.now() - root.playerFetchedAt) / 1000 * root.speed
      var next = (Number(root.player.position) || 0) + elapsed
      root.localPosition = root.duration > 0 ? Math.min(next, root.duration) : next
      // At the end: the bridge marks it played and moves on; ask soon.
      if (root.duration > 0 && next >= root.duration - 0.5) settleTimer.restart()
    }
  }

  // Poll cadence: brisk while a panel is open, steady while playing (the
  // bridge pushes the position to Pocket Casts from these polls and notices
  // the end of an episode), sleepy when nothing is playing.
  Timer {
    id: pollTimer
    interval: root.panelOpen ? 3000 : (root.isPlaying ? 5000 : 60000)
    repeat: true
    running: root.active && (root.authenticated || root.playerActive)
    onTriggered: root.refreshPlayer()
  }

  Timer {
    id: settleTimer
    interval: 600
    repeat: false
    onTriggered: root.refreshPlayer()
  }

  function settle() { settleTimer.restart() }

  function optimistic(patch) {
    var next = {}
    for (var k in player) next[k] = player[k]
    for (var p in patch) next[p] = patch[p]
    player = next
    playerFetchedAt = Date.now()
  }

  // A player action: the bridge answers with the new player state, so most
  // need no follow-up poll.
  function action(args, label, after) {
    actionRunning = true
    call(args, function(result) {
      root.actionRunning = false
      if (!result.ok) {
        if (root.absorbAuthError(result)) return
        root.flash(result.error, true)
        root.settle()
        return
      }
      if (result.data && result.data.active !== undefined) root.applyPlayer(result.data)
      else root.settle()
      if (label) root.flash(label, false)
      if (after) after(result.data)
    })
  }

  function playPause() {
    if (!authenticated && !playerActive) return false
    if (isPlaying) {
      optimistic({ playing: false, position: localPosition })
      action(["pause"])
    } else {
      if (playerActive) optimistic({ playing: true, position: localPosition })
      action(["resume"])
    }
    return true
  }

  function next() {
    if (!authenticated) return false
    action(["next"], "", function() { root.upNextLoadedAt = 0; root.loadUpNext() })
    return true
  }

  function stop() {
    action(["stop"])
  }

  function seek(seconds) {
    if (!playerActive) return
    var clamped = Math.max(0, Math.min(duration > 0 ? duration : seconds, seconds))
    optimistic({ position: clamped })
    localPosition = clamped
    action(["seek", String(Math.round(clamped))])
  }

  function skip(delta) {
    if (!playerActive) return false
    var target = Math.max(0, localPosition + delta)
    if (duration > 0) target = Math.min(target, duration - 1)
    optimistic({ position: target })
    localPosition = target
    action(["seek", "--relative", "--", String(delta)])
    return true
  }

  function skipBack() { return skip(-skipBackSeconds) }
  function skipForward() { return skip(skipForwardSeconds) }

  function setVolume(pct) {
    var v = Math.max(0, Math.min(100, Math.round(pct)))
    optimistic({ volume: v })
    volumeDebounce.pending = v
    volumeDebounce.restart()
  }

  Timer {
    id: volumeDebounce
    property int pending: -1
    interval: 180
    repeat: false
    onTriggered: if (pending >= 0) root.call(["volume", String(pending)], null)
  }

  function nudgeVolume(delta) { setVolume(volume + delta) }

  function cycleSpeed() {
    call(["speed", "cycle"], function(result) {
      if (!result.ok) { root.flash(result.error, true); return }
      root.optimistic({ speed: result.data.speed })
      root.flash("Speed " + Model.fmtSpeed(result.data.speed), false)
    })
  }

  function playItem(item, fromStart) {
    if (!item || !item.uuid) return
    var args = ["play", item.uuid]
    if (item.podcast) args.push("--podcast", item.podcast)
    if (fromStart) args.push("--from-start")
    optimistic({ active: true, playing: true, item: item, position: fromStart ? 0 : (item.playedUpTo || 0), duration: item.duration || 0 })
    localPosition = Number(player.position) || 0
    action(args, "", function() {
      root.upNextLoadedAt = 0
      root.inProgressLoadedAt = 0
      if (root.panelOpen) root.loadUpNext()
    })
  }

  // ------------------------------------------------------- episode actions --

  function queue(item, where) {
    if (!item || !item.uuid) return
    var args = ["queue", where, item.uuid]
    if (item.podcast) args.push("--podcast", item.podcast)
    var label = where === "remove" ? "Removed from Up Next" : (where === "next" ? "Playing next" : "Added to Up Next")
    call(args, function(result) {
      if (!result.ok) { if (!root.absorbAuthError(result)) root.flash(result.error, true); return }
      root.flash(label, false)
      root.loadUpNext(true)
    })
  }

  function toggleQueued(item) {
    if (!item) return
    queue(item, Model.containsUuid(upNext, item.uuid) ? "remove" : "last")
  }

  function markPlayed(item, played) {
    if (!item || !item.uuid || !item.podcast) return
    call(["mark", played ? "played" : "unplayed", item.uuid, "--podcast", item.podcast], function(result) {
      if (!result.ok) { if (!root.absorbAuthError(result)) root.flash(result.error, true); return }
      root.patchItem(item.uuid, { status: played ? Model.statusPlayed : Model.statusUnplayed, playedUpTo: 0 })
      root.flash(played ? "Marked as played" : "Marked as unplayed", false)
      if (played) root.loadUpNext(true)
    })
  }

  // Update one episode wherever it is listed, without a refetch.
  function patchItem(uuid, patch) {
    function patched(list) {
      var out = []
      for (var i = 0; i < (list || []).length; i++) {
        var item = list[i]
        if (item.uuid === uuid) {
          var copy = {}
          for (var k in item) copy[k] = item[k]
          for (var p in patch) copy[p] = patch[p]
          item = copy
        }
        out.push(item)
      }
      return out
    }
    upNext = patched(upNext)
    inProgress = patched(inProgress)
    newReleases = patched(newReleases)
    if (detail && detail.items) {
      var next = {}
      for (var d in detail) next[d] = detail[d]
      next.items = patched(detail.items)
      detail = next
    }
  }

  // ------------------------------------------------------------- lists --

  function loadList(kind, args, force) {
    var loadedAt = root[kind + "LoadedAt"]
    if (!authenticated || root[kind + "Loading"]) return
    if (!force && loadedAt > 0 && Date.now() - loadedAt < staleMs) return
    root[kind + "Loading"] = true
    root[kind + "Error"] = ""
    call(args, function(result) {
      root[kind + "Loading"] = false
      if (!result.ok) { if (!root.absorbAuthError(result)) root[kind + "Error"] = result.error; return }
      root[kind] = result.data.items || []
      root[kind + "LoadedAt"] = Date.now()
    })
  }

  function loadUpNext(force) { loadList("upNext", ["up-next"], force) }
  function loadUpNextIfStale() { loadUpNext(false) }
  function loadInProgress(force) { loadList("inProgress", ["in-progress"], force) }
  function loadNewReleases(force) { loadList("newReleases", ["new-releases"], force) }
  function loadPodcasts(force) { loadList("podcasts", force ? ["podcasts", "--force"] : ["podcasts"], force) }

  function loadTab(tab, force) {
    if (tab === "upnext") loadUpNext(force)
    else if (tab === "progress") loadInProgress(force)
    else if (tab === "new") loadNewReleases(force)
    else if (tab === "podcasts") loadPodcasts(force)
  }

  // ------------------------------------------------------------- detail --

  function openDetail(item) {
    if (!item || item.type !== "podcast") return false
    var serial = ++_detailSerial
    detail = { item: item, items: [], total: 0, loading: true, error: "" }
    call(["episodes", item.uuid], function(result) {
      if (serial !== root._detailSerial || !root.detail) return
      var next = {}
      for (var k in root.detail) next[k] = root.detail[k]
      next.loading = false
      if (!result.ok) {
        root.absorbAuthError(result)
        next.error = result.error
      } else {
        next.items = result.data.items || []
        next.total = Number(result.data.total) || next.items.length
        if (result.data.podcast && result.data.podcast.name) next.item = result.data.podcast
      }
      root.detail = next
    })
    return true
  }

  function closeDetail() {
    _detailSerial++
    detail = null
  }

  // ----------------------------------------------------------------- IPC --

  IpcHandler {
    // Only the shared instance answers IPC; the per-panel fallback stays quiet.
    enabled: root.active
    target: "pocketcasts"

    function playPause(): string { return root.playPause() ? "ok" : "unhandled" }
    function next(): string { return root.next() ? "ok" : "unhandled" }
    function skipBack(): string { return root.skipBack() ? "ok" : "unhandled" }
    function skipForward(): string { return root.skipForward() ? "ok" : "unhandled" }
    function stop(): string { root.stop(); return "ok" }
    function volumeUp(): string { root.nudgeVolume(5); return "ok" }
    function volumeDown(): string { root.nudgeVolume(-5); return "ok" }
    function cycleSpeed(): string { root.cycleSpeed(); return "ok" }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string {
      return JSON.stringify({
        authenticated: root.authenticated,
        active: root.playerActive,
        playing: root.isPlaying,
        title: root.nowItem ? root.nowItem.name : "",
        show: root.nowItem ? root.nowItem.show : "",
        position: Math.round(root.localPosition),
        duration: Math.round(root.duration),
        speed: root.speed
      })
    }
  }

  Timer {
    interval: 300000
    repeat: true
    running: root.active
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onActiveChanged: if (active && !probed) refresh()
}
