import QtQuick
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.dhwani.listen"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  property int tab: 0
  property var openShow: null
  property int selectedIndex: 0
  property int trendingIndex: 0
  property int queueIndex: 0
  property int showsIndex: 0
  property int showIndex: 0
  property bool enterPressed: false

  readonly property var barIdentity: hostWidget || root
  readonly property var listen: service || (bar && bar.shell && bar.shell.serviceFor ? bar.shell.serviceFor("io.dhwani.listen") : null)
  readonly property var queue: listen ? listen.queue : []
  readonly property var trending: listen ? listen.trending : []
  readonly property var shows: listen ? listen.shows : []
  readonly property var showRecord: listen && openShow ? listen.showRecord(openShow.podcastId) : { episodes: [], total: 0 }
  readonly property var showEpisodes: showRecord.episodes || []
  readonly property var visibleRows: tab === 1 ? queue : (tab === 2 ? (openShow ? showEpisodes : shows) : trending)
  readonly property var currentPlayback: listen ? listen.currentPlayback : null
  readonly property var playbackPlayer: listen ? listen.playbackPlayer : null
  readonly property real playbackPosition: listen ? listen.playbackPosition : 0
  readonly property real playbackLength: listen ? listen.playbackLength : 0
  readonly property bool canSeek: listen ? listen.canSeek : false
  readonly property bool refreshing: listen ? listen.refreshing : false
  readonly property string errorText: listen ? listen.errorText : ""
  readonly property string launchingEpisodeId: listen ? listen.launchingEpisodeId : ""
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string apiBase: Model.normalizeBaseUrl(setting("apiBase", "https://api-v1.dhwani.io"))
  readonly property int episodeLimit: Math.max(3, Math.min(20, parseInt(setting("episodeLimit", 10), 10) || 10))
  readonly property int staleAfterMs: Math.max(30000, (parseInt(setting("staleAfterSec", 600), 10) || 600) * 1000)
  readonly property int rowHeight: Style.space(66)
  readonly property var tabs: ["Trending", "Queue", "All Shows"]

  function open() {
    controller.show()
    Qt.callLater(function() {
      restoreIndex()
      moveCursor(0)
    })
    ensureData(false)
  }

  function close() {
    if (listen) listen.rememberPlayback()
    controller.hide()
  }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function ensureData(force) {
    if (!listen) return
    listen.configure(apiBase, episodeLimit, staleAfterMs)
    if (tab === 0) listen.ensureTrending(force)
    else if (tab === 2 && !openShow) listen.ensureShows(force)
    else if (tab === 2 && openShow) listen.ensureShow(openShow.podcastId, force)
  }

  function refresh() {
    if (tab === 1) return
    ensureData(true)
  }

  function saveCurrentIndex() {
    if (tab === 0) trendingIndex = selectedIndex
    else if (tab === 1) queueIndex = selectedIndex
    else if (openShow) showIndex = selectedIndex
    else showsIndex = selectedIndex
  }

  function restoreIndex() {
    var rows = visibleRows
    var index = tab === 0 ? trendingIndex : (tab === 1 ? queueIndex : (openShow ? showIndex : showsIndex))
    selectedIndex = Math.max(0, Math.min(index, Math.max(0, rows.length - 1)))
    moveCursor(0)
  }

  function switchTab(delta) {
    saveCurrentIndex()
    tab = (tab + delta + 3) % 3
    restoreIndex()
    ensureData(false)
  }

  function moveCursor(delta) {
    var rows = visibleRows
    if (!rows.length) return
    selectedIndex = Math.max(0, Math.min(rows.length - 1, selectedIndex + delta))
    saveCurrentIndex()
    var top = selectedIndex * rowHeight
    if (top < episodeList.contentY) episodeList.contentY = top
    else if (top + rowHeight > episodeList.contentY + episodeList.height)
      episodeList.contentY = top + rowHeight - episodeList.height
    maybePage()
  }

  function maybePage() {
    if (!listen || tab !== 2) return
    if (!openShow && selectedIndex > shows.length - 4) listen.pageShows()
    else if (openShow && selectedIndex > showEpisodes.length - 4) listen.pageShow(openShow.podcastId)
  }

  function activateSelected() {
    var item = visibleRows[selectedIndex]
    if (!item) return
    if (item.kind === "show") {
      openShow = item
      selectedIndex = 0
      showIndex = 0
      ensureData(false)
      return
    }
    if (listen) listen.playEpisode(item)
  }

  function back() {
    if (tab === 2 && openShow) {
      saveCurrentIndex()
      openShow = null
      restoreIndex()
      return
    }
    close()
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: true
    focusTarget: keyCatcher
    contentWidth: fittedContentWidth(Style.space(520))
    contentHeight: fittedContentHeight(Style.space(570))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dx < 0 && root.tab === 2 && root.openShow) root.back()
        else if (dx) root.switchTab(dx)
        else if (dy) root.moveCursor(dy)
      }
      onReturnRequested: {
        root.enterPressed = true
        root.activateSelected()
      }
      onActivateRequested: {
        if (root.enterPressed) {
          root.enterPressed = false
          return
        }
        if (root.listen) root.listen.togglePlaying()
      }
      onCloseRequested: root.back()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
      }

      Shortcut {
        sequences: ["h"]
        enabled: root.opened
        onActivated: if (root.listen) root.listen.seekBy(-15)
      }
      Shortcut {
        sequences: ["l"]
        enabled: root.opened
        onActivated: if (root.listen) root.listen.seekBy(30)
      }

      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(70)

        Text {
          id: mark
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          text: "󰦔"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.fontPx(2.7)
        }

        Column {
          anchors.left: mark.right
          anchors.leftMargin: Style.space(16)
          anchors.right: refreshButton.left
          anchors.rightMargin: Style.space(12)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Text {
            width: parent.width
            text: "Dhwani"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }

          Text {
            width: parent.width
            text: root.currentPlayback ? (root.currentPlayback.player.isPlaying ? "Playing now" : "Paused") : (root.openShow && root.tab === 2 ? root.openShow.title : "Something worth hearing")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        PanelActionButton {
          id: refreshButton
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.refreshing ? "󰑐" : "󰑓"
          tooltipText: "Refresh · r"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: !root.refreshing && root.tab !== 1
          onClicked: root.refresh()
        }
      }

      Row {
        id: tabBar
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(32)
        spacing: Style.space(16)
        leftPadding: Style.space(8)

        Repeater {
          model: root.tabs
          Text {
            required property int index
            required property string modelData
            text: modelData + (index === 1 && root.queue.length ? " " + root.queue.length : "")
            color: root.tab === index ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: root.tab === index
            height: tabBar.height
            verticalAlignment: Text.AlignVCenter
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.saveCurrentIndex()
                root.tab = index
                root.restoreIndex()
                root.ensureData(false)
              }
            }
          }
        }
      }

      Rectangle {
        id: separator
        anchors.top: tabBar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.spacing.hairline
        color: root.foreground
        opacity: 0.12
      }

      Item {
        id: listArea
        anchors.top: separator.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: playbackControls.visible ? playbackControls.top : footer.top

        Column {
          anchors.centerIn: parent
          spacing: Style.space(10)
          visible: root.visibleRows.length === 0

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.refreshing ? "󰑐" : (root.errorText ? "󰅚" : "󰐹")
            color: root.errorText ? (root.bar ? root.bar.urgent : Color.urgent) : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.fontPx(2.2)
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(1, listArea.width - Style.space(48))
            text: root.refreshing ? "Listening for Dhwani…" : (root.errorText || (root.tab === 1 ? "Play something and it will land here" : "The listening queue is quiet"))
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }
        }

        Flickable {
          id: episodeList
          anchors.fill: parent
          visible: root.visibleRows.length > 0
          clip: true
          contentWidth: width
          contentHeight: episodeColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: episodeColumn
            width: episodeList.width

            Repeater {
              model: root.visibleRows

              CursorSurface {
                id: episodeRow
                required property int index
                required property var modelData
                readonly property var mediaPlayer: root.listen ? root.listen.playerFor(modelData) : null

                width: episodeColumn.width
                height: root.rowHeight
                hasCursor: root.selectedIndex === index
                current: mediaPlayer !== null
                foreground: root.foreground
                accent: Color.accent

                Rectangle {
                  id: artwork
                  x: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(48)
                  height: width
                  radius: Style.cornerRadius
                  color: Style.normalFillFor(root.foreground, Color.accent)
                  clip: true

                  Text {
                    anchors.centerIn: parent
                    text: modelData.kind === "show" ? "󰐌" : "󰦔"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  Image {
                    anchors.fill: parent
                    source: modelData.artworkUrl
                    sourceSize.width: 96
                    sourceSize.height: 96
                    asynchronous: true
                    cache: true
                    fillMode: Image.PreserveAspectCrop
                    visible: status === Image.Ready
                  }
                }

                Column {
                  anchors.left: artwork.right
                  anchors.leftMargin: Style.space(12)
                  anchors.right: meta.left
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(3)

                  Text {
                    width: parent.width
                    text: modelData.title
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: modelData.kind === "show" ? (modelData.episodeCount ? modelData.episodeCount + " episodes" : "Show") : modelData.podcastTitle
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }
                }

                Column {
                  id: meta
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(12)
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(62)
                  spacing: Style.space(3)

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignRight
                    text: modelData.kind === "show" ? "󰅂" : (root.launchingEpisodeId === (modelData.episodeId || modelData.audioUrl) ? "󰑐" : (episodeRow.mediaPlayer && episodeRow.mediaPlayer.isPlaying ? "󰏤" : "󰐊"))
                    color: root.selectedIndex === index ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignRight
                    text: modelData.kind === "show" ? "" : (modelData.position ? Model.formatPosition(modelData.position) : Model.formatDuration(modelData.duration))
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: root.selectedIndex = index
                  onClicked: {
                    root.selectedIndex = index
                    root.activateSelected()
                  }
                }
              }
            }
          }
        }
      }

      Item {
        id: playbackControls
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? Style.space(76) : 0
        visible: root.currentPlayback !== null

        Item {
          id: timeline
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.space(14)

          Rectangle {
            id: progressTrack
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Math.max(2, Style.spacing.hairline * 2)
            color: root.foreground
            opacity: 0.18
          }

          Rectangle {
            anchors.top: progressTrack.top
            anchors.left: progressTrack.left
            width: progressTrack.width * Model.playbackProgress(root.playbackPosition, root.playbackLength)
            height: progressTrack.height
            color: Color.accent
          }

          MouseArea {
            anchors.fill: parent
            enabled: root.canSeek && root.playbackPlayer && root.playbackPlayer.positionSupported && root.playbackLength > 0
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: function(mouse) { if (root.listen) root.listen.seekTo(mouse.x / width) }
          }
        }

        Item {
          anchors.top: timeline.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom

          Column {
            anchors.left: parent.left
            anchors.right: transport.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(3)

            Text {
              width: parent.width
              text: root.errorText || (root.currentPlayback ? root.currentPlayback.episode.title : "")
              color: root.errorText ? (root.bar ? root.bar.urgent : Color.urgent) : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.currentPlayback ? root.currentPlayback.episode.podcastTitle : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Math.max(8, Style.font.caption - 1)
              elide: Text.ElideRight
            }
          }

          Row {
            id: transport
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)

            PanelActionButton {
              iconText: "−15"
              tooltipText: "Back 15 seconds · h"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              size: Style.space(30)
              radius: size / 2
              enabled: root.canSeek
              onClicked: if (root.listen) root.listen.seekBy(-15)

              Text {
                anchors.top: parent.bottom
                anchors.topMargin: Style.space(2)
                anchors.horizontalCenter: parent.horizontalCenter
                text: "h"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            PanelActionButton {
              iconText: root.playbackPlayer && root.playbackPlayer.isPlaying ? "󰏤" : "󰐊"
              tooltipText: root.playbackPlayer && root.playbackPlayer.isPlaying ? "Pause · space" : "Play · space"
              foreground: root.playbackPlayer && root.playbackPlayer.isPlaying ? Color.accent : root.foreground
              hoverColor: Color.accent
              fontFamily: root.fontFamily
              size: Style.space(34)
              radius: size / 2
              bordered: true
              enabled: root.playbackPlayer !== null
              onClicked: if (root.listen) root.listen.togglePlaying()
            }

            PanelActionButton {
              iconText: "+30"
              tooltipText: "Forward 30 seconds · l"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              size: Style.space(30)
              radius: size / 2
              enabled: root.canSeek
              onClicked: if (root.listen) root.listen.seekBy(30)

              Text {
                anchors.top: parent.bottom
                anchors.topMargin: Style.space(2)
                anchors.horizontalCenter: parent.horizontalCenter
                text: "l"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          Column {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(72)
            spacing: Style.space(3)

            Text {
              width: parent.width
              text: Model.formatPosition(root.playbackPosition)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
            }

            Text {
              width: parent.width
              text: "of " + Model.formatPosition(root.playbackLength)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Math.max(8, Style.font.caption - 1)
              horizontalAlignment: Text.AlignRight
            }
          }
        }
      }

      Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: visible ? Style.space(32) : 0
        visible: !playbackControls.visible

        Rectangle {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6)
          height: width
          radius: width / 2
          color: root.errorText ? (root.bar ? root.bar.urgent : Color.urgent) : root.dim
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(14)
          text: root.errorText && root.visibleRows.length ? root.errorText : (root.launchingEpisodeId ? "Opening episode…" : (root.openShow && root.tab === 2 ? "esc/← back  ·  h/l seek  ·  enter play  ·  space pause" : "←→ tabs  ·  h/l seek  ·  enter play  ·  space pause"))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
