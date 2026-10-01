import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The Pocket Casts panel: a now-playing hero (cover, progress, skip back /
// play / skip forward / next, speed, volume) and four tabs — Up Next, In
// Progress, New, Podcasts — that all render into one flat row list so a
// single keyboard cursor walks whichever is showing. A podcast drills into
// its episode list.
//
// IPC lives on BarWidget.qml; this component only needs moduleName so the
// shell can inject bar/settings/anchorItem/hostWidget into it.
Panel {
  id: root
  moduleName: "ninepointlabs.pocketcasts"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // One service per shell — every bar widget and every open panel reads the
  // same instance. A shell without service support gets a local one.
  readonly property var sharedService: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(moduleName) : null
  readonly property var service: sharedService || localService

  function pushSettings() { if (service) service.settings = settings }
  onSettingsChanged: pushSettings()
  onServiceChanged: pushSettings()
  Component.onCompleted: pushSettings()

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 2.1)

  // ---------------------------------------------------------------- state --

  property string currentTab: setting("defaultTab", "upnext")
  property int cursorIndex: -1
  property bool countedOpen: false
  property bool _returnFired: false

  readonly property bool authenticated: service ? service.authenticated === true : false
  readonly property bool needsSetup: service && service.probed && !authenticated
  readonly property var detail: service ? service.detail : null
  readonly property bool detailOpen: detail !== null && detail !== undefined
  readonly property bool playerActive: service ? service.playerActive : false
  readonly property bool isPlaying: service ? service.isPlaying : false
  readonly property var nowItem: service ? service.nowItem : null
  readonly property var heroItem: nowItem || (service && service.lastItem && service.lastItem.uuid ? service.lastItem : null)
  readonly property string nowUuid: service ? service.nowUuid : ""
  readonly property real duration: service ? service.duration : 0
  readonly property real position: service ? service.localPosition : 0
  readonly property string heroArt: Model.artSource(heroItem)

  readonly property var rows: computeRows()

  function computeRows() {
    if (!service || !authenticated) return []
    if (detailOpen) return Model.detailRows(detail)
    if (currentTab === "upnext") return Model.upNextRows(service.upNext, nowUuid, service.upNextLoading, service.upNextError)
    if (currentTab === "progress") return Model.listRows(service.inProgress, service.inProgressLoading, service.inProgressError, "Nothing in progress.")
    if (currentTab === "new") return Model.listRows(service.newReleases, service.newReleasesLoading, service.newReleasesError, "No new episodes from your shows.")
    if (currentTab === "podcasts") return Model.listRows(service.podcasts, service.podcastsLoading, service.podcastsError, "You don't follow any shows yet. Subscribe in Pocket Casts and they show up here.")
    return []
  }

  // Keep the keyboard cursor on a real row: land on the first item whenever
  // the list changes under it (tab switch, results arriving, detail opening).
  onRowsChanged: {
    if (cursorIndex < 0 || cursorIndex >= rows.length || rows[cursorIndex].kind !== "item") cursorIndex = Model.firstItemIndex(rows, 0, 1)
  }

  readonly property string statusText: {
    if (!service) return ""
    if (service.actionError !== "") return service.actionError
    if (service.actionStatus !== "") return service.actionStatus
    if (service.playerError !== "") return service.playerError
    if (service.lastError !== "") return service.lastError
    if (!authenticated) return ""
    if (!service.mpvInstalled) return "mpv is not installed — run: omarchy pkg add mpv"
    if (service.buffering) return "Buffering…"
    if (playerActive) return (isPlaying ? "Playing" : "Paused") + (service.speed !== 1 ? " at " + Model.fmtSpeed(service.speed) : "")
    if (service.email !== "") return "Signed in as " + service.email
    return "Signed in"
  }
  readonly property bool statusIsError: service && (service.actionError !== "" || service.playerError !== "" || service.lastError !== "" || !service.mpvInstalled)

  // ------------------------------------------------------------ actions --

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function setTab(name) {
    if (service) service.closeDetail()
    if (currentTab !== name) {
      currentTab = name
      persistSettings({ defaultTab: name })
    }
    if (service) service.loadTab(name, false)
    cursorIndex = Model.firstItemIndex(rows, 0, 1)
    Qt.callLater(function() { if (listFlick) listFlick.contentY = 0 })
  }

  function stepTab(delta) {
    setTab(Model.tabAt(Model.tabIndex(currentTab) + delta))
  }

  function moveCursor(delta) {
    if (!Model.hasItems(rows)) return
    if (cursorIndex >= 0) {
      // Stop at the ends rather than wrapping, so a long list can't surprise you.
      var probe = cursorIndex + delta
      var found = -1
      while (probe >= 0 && probe < rows.length) {
        if (rows[probe].kind === "item") { found = probe; break }
        probe += delta
      }
      if (found < 0) return
      cursorIndex = found
    } else {
      cursorIndex = Model.firstItemIndex(rows, delta > 0 ? 0 : rows.length - 1, delta)
    }
    ensureCursorVisible()
  }

  function ensureCursorVisible() {
    if (cursorIndex < 0 || !listFlick) return
    var delegate = rowsRepeater.itemAt(cursorIndex)
    if (!delegate) return
    var top = delegate.y
    var bottom = delegate.y + delegate.height
    if (top < listFlick.contentY) listFlick.contentY = Math.max(0, top - Style.space(4))
    else if (bottom > listFlick.contentY + listFlick.height) listFlick.contentY = Math.min(Math.max(0, listFlick.contentHeight - listFlick.height), bottom - listFlick.height + Style.space(4))
  }

  function cursorItem() {
    if (cursorIndex < 0 || cursorIndex >= rows.length || rows[cursorIndex].kind !== "item") return null
    return rows[cursorIndex].item
  }

  function activateRow(index) {
    if (index < 0 || index >= rows.length || rows[index].kind !== "item" || !service) return
    var item = rows[index].item
    if (item.type === "podcast") {
      service.openDetail(item)
      Qt.callLater(function() { if (listFlick) listFlick.contentY = 0 })
      return
    }
    if (item.uuid === nowUuid) service.playPause()
    else service.playItem(item, false)
  }

  function queueCursor() {
    var item = cursorItem()
    if (item && item.type === "episode" && service) service.toggleQueued(item)
  }

  function markCursor() {
    var item = cursorItem()
    if (item && item.type === "episode" && service) service.markPlayed(item, item.status !== Model.statusPlayed)
  }

  function goBack() {
    if (!service || !detailOpen) return false
    service.closeDetail()
    cursorIndex = Model.firstItemIndex(rows, 0, 1)
    return true
  }

  function refresh() {
    if (!service) return
    service.refresh()
    service.loadTab(currentTab, true)
    if (detailOpen && detail.item) service.openDetail(detail.item)
  }

  function signIn() {
    if (!service) return
    if (service.login(emailField.text, passwordField.text)) passwordField.text = ""
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function noteOpen(isOpen) {
    if (!service) return
    if (isOpen && !countedOpen) { service.openPanels += 1; countedOpen = true }
    else if (!isOpen && countedOpen) { service.openPanels = Math.max(0, service.openPanels - 1); countedOpen = false }
  }

  Component.onDestruction: noteOpen(false)

  implicitWidth: 1
  implicitHeight: 1

  onOpenedChanged: {
    noteOpen(opened)
    if (!opened) {
      if (service) service.closeDetail()
      passwordField.text = ""
      return
    }
    if (service) {
      service.refreshIfStale()
      service.loadTab(currentTab, false)
      if (currentTab !== "upnext") service.loadUpNext(false)
    }
    cursorIndex = Model.firstItemIndex(rows, 0, 1)
    if (listFlick) listFlick.contentY = 0
    Qt.callLater(function() {
      if (root.needsSetup) emailField.forceActiveFocus()
      else keyCatcher.forceActiveFocus()
    })
  }

  Service {
    id: localService
    active: root.sharedService === null
  }

  // ------------------------------------------------------------- pieces --

  // Cover art with rounded corners and a glyph placeholder. Reads root for
  // colors so callers only ever set `source` and `placeholder`.
  component RoundedArt: Item {
    id: art
    property string source: ""
    property string placeholder: Model.glyph.podcast
    property real cornerRadius: Style.cornerRadius > 0 ? Math.max(3, Math.round(width * 0.12)) : 0
    readonly property bool showsImage: source !== "" && image.status === Image.Ready

    Rectangle {
      anchors.fill: parent
      radius: art.cornerRadius
      color: Style.normalFillFor(root.foreground, root.accent)
      border.width: Style.spacing.hairline
      border.color: Style.normalBorderFor(root.foreground, root.accent)
      visible: !art.showsImage
    }

    Text {
      textFormat: Text.PlainText
      anchors.centerIn: parent
      visible: !art.showsImage
      text: art.placeholder
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Math.max(Style.font.body, Math.round(art.width * 0.42))
    }

    Image {
      id: image
      anchors.fill: parent
      source: art.source
      fillMode: Image.PreserveAspectCrop
      asynchronous: true
      smooth: true
      mipmap: true
      sourceSize.width: 320
      sourceSize.height: 320
      visible: false
      layer.enabled: true
    }

    Rectangle {
      id: mask
      anchors.fill: parent
      radius: art.cornerRadius
      visible: false
      layer.enabled: true
    }

    MultiEffect {
      anchors.fill: parent
      visible: art.showsImage
      source: image
      maskEnabled: true
      maskSource: mask
    }
  }

  // A transport button: icon-only, dims when it can't act.
  component TransportButton: Button {
    property bool available: true
    foreground: root.foreground
    accent: root.accent
    fontFamily: root.fontFamily
    horizontalPadding: Style.space(8)
    verticalPadding: Style.space(5)
    enabled: available
    opacity: available ? 1.0 : 0.4
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(470))
    contentHeight: panel.fittedContentHeight(
      fixedContent.implicitHeight + content.spacing + (root.needsSetup ? 0 : Math.max(Style.space(180), listColumn.implicitHeight + Style.space(6))),
      Style.space(760))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: emailField.activeFocus || passwordField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx < 0 && root.detailOpen) root.goBack()
        else if (dx !== 0 && !root.detailOpen) root.stepTab(dx)
      }
      onReturnRequested: { root._returnFired = true; root.activateRow(root.cursorIndex) }
      onActivateRequested: {
        if (root._returnFired) { root._returnFired = false; return }
        if (root.service) root.service.playPause()
      }
      onCloseRequested: {
        if (root.goBack()) return
        root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (!root.service || !root.authenticated) return
        if (t === "1") root.setTab("upnext")
        else if (t === "2") root.setTab("progress")
        else if (t === "3") root.setTab("new")
        else if (t === "4") root.setTab("podcasts")
        else if (t === "n") root.service.next()
        else if (t === "s" && root.playerActive) root.service.stop()
        else if (t === "b" || t === ",") root.service.skipBack()
        else if (t === "f" || t === ".") root.service.skipForward()
        else if (t === "x") root.service.cycleSpeed()
        else if (t === "q") root.queueCursor()
        else if (t === "m") root.markCursor()
        else if (t === "r") root.refresh()
        else if (t === "+" || t === "=") root.service.nudgeVolume(5)
        else if (t === "-") root.service.nudgeVolume(-5)
      }

      ColumnLayout {
        id: content
        anchors.fill: parent
        spacing: Style.space(10)

        Column {
          id: fixedContent
          Layout.fillWidth: true
          spacing: Style.space(10)

          // ---------------------------------------------------- header --
          Item {
            width: parent.width
            implicitHeight: Math.max(titleColumn.implicitHeight, headerActions.implicitHeight)

            Column {
              id: titleColumn
              anchors.left: parent.left
              anchors.right: headerActions.left
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Row {
                spacing: Style.space(6)
                Text {
                  textFormat: Text.PlainText
                  text: Model.glyph.pocketcasts
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  textFormat: Text.PlainText
                  text: "POCKET CASTS"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                  font.letterSpacing: 1
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              Text {
                visible: text !== ""
                width: parent.width
                text: root.statusText
                textFormat: Text.PlainText
                color: root.statusIsError ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
            }

            Row {
              id: headerActions
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              PanelActionButton {
                visible: root.authenticated
                iconText: root.service && root.service.busy ? Model.glyph.refreshing : Model.glyph.refresh
                tooltipText: "Refresh (r)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: !root.service || !root.service.busy
                onClicked: root.refresh()
              }

              PanelActionButton {
                visible: root.authenticated
                iconText: Model.glyph.signOut
                tooltipText: root.service && root.service.email !== "" ? "Sign out " + root.service.email : "Sign out"
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: if (root.service) root.service.signOut()
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------- sign-in card --
          Column {
            visible: root.needsSetup
            width: parent.width
            spacing: Style.space(10)
            topPadding: Style.space(6)
            bottomPadding: Style.space(8)

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: root.service && root.service.needsReauth ? "Your Pocket Casts session expired" : "Sign in to Pocket Casts"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.Wrap
            }

            TextField {
              id: emailField
              width: parent.width
              placeholderText: "Email"
              text: root.service ? root.service.email : ""
              foreground: root.foreground
              accent: root.accent
              font.family: root.fontFamily
              enabled: !(root.service && root.service.loginRunning)
              Keys.onReturnPressed: passwordField.forceActiveFocus()
              Keys.onEscapePressed: keyCatcher.forceActiveFocus()
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              TextField {
                id: passwordField
                width: parent.width - signInButton.width - parent.spacing
                placeholderText: "Password"
                password: true
                foreground: root.foreground
                accent: root.accent
                font.family: root.fontFamily
                enabled: !(root.service && root.service.loginRunning)
                Keys.onReturnPressed: root.signIn()
                Keys.onEscapePressed: { text = ""; keyCatcher.forceActiveFocus() }
              }

              Button {
                id: signInButton
                text: root.service && root.service.loginRunning ? "Signing in…" : "Sign in"
                bordered: true
                foreground: root.foreground
                background: Color.popups.background
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.body
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                anchors.verticalCenter: parent.verticalCenter
                enabled: !(root.service && root.service.loginRunning)
                onClicked: root.signIn()
              }
            }

            Text {
              visible: root.service && root.service.loginError !== ""
              width: parent.width
              textFormat: Text.PlainText
              text: root.service ? root.service.loginError : ""
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            Repeater {
              model: Model.signInNotes

              Text {
                required property var modelData
                width: parent.width
                textFormat: Text.PlainText
                text: modelData
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.Wrap
              }
            }

            Text {
              visible: root.service && !root.service.mpvInstalled
              width: parent.width
              textFormat: Text.PlainText
              text: "Audio plays through mpv, which isn't installed. Run: omarchy pkg add mpv"
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }
          }

          // -------------------------------------------------------- hero --
          Column {
            visible: root.authenticated
            width: parent.width
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(12)

              RoundedArt {
                id: heroArt
                width: Style.space(84)
                height: Style.space(84)
                source: root.heroArt
                placeholder: Model.glyph.pocketcasts
                opacity: root.playerActive ? 1.0 : 0.55

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: if (root.service) root.service.playPause()
                }
              }

              Column {
                width: parent.width - heroArt.width - parent.spacing
                spacing: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.heroItem ? root.heroItem.name : "Nothing playing"
                  color: root.playerActive ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.heading
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  visible: text !== ""
                  text: {
                    if (!root.heroItem) return "Pick an episode below, or press space to resume Up Next"
                    var parts = Model.joinParts([root.heroItem.show, Model.fmtDate(root.heroItem.published)])
                    return root.playerActive ? parts : (parts !== "" ? "Last played · " + parts : "Last played")
                  }
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight
                }

                Item { width: 1; height: Style.space(2) }

                PanelSlider {
                  id: progressSlider
                  width: parent.width
                  bar: root.bar
                  minimum: 0
                  maximum: Math.max(1, root.duration)
                  value: root.position
                  step: 10
                  integer: true
                  enabled: root.playerActive && root.duration > 0
                  opacity: enabled ? 1.0 : 0.4
                  implicitHeight: Style.space(18)
                  knobSize: Style.space(12)
                  trackHeight: Style.space(4)
                  onReleased: function(v) { if (root.service) root.service.seek(v) }
                }

                Item {
                  width: parent.width
                  height: elapsed.implicitHeight

                  Text {
                    textFormat: Text.PlainText
                    id: elapsed
                    anchors.left: parent.left
                    text: Model.fmtTime(progressSlider.dragging ? progressSlider.liveValue : root.position)
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    text: root.duration > 0 ? "-" + Model.fmtTime(Math.max(0, root.duration - (progressSlider.dragging ? progressSlider.liveValue : root.position))) : "–:––"
                    color: root.faint
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // Transport on the left, speed and volume on the right.
            Item {
              width: parent.width
              height: transport.implicitHeight

              Row {
                id: transport
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)

                TransportButton {
                  iconText: Model.glyph.skipBack
                  tooltipText: "Back " + (root.service ? root.service.skipBackSeconds : 10) + "s (b)"
                  available: root.playerActive
                  onClicked: if (root.service) root.service.skipBack()
                }

                Button {
                  iconText: root.isPlaying ? Model.glyph.pause : Model.glyph.play
                  tooltipText: root.isPlaying ? "Pause (space)" : "Play (space)"
                  bordered: true
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  iconSize: Style.font.iconLarge
                  horizontalPadding: Style.space(14)
                  verticalPadding: Style.space(4)
                  onClicked: if (root.service) root.service.playPause()
                }

                TransportButton {
                  iconText: Model.glyph.stop
                  tooltipText: "Stop (s)"
                  available: root.playerActive
                  onClicked: if (root.service) root.service.stop()
                }

                TransportButton {
                  iconText: Model.glyph.skipForward
                  tooltipText: "Forward " + (root.service ? root.service.skipForwardSeconds : 30) + "s (f)"
                  available: root.playerActive
                  onClicked: if (root.service) root.service.skipForward()
                }

                TransportButton {
                  iconText: Model.glyph.next
                  tooltipText: "Next in Up Next (n)"
                  available: root.service && root.service.upNext.length > (root.playerActive ? 1 : 0)
                  onClicked: if (root.service) root.service.next()
                }

                TransportButton {
                  text: Model.fmtSpeed(root.service ? root.service.speed : 1)
                  tooltipText: "Playback speed (x)"
                  selected: root.service && root.service.speed !== 1
                  fontSize: Style.font.caption
                  onClicked: if (root.service) root.service.cycleSpeed()
                }
              }

              Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: Model.volumeGlyph(root.service ? root.service.volume : 100)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(18)
                  horizontalAlignment: Text.AlignHCenter

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.service) root.service.setVolume(root.service.volume === 0 ? 70 : 0)
                  }
                }

                PanelSlider {
                  width: Style.space(90)
                  bar: root.bar
                  minimum: 0
                  maximum: 100
                  step: 5
                  integer: true
                  value: root.service ? root.service.volume : 100
                  implicitHeight: Style.space(18)
                  knobSize: Style.space(12)
                  trackHeight: Style.space(4)
                  anchors.verticalCenter: parent.verticalCenter
                  onMoved: function(v) { if (root.service) root.service.setVolume(v) }
                  onReleased: function(v) { if (root.service) root.service.setVolume(v) }
                }
              }
            }
          }

          PanelSeparator { visible: root.authenticated; foreground: root.foreground }

          // ---------------------------------------------------- tabs --
          Row {
            visible: root.authenticated && !root.detailOpen
            width: parent.width
            spacing: Style.space(2)

            Repeater {
              model: Model.tabs

              Button {
                required property var modelData
                iconText: modelData.icon
                text: modelData.label
                selected: root.currentTab === modelData.key
                tooltipText: modelData.hint
                foreground: root.foreground
                background: "transparent"
                accent: root.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                iconSize: Style.font.bodySmall
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                onClicked: root.setTab(modelData.key)
              }
            }
          }

          // -------------------------------------------- detail header --
          Item {
            visible: root.authenticated && root.detailOpen
            width: parent.width
            implicitHeight: detailRow.implicitHeight

            Row {
              id: detailRow
              width: parent.width
              spacing: Style.space(10)

              PanelActionButton {
                iconText: Model.glyph.back
                tooltipText: "Back (esc / h)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.goBack()
              }

              RoundedArt {
                id: detailArt
                width: Style.space(52)
                height: Style.space(52)
                source: root.detailOpen ? Model.artSource(root.detail.item) : ""
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - detailArt.width - Style.space(22) - parent.spacing * 2
                spacing: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.detailOpen && root.detail.item ? root.detail.item.name : ""
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.detailOpen && root.detail.item ? (root.detail.item.author || "") : ""
                  visible: text !== ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }
          }
        }

        // ---------------------------------------------------------- list --
        Flickable {
          id: listFlick
          visible: root.authenticated
          Layout.fillWidth: true
          Layout.fillHeight: true
          contentWidth: width
          contentHeight: listColumn.implicitHeight
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          Column {
            id: listColumn
            width: listFlick.width
            spacing: Style.space(2)

            Repeater {
              id: rowsRepeater
              model: root.rows

              Item {
                id: rowItem
                required property var modelData
                required property int index
                readonly property bool isItem: modelData.kind === "item"
                readonly property var item: isItem ? modelData.item : null
                readonly property bool isEpisode: isItem && item.type === "episode"
                readonly property bool hasCursor: isItem && root.cursorIndex === index
                readonly property bool isNow: isEpisode && item.uuid === root.nowUuid
                readonly property bool queued: isEpisode && root.service && Model.containsUuid(root.service.upNext, item.uuid)
                readonly property bool played: isEpisode && item.status === Model.statusPlayed
                readonly property real progress: isEpisode ? Model.progressFraction(item) : 0

                width: listColumn.width
                height: modelData.kind === "header" ? headerText.implicitHeight + Style.space(10)
                      : modelData.kind === "note" ? noteText.implicitHeight + Style.space(12)
                      : Style.space(46)

                PanelSectionHeader {
                  id: headerText
                  visible: rowItem.modelData.kind === "header"
                  anchors.left: parent.left
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(3)
                  text: rowItem.modelData.kind === "header" ? rowItem.modelData.label : ""
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                // Inert copy (empty states, loading, errors)
                Text {
                  id: noteText
                  visible: rowItem.modelData.kind === "note"
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(4)
                  textFormat: Text.PlainText
                  text: rowItem.modelData.kind === "note" ? rowItem.modelData.text : ""
                  color: rowItem.modelData.kind === "note" && rowItem.modelData.dim === false ? root.urgent : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: Text.Wrap
                }

                Rectangle {
                  visible: rowItem.isItem
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: rowItem.hasCursor ? Style.hoverFillFor(root.foreground, root.accent)
                       : (rowItem.isNow ? Style.normalFillFor(root.foreground, root.accent) : "transparent")

                  Row {
                    anchors.left: parent.left
                    anchors.right: rowActions.left
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(6)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(10)

                    RoundedArt {
                      id: rowArt
                      width: Style.space(36)
                      height: Style.space(36)
                      // A show's own episode list repeats the same cover on
                      // every row; show the episode glyph there instead.
                      source: rowItem.isItem && !(root.detailOpen && rowItem.isEpisode) ? Model.artSource(rowItem.item) : ""
                      placeholder: rowItem.isEpisode ? Model.glyph.episode : Model.glyph.podcast
                      cornerRadius: Style.cornerRadius > 0 ? Style.space(4) : 0
                      opacity: rowItem.played ? 0.5 : 1.0
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Column {
                      width: parent.width - rowArt.width - parent.spacing
                      spacing: Style.space(2)
                      anchors.verticalCenter: parent.verticalCenter

                      Row {
                        width: parent.width
                        spacing: Style.space(6)

                        Text {
                          textFormat: Text.PlainText
                          text: rowItem.isItem ? rowItem.item.name : ""
                          width: Math.min(implicitWidth, parent.width - (stateGlyph.visible ? stateGlyph.width + parent.spacing : 0))
                          color: rowItem.isNow ? root.accent : (rowItem.played ? root.dim : root.foreground)
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.body
                          font.bold: rowItem.hasCursor || rowItem.isNow
                          elide: Text.ElideRight
                        }
                        Text {
                          textFormat: Text.PlainText
                          id: stateGlyph
                          visible: rowItem.isNow || (rowItem.queued && root.currentTab !== "upnext")
                          text: rowItem.isNow ? (root.isPlaying ? Model.glyph.volumeHigh : Model.glyph.pause) : Model.glyph.upNext
                          color: rowItem.isNow ? root.accent : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.bodySmall
                          anchors.verticalCenter: parent.verticalCenter
                        }
                      }

                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: rowItem.isItem ? Model.subtitle(rowItem.item, root.detailOpen) : ""
                        visible: text !== ""
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }

                      // Listening progress for started episodes.
                      Rectangle {
                        visible: rowItem.isEpisode && rowItem.progress > 0 && !rowItem.played
                        width: parent.width
                        height: Style.space(2)
                        radius: 1
                        color: Style.selectedFillFor(root.foreground, root.accent)

                        Rectangle {
                          width: parent.width * rowItem.progress
                          height: parent.height
                          radius: parent.radius
                          color: root.accent
                        }
                      }
                    }
                  }

                  Row {
                    id: rowActions
                    anchors.right: parent.right
                    anchors.rightMargin: Style.space(4)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)
                    visible: rowItem.hasCursor && rowItem.isEpisode
                    width: visible ? implicitWidth : 0

                    PanelActionButton {
                      iconText: rowItem.played ? Model.glyph.unplayed : Model.glyph.played
                      tooltipText: rowItem.played ? "Mark as unplayed (m)" : "Mark as played (m)"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: if (root.service) root.service.markPlayed(rowItem.item, !rowItem.played)
                    }
                    PanelActionButton {
                      iconText: rowItem.queued ? Model.glyph.close : Model.glyph.queue
                      tooltipText: rowItem.queued ? "Remove from Up Next (q)" : "Add to Up Next (q)"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: if (root.service) root.service.toggleQueued(rowItem.item)
                    }
                    PanelActionButton {
                      iconText: rowItem.isNow && root.isPlaying ? Model.glyph.pause : Model.glyph.play
                      tooltipText: rowItem.isNow && root.isPlaying ? "Pause" : "Play (enter)"
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: root.activateRow(rowItem.index)
                    }
                  }

                  MouseArea {
                    anchors.fill: parent
                    anchors.rightMargin: rowActions.visible ? rowActions.width + Style.space(6) : 0
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                    onEntered: root.cursorIndex = rowItem.index
                    onClicked: function(mouse) {
                      if ((mouse.button === Qt.RightButton || mouse.button === Qt.MiddleButton) && rowItem.isEpisode) {
                        if (root.service) root.service.toggleQueued(rowItem.item)
                        return
                      }
                      root.activateRow(rowItem.index)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
