import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar chip: just the podcast glyph until an episode is loaded. While one
// is playing or paused it grows into the show's rounded cover plus a
// scrolling "Episode · Show" label; stopping shrinks it back to the glyph
// until something else is played. Hosts
// the full panel on click using the same Loader + hostWidget handoff
// omarchy.clock and ninepointlabs.spotify use, so this widget stands in for
// the panel as the bar's popout identity.
//
//   left   = open/close the panel
//   middle = play/pause
//   right  = skip forward
//   scroll = volume ±5
BarWidget {
  id: root
  moduleName: "ninepointlabs.pocketcasts"

  readonly property var service: panelLoader.item ? panelLoader.item.service : null
  readonly property bool authenticated: service ? service.authenticated === true : false
  readonly property bool playerActive: service ? service.playerActive === true : false
  readonly property bool isPlaying: service ? service.isPlaying === true : false
  readonly property var nowItem: service ? service.nowItem : null
  // Only a loaded episode (playing or paused) earns the cover; stopped or
  // idle, the chip is the bare glyph.
  readonly property var chipItem: playerActive ? nowItem : null
  readonly property string chipArt: Model.artSource(chipItem)
  readonly property string title: nowItem && nowItem.name ? nowItem.name : ""
  readonly property string show: nowItem && nowItem.show ? nowItem.show : ""
  readonly property string labelText: title !== "" ? (show !== "" ? title + "  ·  " + show : title) : ""

  readonly property bool showTitle: setting("showTitle", true) === true
  readonly property real maxLabelWidth: Style.space(Number(setting("maxLabelWidth", 180)) || 180)
  readonly property bool labelShown: showTitle && !vertical && playerActive && labelText !== ""
  readonly property bool artShown: chipArt !== "" && artImage.status !== Image.Error

  readonly property color chipColor: {
    if (!bar) return Color.foreground
    if (!authenticated && !playerActive) return Qt.darker(bar.barForeground, 1.7)
    if (isPlaying) return bar.barForeground
    return Qt.darker(bar.barForeground, 1.35)
  }

  function refresh() {
    if (service) service.refreshIfStale()
    if (panelLoader.item && panelLoader.item.refresh) panelLoader.item.refresh()
  }

  // ---- Panel popup. Shape contract for shell.summon/hide/toggle routing:
  //      Bar.findPanelWidget requires open/close/opened on the bar-widget root.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false

  // True if this widget's panel is open on any monitor — the IPC handler
  // lives on one instance, but the panel opens on whichever bar was used.
  function anyOpened() {
    var items = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) if (items[i] && items[i].opened === true) return true
    return false
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function togglePanel() { if (panelLoader.item) panelLoader.item.toggle() }

  readonly property real openPanelIndicatorWidth: button.width
  readonly property real openPanelIndicatorHeight: Math.max(Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    target: "ninepointlabs.pocketcasts"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }
    function isOpen(): string { return root.anyOpened() ? "true" : "false" }
    function refresh(): void { root.broadcast("refresh") }
    function playPause(): string { return root.service && root.service.playPause() ? "ok" : "unhandled" }
    function next(): string { return root.service && root.service.next() ? "ok" : "unhandled" }
    function skipBack(): string { return root.service && root.service.skipBack() ? "ok" : "unhandled" }
    function skipForward(): string { return root.service && root.service.skipForward() ? "ok" : "unhandled" }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Math.round(chipRow.implicitWidth + Style.spaceReal(horizontalMargin) * 2)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    horizontalMargin: root.labelShown ? 7 : 6
    tooltipText: root.playerActive && root.labelText !== ""
      ? (root.isPlaying ? "Pocket Casts · " : "Pocket Casts (paused) · ") + root.labelText
      : (root.authenticated ? "Pocket Casts" : "Pocket Casts — not signed in")

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.service) root.service.playPause() }
      else if (b === Qt.RightButton) { if (root.service) root.service.skipForward() }
      else root.togglePanel()
    }
    onWheelMoved: function(delta) {
      if (!root.service || !root.playerActive) return
      if (delta > 0) root.service.nudgeVolume(5)
      else if (delta < 0) root.service.nudgeVolume(-5)
    }

    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(6)

      // Cover thumbnail with a rounded mask; the glyph sits underneath and
      // shows through only until an image is available.
      Item {
        id: artBox
        readonly property real size: Style.bar.iconCanvas + Style.space(2)
        width: size
        height: size
        anchors.verticalCenter: parent.verticalCenter

        OpticalGlyph {
          anchors.fill: parent
          visible: !root.artShown
          text: Model.glyph.pocketcasts
          fontFamily: button.fontFamily
          fontSize: Style.bar.iconFont
          color: root.chipColor
        }

        Image {
          id: artImage
          anchors.fill: parent
          source: root.chipArt
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          smooth: true
          mipmap: true
          sourceSize.width: 64
          sourceSize.height: 64
          visible: false
          layer.enabled: true
        }

        Rectangle {
          id: artMask
          anchors.fill: parent
          // Follow the theme: rounded covers on rounded themes, square on sharp.
          radius: Style.cornerRadius > 0 ? Math.max(2, Math.round(artBox.size * 0.22)) : 0
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: parent
          visible: root.artShown
          source: artImage
          maskEnabled: true
          maskSource: artMask
          // Paused or idle: fade the cover the way the glyph dims.
          opacity: root.isPlaying ? 1.0 : (root.playerActive ? 0.72 : 0.5)
          Behavior on opacity { NumberAnimation { duration: 160 } }
        }
      }

      Item {
        id: scrollClip
        visible: root.labelShown
        width: root.labelShown ? Math.min(root.maxLabelWidth, labelItem.implicitWidth) : 0
        height: labelItem.implicitHeight
        clip: true
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: labelItem
          textFormat: Text.PlainText
          text: root.labelText
          color: root.chipColor
          font.family: button.fontFamily
          font.pixelSize: Style.font.body
          anchors.verticalCenter: parent.verticalCenter

          readonly property bool needsScroll: implicitWidth > scrollClip.width + 1

          // Marquee only while playing and the panel is closed; a paused
          // chip sits still like the rest of the bar.
          NumberAnimation on x {
            running: labelItem.needsScroll && root.isPlaying && !root.opened
            loops: Animation.Infinite
            duration: Math.max(6000, labelItem.implicitWidth * 28)
            from: scrollClip.width
            to: -labelItem.implicitWidth
            easing.type: Easing.Linear
          }

          onNeedsScrollChanged: if (!needsScroll) x = 0
        }
      }
    }
  }
}
