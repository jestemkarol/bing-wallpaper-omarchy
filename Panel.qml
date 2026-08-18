import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Bar button plus popup, in one entry point — the shape omarchy.dropbox uses.
// All fetching and applying lives in Service.qml; this reads its state and
// calls into it, so nothing here runs when the panel is closed.
Panel {
  id: root
  moduleName: "io.github.jestemkarol.bing-wallpaper"
  ipcTarget: "io.github.jestemkarol.bing-wallpaper"
  manageIpc: false

  // The service is a shell-wide singleton loaded from the same manifest. Bar
  // widgets are not handed it the way panel plugins are, so look it up.
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null

  readonly property var entries: service ? service.entries : []
  readonly property bool hasLibrary: entries.length > 0

  // Which day the panel is showing. Follows the wallpaper on screen when the
  // service owns it, and resets to the newest image otherwise.
  property string selectedDate: ""
  readonly property var selected: Model.entryForDate({ entries: entries }, selectedDate)
    || (hasLibrary ? entries[0] : null)
  readonly property var described: Model.describe(selected)
  readonly property bool selectedIsCurrent: selected && service && selected.file === service.currentBackground

  property bool settingsOpen: false
  property int cursor: 0
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: bar ? bar.accent : Color.accent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property real thumbWidth: Style.space(364)
  readonly property real thumbHeight: Math.round(thumbWidth * 9 / 16)

  // ------------------------------------------------------------------ actions

  function syncSelectionToBackground() {
    if (!service) return
    var index = Model.indexOfFile(entries, service.currentBackground)
    selectedDate = index !== -1 ? entries[index].date : (hasLibrary ? entries[0].date : "")
  }

  function stepDay(direction) {
    if (!hasLibrary) return
    var next = Model.step(entries, selectedDate, direction)
    if (next) selectedDate = next.date
  }

  function applySelected() {
    if (service && selected) service.applyEntry(selected)
  }

  function refresh() {
    if (service) service.sync(false)
  }

  function openCredit() {
    if (!selected || !selected.copyrightLink || !bar) return
    bar.run("xdg-open " + JSON.stringify(selected.copyrightLink))
  }

  // --------------------------------------------------------------- settings

  function setting(name, fallback) {
    var value = root.settings ? root.settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Settings live in this widget's shell.json entry. The service watches that
  // file, so writing here is also how the service learns about a change.
  function persist(key, value) {
    var entry = { id: root.moduleName }
    var current = root.settings || ({})
    for (var existing in current) if (existing !== "id") entry[existing] = current[existing]
    entry[key] = value

    root.settings = entry
    if (bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
      bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // ------------------------------------------------------------------ cursor

  // Keyboard focus order through the action row; the settings controls take
  // their own focus once the section is open.
  readonly property var cursorTargets: ["previous", "next", "apply", "refresh", "settings"]

  function moveCursor(dx, dy) {
    cursorActive = true
    var step = dx !== 0 ? dx : dy
    if (step === 0) return
    cursor = (cursor + step + cursorTargets.length) % cursorTargets.length
  }

  function activateCursor() {
    switch (cursorTargets[cursor]) {
      case "previous": stepDay(-1); break
      case "next": stepDay(1); break
      case "apply": applySelected(); break
      case "refresh": refresh(); break
      case "settings": settingsOpen = !settingsOpen; break
    }
  }

  function hasCursorOn(name) {
    return cursorActive && cursorTargets[cursor] === name
  }

  // ------------------------------------------------------------------- wiring

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    cursor = 0
    settingsOpen = false
    syncSelectionToBackground()
    if (service) service.refreshBackgroundPath()
    Qt.callLater(function () { keyCatcher.forceActiveFocus() })
  }

  Connections {
    target: root.service
    enabled: root.service !== null
    // A fresh library can arrive while the panel is open (the daily fetch, or
    // a market change); land on something real rather than a stale date.
    function onLibraryChanged() {
      if (!Model.entryForDate({ entries: root.entries }, root.selectedDate)) root.syncSelectionToBackground()
    }
    function onApplied() { root.syncSelectionToBackground() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    slotSize: Style.bar.iconSlot
    tooltipText: root.described.title || "Bing Wallpaper"

    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) { if (root.service) root.service.applyStep(1) }
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.thumbWidth)
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))
    popoutSwitching: root.popoutSwitching
    popoutSwitchClosing: root.popoutSwitchClosing

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onTextKey: function (t) {
        var key = String(t || "").toLowerCase()
        if (key === "h") root.stepDay(-1)
        else if (key === "l") root.stepDay(1)
        else if (key === "r") root.refresh()
        else if (key === "s") root.settingsOpen = !root.settingsOpen
        else if (key === "t" && root.hasLibrary) root.selectedDate = root.entries[0].date
        else if (key === "\r" || key === "\n") root.applySelected()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Bing Wallpaper"
            meta: root.hasLibrary ? root.described.date : "No images yet"
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: ""
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
                color: root.foreground
              }
            }
          }

          // ------------------------------------------------------ preview

          Item {
            id: thumbFrame
            width: parent.width
            height: root.thumbHeight
            visible: root.hasLibrary

            readonly property real corner: Style.cornerRadius

            Item {
              id: thumbMask
              anchors.fill: parent
              visible: false
              layer.enabled: thumbFrame.corner > 0
              Rectangle {
                anchors.fill: parent
                radius: thumbFrame.corner
                color: "white"
              }
            }

            Item {
              anchors.fill: parent
              // The mask only earns its layer when the theme actually rounds
              // corners; at radius 0 it would be a render target for nothing.
              layer.enabled: thumbFrame.corner > 0
              layer.smooth: true
              layer.effect: MultiEffect {
                maskEnabled: true
                maskSource: thumbMask
                maskThresholdMin: 0.5
                maskSpreadAtMin: 0.02
              }

              Rectangle {
                anchors.fill: parent
                color: Util.alpha(root.foreground, 0.08)
              }

              Image {
                id: thumb
                anchors.fill: parent
                source: root.selected ? Util.fileUrl(root.selected.file) : ""
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: true
                smooth: true
                mipmap: true
              }
            }

            // A quiet marker rather than a badge: the current wallpaper should
            // be recognizable at a glance without competing with the image.
            Rectangle {
              visible: root.selectedIsCurrent
              anchors { right: parent.right; top: parent.top; margins: Style.space(8) }
              width: currentLabel.implicitWidth + Style.space(12)
              height: currentLabel.implicitHeight + Style.space(6)
              radius: height / 2
              color: Util.alpha(Color.popups.background, 0.82)

              Text {
                id: currentLabel
                anchors.centerIn: parent
                text: "On screen"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ------------------------------------------------------ metadata

          Column {
            width: parent.width
            spacing: Style.spacing.labelGap
            visible: root.hasLibrary

            Text {
              width: parent.width
              text: root.described.title
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.described.description !== "" && root.described.description !== root.described.title
              text: root.described.description
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.described.credit !== ""
              text: root.described.credit
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap

              MouseArea {
                anchors.fill: parent
                enabled: root.selected && root.selected.copyrightLink !== ""
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openCredit()
              }
            }
          }

          // -------------------------------------------------------- empty

          Text {
            width: parent.width
            visible: !root.hasLibrary
            text: root.service && root.service.syncing
              ? "Fetching today's image…"
              : (root.service && root.service.lastError !== ""
                 ? root.service.lastError
                 : "Nothing downloaded yet. Press r to fetch.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
          }

          // ------------------------------------------------------- actions

          Item {
            width: parent.width
            height: actionRow.implicitHeight

            Row {
              id: actionRow
              anchors.left: parent.left
              spacing: Style.space(4)

              PanelActionButton {
                iconText: "‹"
                tooltipText: "Newer image"
                enabled: root.hasLibrary
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursorOn("previous")
                onClicked: root.stepDay(-1)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(64)
                text: root.hasLibrary ? Model.formatDateShort(root.selected.date) : "—"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                horizontalAlignment: Text.AlignHCenter
              }

              PanelActionButton {
                iconText: "›"
                tooltipText: "Older image"
                enabled: root.hasLibrary
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursorOn("next")
                onClicked: root.stepDay(1)
              }
            }

            Row {
              anchors.right: parent.right
              spacing: Style.space(4)

              PanelActionButton {
                iconText: ""
                tooltipText: root.selectedIsCurrent ? "Already your background" : "Set as background"
                enabled: root.hasLibrary && !root.selectedIsCurrent
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursorOn("apply")
                onClicked: root.applySelected()
              }

              PanelActionButton {
                iconText: ""
                tooltipText: "Check Bing for a new image"
                enabled: !(root.service && root.service.syncing)
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursorOn("refresh")
                onClicked: root.refresh()
              }

              PanelActionButton {
                iconText: ""
                tooltipText: root.settingsOpen ? "Close settings" : "Settings"
                foreground: root.foreground
                fontFamily: root.fontFamily
                hasCursor: root.hasCursorOn("settings")
                onClicked: root.settingsOpen = !root.settingsOpen
              }
            }
          }

          // ------------------------------------------------------ settings

          PanelSeparator {
            visible: root.settingsOpen
            foreground: root.foreground
          }

          Column {
            width: parent.width
            visible: root.settingsOpen
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Dropdown {
              width: parent.width
              label: "Region"
              value: root.setting("market", Model.DEFAULTS.market)
              options: ["auto"].concat(Model.MARKETS)
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function (value) { root.persist("market", value) }
            }

            Dropdown {
              width: parent.width
              label: "Resolution"
              value: root.setting("resolution", Model.DEFAULTS.resolution)
              options: ["UHD", "1920x1200", "1920x1080", "1366x768", "1280x720"]
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onChanged: function (value) { root.persist("resolution", value) }
            }

            Toggle {
              width: parent.width
              label: "Apply new images"
              description: "New images become your background as soon as they download."
              checked: root.setting("autoApply", Model.DEFAULTS.autoApply)
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.persist("autoApply", !checked)
            }

            Toggle {
              width: parent.width
              label: "Keep after theme switch"
              description: "Omarchy resets the background when the theme changes."
              checked: root.setting("reapplyAfterThemeChange", Model.DEFAULTS.reapplyAfterThemeChange)
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.persist("reapplyAfterThemeChange", !checked)
            }

            Toggle {
              width: parent.width
              label: "Shuffle the library"
              description: "Pick a random downloaded image instead of today's."
              checked: root.setting("randomFromLibrary", Model.DEFAULTS.randomFromLibrary)
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.persist("randomFromLibrary", !checked)
            }

            Toggle {
              width: parent.width
              label: "Notify on change"
              checked: root.setting("notify", Model.DEFAULTS.notify)
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.persist("notify", !checked)
            }

            NumberField {
              label: "Keep for (days)"
              value: root.setting("keepDays", Model.DEFAULTS.keepDays)
              from: 1
              to: 365
              stepSize: 1
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onModified: function (value) { root.persist("keepDays", value) }
            }

            Text {
              width: parent.width
              text: root.service
                ? (root.service.entries.length + " image" + (root.service.entries.length === 1 ? "" : "s") + " downloaded")
                : "Service is not running"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            text: "h/l day  ·  enter set  ·  r refresh  ·  s settings"
            color: Qt.darker(root.dim, 1.2)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }
}
