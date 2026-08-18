import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Owns everything that has to keep happening whether or not the bar widget is
// on screen: fetching, scheduling, applying, and putting the image back after
// a theme switch. Panel.qml reads state off this and calls into it; it never
// runs the sync script itself.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null

  readonly property string pluginId: "io.github.jestemkarol.bing-wallpaper"
  readonly property string home: Quickshell.env("HOME")
  readonly property string dataDir: home + "/.local/share/omarchy-bing-wallpaper"
  readonly property string imagesDir: dataDir + "/images"
  readonly property string stateFile: dataDir + "/state.json"
  readonly property string backgroundLink: home + "/.local/state/omarchy/current/background"

  // Qt.resolvedUrl hands back a file:// URL; Process wants a plain path.
  readonly property string syncScript: String(Qt.resolvedUrl("bing-wallpaper-sync")).replace(/^file:\/\//, "")

  property var settings: Model.normalizeSettings(null)
  property var library: Model.emptyState()
  readonly property var entries: library.entries
  readonly property var newest: entries.length > 0 ? entries[0] : null

  property string currentBackground: ""
  readonly property bool ownsBackground: currentBackground !== ""
    && currentBackground.indexOf(imagesDir + "/") === 0

  property bool syncing: false
  // Set when a sync finishes and its result should go up on screen. The apply
  // waits for the reloaded library rather than running straight away: the
  // state file is read asynchronously, so at the moment the script exits the
  // entries here are still the ones from before it ran.
  property bool applyPending: false
  property int failureCount: 0
  property string lastError: ""
  property double lastSyncAt: 0

  // `library` is a property, so libraryChanged() already exists — Panel.qml
  // listens on that rather than a hand-rolled duplicate.
  signal applied(string file)

  // ------------------------------------------------------------------ fetch

  function sync(force) {
    if (syncProc.running) return
    root.syncing = true
    syncProc.applyAfter = force === true ? true : root.settings.autoApply
    syncProc.command = [
      "bash", root.syncScript,
      "--dir", root.dataDir,
      "--market", Model.resolveMarket(root.settings.market, Qt.locale().name),
      "--resolution", root.settings.resolution,
      "--keep", String(root.settings.keepDays)
    ]
    syncProc.running = true
  }

  function reloadLibrary() {
    stateView.reload()
  }

  // Emitted after every successful apply so the panel can follow along.

  // ------------------------------------------------------------------ apply

  function applyEntry(entry) {
    if (!entry || !entry.file) return false
    applyProc.pendingEntry = entry
    applyProc.command = ["omarchy-theme-bg-set", entry.file]
    applyProc.running = true
    return true
  }

  function applyDate(date) {
    return applyEntry(Model.entryForDate(root.library, date))
  }

  function applyToday() {
    return applyEntry(root.newest)
  }

  function applyStep(direction) {
    var from = root.ownsBackground ? currentEntryDate() : ""
    return applyEntry(Model.step(root.entries, from, direction))
  }

  function applyRandom() {
    return applyEntry(Model.randomEntry(root.entries, root.currentBackground))
  }

  // Which library image is on screen right now, if any.
  function currentEntryDate() {
    var index = Model.indexOfFile(root.entries, root.currentBackground)
    return index === -1 ? "" : root.entries[index].date
  }

  // What a fresh sync should put up: today's image, or a random one from the
  // library when the user asked to shuffle.
  function autoTarget() {
    return root.settings.randomFromLibrary
      ? Model.randomEntry(root.entries, root.currentBackground)
      : root.newest
  }

  function notify(entry) {
    if (!root.settings.notify || !entry) return
    var described = Model.describe(entry)
    notifyProc.command = ["omarchy-notification-send",
      "Bing Wallpaper", described.title || described.date, "-t", "4000"]
    notifyProc.running = true
  }

  function refreshBackgroundPath() {
    if (!readlinkProc.running) readlinkProc.running = true
  }

  function rescheduleCheck() {
    checkTimer.interval = Model.nextCheckDelay(root.library, Date.now(), root.failureCount)
    checkTimer.restart()
  }

  function status() {
    var described = Model.describe(root.newest)
    return {
      market: Model.resolveMarket(root.settings.market, Qt.locale().name),
      resolution: root.settings.resolution,
      syncing: root.syncing,
      library: root.entries.length,
      lastSyncAt: root.lastSyncAt,
      lastError: root.lastError,
      failureCount: root.failureCount,
      nextCheckInSeconds: Math.round(checkTimer.interval / 1000),
      background: root.currentBackground,
      ownsBackground: root.ownsBackground,
      current: root.ownsBackground ? currentEntryDate() : "",
      today: root.newest ? { date: root.newest.date, title: described.title, file: root.newest.file } : null
    }
  }

  // ---------------------------------------------------------------- settings

  // shell.qml hands service plugins only `shell`, so settings come from
  // shell.json directly. Watching it also means hand edits and the panel's own
  // writes land here through the same path.
  FileView {
    id: shellConfigView
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.adoptSettings(Model.settingsFromShellConfig(text(), root.pluginId))
    onLoadFailed: root.adoptSettings(Model.normalizeSettings(null))
  }

  function adoptSettings(next) {
    var previous = root.settings
    root.settings = next
    if (!root.ready) return
    // Only a market, resolution or retention change alters what is on disk.
    if (Model.settingsAffectLibrary(previous, next)) sync(false)
  }

  property bool ready: false

  // ------------------------------------------------------------------- state

  FileView {
    id: stateView
    path: root.stateFile
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.adoptLibrary(Model.parseState(text()))
    onLoadFailed: root.adoptLibrary(Model.emptyState())
  }

  function adoptLibrary(next) {
    root.library = next
    root.rescheduleCheck()
    if (root.applyPending) {
      root.applyPending = false
      applyPendingTimeout.stop()
      root.applyAutoTarget()
    }
  }

  // A reload that changes nothing may not produce an onLoaded; without this
  // the pending apply would sit there until the next sync.
  Timer {
    id: applyPendingTimeout
    interval: 3000
    repeat: false
    onTriggered: {
      if (!root.applyPending) return
      root.applyPending = false
      root.applyAutoTarget()
    }
  }

  // --------------------------------------------------------------- processes

  Process {
    id: syncProc
    property bool applyAfter: false

    stdout: StdioCollector { id: syncOut; waitForEnd: true }
    stderr: StdioCollector { id: syncErr; waitForEnd: true }

    onExited: function (exitCode) {
      root.syncing = false
      root.lastSyncAt = Date.now()

      if (exitCode === 0) {
        root.failureCount = 0
        root.lastError = ""
      } else {
        root.failureCount += 1
        root.lastError = String(syncErr.text || "").trim() || ("sync exited " + exitCode)
        console.warn("bing-wallpaper: " + root.lastError)
      }

      if (exitCode === 0 && applyAfter) {
        root.applyPending = true
        applyPendingTimeout.restart()
      } else {
        root.rescheduleCheck()
      }

      // The state file is rewritten even on a partial failure, so reload
      // regardless — a day that did download should still reach the panel.
      stateView.reload()
    }
  }

  function applyAutoTarget() {
    var target = autoTarget()
    if (target && target.file !== root.currentBackground) applyEntry(target)
  }

  Process {
    id: applyProc
    property var pendingEntry: null

    onExited: function (exitCode) {
      if (exitCode === 0 && pendingEntry) {
        root.currentBackground = pendingEntry.file
        root.applied(pendingEntry.file)
        root.notify(pendingEntry)
      }
      pendingEntry = null
      root.refreshBackgroundPath()
    }
  }

  Process {
    id: readlinkProc
    command: ["readlink", "-f", root.backgroundLink]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.currentBackground = String(text || "").trim()
    }
  }

  Process { id: notifyProc }

  // ------------------------------------------------------------------ timers

  // Interval is recomputed on every library change and every sync outcome; see
  // Model.nextCheckDelay for why it is clamped rather than aimed exactly.
  Timer {
    id: checkTimer
    interval: 6 * 60 * 60 * 1000
    repeat: false
    running: false
    onTriggered: root.sync(false)
  }

  // Cheap enough to run forever, and it is what tells us the user picked a
  // different wallpaper by hand — which is the signal that stops us putting
  // the Bing image back after the next theme switch.
  Timer {
    interval: 5 * 60 * 1000
    repeat: true
    running: true
    onTriggered: root.refreshBackgroundPath()
  }

  // ------------------------------------------------------- theme reapply

  // omarchy-theme-set points the background symlink at one of the new theme's
  // images. If the Bing image was up beforehand, put it back once the theme
  // transition has settled — and if it was not, leave the user's choice alone.
  property string themeName: ""
  property string reapplyFile: ""

  FileView {
    id: themeView
    path: root.home + "/.local/state/omarchy/current/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.onThemeNameRead(String(text() || "").trim())
    onLoadFailed: root.themeName = ""
  }

  function onThemeNameRead(name) {
    var previous = root.themeName
    root.themeName = name
    if (!previous || previous === name) return
    if (!root.settings.reapplyAfterThemeChange) return
    if (!root.ownsBackground) return

    root.reapplyFile = root.currentBackground
    reapplyTimer.restart()
  }

  Timer {
    id: reapplyTimer
    // Long enough for omarchy-theme-set to finish its own background
    // transition; re-applying mid-animation leaves the old image on screen.
    interval: 1800
    repeat: false
    onTriggered: {
      var index = Model.indexOfFile(root.entries, root.reapplyFile)
      if (index !== -1) root.applyEntry(root.entries[index])
      root.reapplyFile = ""
    }
  }

  // --------------------------------------------------------------------- ipc

  IpcHandler {
    target: "bing-wallpaper"

    function status(): string {
      return JSON.stringify(root.status(), null, 2)
    }

    function refresh(): string {
      root.sync(false)
      return "syncing"
    }

    function today(): string {
      return root.applyToday() ? "applied" : "library is empty"
    }

    function next(): string {
      return root.applyStep(1) ? "applied" : "library is empty"
    }

    function previous(): string {
      return root.applyStep(-1) ? "applied" : "library is empty"
    }

    function random(): string {
      return root.applyRandom() ? "applied" : "library is empty"
    }

    function apply(date: string): string {
      return root.applyDate(date) ? "applied" : ("no image for " + date)
    }

    function list(): string {
      var out = []
      for (var i = 0; i < root.entries.length; i++) {
        var described = Model.describe(root.entries[i])
        out.push({ date: root.entries[i].date, title: described.title, file: root.entries[i].file })
      }
      return JSON.stringify(out, null, 2)
    }
  }

  Component.onCompleted: {
    refreshBackgroundPath()
    // shell.json and state.json both land through their FileViews; the first
    // sync waits a beat so it runs with real settings rather than defaults.
    startupTimer.start()
  }

  Timer {
    id: startupTimer
    interval: 1200
    repeat: false
    onTriggered: {
      root.ready = true
      root.sync(false)
    }
  }
}
