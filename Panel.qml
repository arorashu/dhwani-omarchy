import QtQuick
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.dhwani.listen"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var episodes: []
  property int selectedIndex: 0
  property string errorText: ""
  property string launchingEpisodeId: ""
  property bool refreshing: false
  property double lastFetchMs: 0

  readonly property var barIdentity: hostWidget || root
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var currentPlayback: findCurrentPlayback()
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string apiBase: Model.normalizeBaseUrl(setting("apiBase", "http://127.0.0.1:8791"))
  readonly property int episodeLimit: Math.max(3, Math.min(10, parseInt(setting("episodeLimit", 7), 10) || 7))
  readonly property int staleAfterSec: Math.max(30, parseInt(setting("staleAfterSec", 300), 10) || 300)
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("play.py")).replace(/^file:\/\//, ""))
  readonly property int rowHeight: Style.space(66)
  readonly property var playbackPlayer: currentPlayback ? currentPlayback.player : null
  readonly property real playbackPosition: playbackPlayer && playbackPlayer.positionSupported ? Math.max(0, Number(playbackPlayer.position) || 0) : 0
  readonly property real playbackLength: playbackPlayer && playbackPlayer.lengthSupported ? Math.max(0, Number(playbackPlayer.length) || 0) : (currentPlayback ? currentPlayback.episode.duration : 0)
  readonly property bool canSeek: playbackPlayer !== null && playbackPlayer.canSeek === true

  function open() {
    controller.show()
    Qt.callLater(function() {
      var index = playbackIndex()
      if (index >= 0) {
        selectedIndex = index
        moveCursor(0)
      }
    })
    if (!episodes.length || Date.now() - lastFetchMs > staleAfterSec * 1000) refresh()
  }

  function close() { controller.hide() }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function refresh() {
    if (feedProcess.running) return
    if (!apiBase) {
      errorText = "Set a Dhwani API address"
      return
    }
    refreshing = true
    errorText = ""
    feedProcess.command = ["curl", "-fsSL", "--max-time", "8", "--max-filesize", "1048576", "--proto", "=http,https", "--proto-redir", "=http,https", "-H", "Accept: application/json", "--", Model.feedUrl(apiBase)]
    feedProcess.running = true
  }

  function applyFeed(raw) {
    if (String(raw || "").length > 1048576) {
      errorText = "Dhwani returned too much data"
      return
    }
    var result = Model.parseFeed(raw, episodeLimit)
    if (!result.ok) {
      errorText = result.error
      return
    }
    episodes = result.episodes
    var currentIndex = playbackIndex()
    selectedIndex = currentIndex >= 0 ? currentIndex : Math.min(selectedIndex, Math.max(0, episodes.length - 1))
    errorText = ""
    lastFetchMs = Date.now()
  }

  function conciseError(raw) {
    var text = String(raw || "").replace(/\s+/g, " ").trim()
    return text.length > 100 ? text.substring(0, 97) + "…" : text
  }

  function moveCursor(delta) {
    if (!episodes.length) return
    selectedIndex = Math.max(0, Math.min(episodes.length - 1, selectedIndex + delta))
    var top = selectedIndex * rowHeight
    if (top < episodeList.contentY) episodeList.contentY = top
    else if (top + rowHeight > episodeList.contentY + episodeList.height)
      episodeList.contentY = top + rowHeight - episodeList.height
  }

  function playerFor(item) {
    var label = Model.playbackTitle(item)
    for (var i = 0; i < mprisPlayers.length; i++) {
      var player = mprisPlayers[i]
      var app = String(player.identity || player.desktopEntry || "").toLowerCase()
      if (app === "mpv" && String(player.trackTitle || "") === label) return player
    }
    return null
  }

  function playbackIndex() {
    for (var i = 0; i < episodes.length; i++) if (playerFor(episodes[i])) return i
    return -1
  }

  function findCurrentPlayback() {
    var index = playbackIndex()
    if (index < 0) return null
    return { episode: episodes[index], player: playerFor(episodes[index]) }
  }

  function togglePlayer(player) {
    if (!player) return false
    if (player.isPlaying && player.canPause) player.pause()
    else if (!player.isPlaying && player.canPlay) player.play()
    else if (player.canTogglePlaying) player.togglePlaying()
    else return false
    errorText = ""
    return true
  }

  function seekBy(seconds) {
    if (!canSeek) return false
    playbackPlayer.seek(seconds)
    errorText = ""
    return true
  }

  function seekTo(progress) {
    if (!canSeek || !playbackPlayer.positionSupported || playbackLength <= 0) return false
    playbackPlayer.position = Math.max(0, Math.min(1, progress)) * playbackLength
    errorText = ""
    return true
  }

  function playEpisode(item) {
    if (!item || !item.audioUrl || playerProcess.running) return
    var player = playerFor(item)
    if (player) {
      togglePlayer(player)
      return
    }
    launchingEpisodeId = item.episodeId || item.audioUrl
    errorText = ""
    playerProcess.command = ["python3", helperPath, item.audioUrl, Model.playbackTitle(item)]
    playerProcess.running = true
  }

  function playSelected() {
    if (episodes.length) playEpisode(episodes[selectedIndex])
  }

  Process {
    id: feedProcess
    command: []
    stdout: StdioCollector { id: feedStdout; waitForEnd: true }
    stderr: StdioCollector { id: feedStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyFeed(feedStdout.text)
      else root.errorText = root.conciseError(feedStderr.text) || "Dhwani is out of reach"
    }
  }

  Process {
    id: playerProcess
    command: []
    stderr: StdioCollector { id: playerStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.launchingEpisodeId = ""
      if (exitCode !== 0) root.errorText = root.conciseError(playerStderr.text) || "The episode could not start"
    }
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.playbackPlayer && root.playbackPlayer.isPlaying && root.playbackPlayer.positionSupported
    onTriggered: if (root.playbackPlayer) root.playbackPlayer.positionChanged()
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
        if (dx) root.seekBy(dx < 0 ? -15 : 30)
        else if (dy) root.moveCursor(dy)
      }
      onActivateRequested: root.playSelected()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "r" || text === "R") root.refresh()
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
            text: root.currentPlayback ? (root.currentPlayback.player.isPlaying ? "Playing now" : "Paused") : "Something worth hearing"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
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
          enabled: !root.refreshing
          onClicked: root.refresh()
        }
      }

      Rectangle {
        id: separator
        anchors.top: header.bottom
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
          visible: root.episodes.length === 0

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
            text: root.refreshing ? "Listening for Dhwani…" : (root.errorText || "The listening queue is quiet")
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
          visible: root.episodes.length > 0
          clip: true
          contentWidth: width
          contentHeight: episodeColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds

          Column {
            id: episodeColumn
            width: episodeList.width

            Repeater {
              model: root.episodes

              CursorSurface {
                id: episodeRow
                required property int index
                required property var modelData
                readonly property var mediaPlayer: root.playerFor(modelData)

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
                    text: "󰦔"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  Image {
                    anchors.fill: parent
                    source: modelData.artworkUrl
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
                    text: modelData.podcastTitle
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
                    text: root.launchingEpisodeId === (modelData.episodeId || modelData.audioUrl) ? "󰑐" : (episodeRow.mediaPlayer && episodeRow.mediaPlayer.isPlaying ? "󰏤" : "󰐊")
                    color: root.selectedIndex === index ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.icon
                  }

                  Text {
                    width: parent.width
                    horizontalAlignment: Text.AlignRight
                    text: Model.formatDuration(modelData.duration)
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
                  onClicked: root.playEpisode(modelData)
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
        anchors.bottom: footer.top
        height: visible ? Style.space(76) : 0
        visible: root.currentPlayback !== null

        Rectangle {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: Style.spacing.hairline
          color: root.foreground
          opacity: 0.12
        }

        Row {
          id: transport
          anchors.top: parent.top
          anchors.topMargin: Style.space(5)
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(8)

          PanelActionButton {
            iconText: "−15"
            tooltipText: "Back 15 seconds · ← or h"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            size: Style.space(30)
            bordered: true
            enabled: root.canSeek
            onClicked: root.seekBy(-15)
          }

          PanelActionButton {
            iconText: root.playbackPlayer && root.playbackPlayer.isPlaying ? "󰏤" : "󰐊"
            tooltipText: root.playbackPlayer && root.playbackPlayer.isPlaying ? "Pause · enter or space" : "Play · enter or space"
            foreground: root.foreground
            fontFamily: root.fontFamily
            size: Style.space(30)
            bordered: true
            enabled: root.playbackPlayer !== null
            onClicked: root.togglePlayer(root.playbackPlayer)
          }

          PanelActionButton {
            iconText: "+30"
            tooltipText: "Forward 30 seconds · → or l"
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            size: Style.space(30)
            bordered: true
            enabled: root.canSeek
            onClicked: root.seekBy(30)
          }
        }

        Item {
          id: timeline
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(32)

          Text {
            id: elapsed
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(48)
            text: Model.formatPosition(root.playbackPosition)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            id: total
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(56)
            text: Model.formatPosition(root.playbackLength)
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }

          Item {
            id: seekSurface
            anchors.left: elapsed.right
            anchors.leftMargin: Style.space(8)
            anchors.right: total.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            height: Style.space(20)

            Rectangle {
              id: progressTrack
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              height: Math.max(2, Style.spacing.hairline * 2)
              radius: height / 2
              color: root.foreground
              opacity: 0.18
            }

            Rectangle {
              anchors.left: progressTrack.left
              anchors.verticalCenter: progressTrack.verticalCenter
              width: progressTrack.width * Model.playbackProgress(root.playbackPosition, root.playbackLength)
              height: progressTrack.height
              radius: height / 2
              color: Color.accent
            }

            MouseArea {
              anchors.fill: parent
              enabled: root.canSeek && root.playbackPlayer.positionSupported && root.playbackLength > 0
              cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: function(mouse) { root.seekTo(mouse.x / width) }
            }
          }
        }
      }

      Item {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: Style.space(32)

        Rectangle {
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(6)
          height: width
          radius: width / 2
          color: root.errorText ? (root.bar ? root.bar.urgent : Color.urgent) : (root.currentPlayback && root.currentPlayback.player.isPlaying ? Color.accent : root.dim)
        }

        Text {
          anchors.left: parent.left
          anchors.leftMargin: Style.space(14)
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - Style.space(14)
          text: root.errorText && root.episodes.length ? root.errorText : (root.launchingEpisodeId ? "Opening episode…" : (root.currentPlayback ? (root.currentPlayback.player.isPlaying ? "Playing · " : "Paused · ") + root.currentPlayback.episode.title : root.episodes.length + " ready  ·  ↑↓ choose  ·  enter play  ·  r refresh"))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
