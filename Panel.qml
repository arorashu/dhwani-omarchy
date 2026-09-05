import QtQuick
import Quickshell
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
  property int tab: 0
  property var trending: []
  property var queue: []
  property var shows: []
  property var showEpisodes: []
  property var openShow: null
  property int selectedIndex: 0
  property int trendingIndex: 0
  property int queueIndex: 0
  property int showsIndex: 0
  property int showIndex: 0
  property int showsTotal: 0
  property int showTotal: 0
  property double trendingAt: 0
  property double showsAt: 0
  property double showAt: 0
  property string errorText: ""
  property string launchingEpisodeId: ""
  property string pendingKind: ""
  property real pendingSeek: 0
  property bool refreshing: false
  property bool stateReady: false

  readonly property var barIdentity: hostWidget || root
  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var visibleRows: tab === 1 ? queue : (tab === 2 ? (openShow ? showEpisodes : shows) : trending)
  readonly property var currentPlayback: findCurrentPlayback()
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Color.muted
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string apiBase: Model.normalizeBaseUrl(setting("apiBase", "https://api-v1.dhwani.io"))
  readonly property int episodeLimit: Math.max(3, Math.min(20, parseInt(setting("episodeLimit", 10), 10) || 10))
  readonly property int staleAfterMs: Math.max(30000, (parseInt(setting("staleAfterSec", 600), 10) || 600) * 1000)
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("play.py")).replace(/^file:\/\//, ""))
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/dhwani-omarchy"
  readonly property int rowHeight: Style.space(66)
  readonly property var playbackPlayer: currentPlayback ? currentPlayback.player : null
  readonly property real playbackPosition: playbackPlayer && playbackPlayer.positionSupported ? Math.max(0, Number(playbackPlayer.position) || 0) : 0
  readonly property real playbackLength: playbackPlayer && playbackPlayer.lengthSupported ? Math.max(0, Number(playbackPlayer.length) || 0) : (currentPlayback ? currentPlayback.episode.duration : 0)
  readonly property bool canSeek: playbackPlayer !== null && playbackPlayer.canSeek === true
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
    rememberPlayback()
    saveState()
    controller.hide()
  }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function curlCommand(url) {
    return ["curl", "-fsSL", "--max-time", "12", "--max-filesize", "1048576", "--proto", "=http,https", "--proto-redir", "=http,https"].concat(Model.curlHeaders()).concat(["--", url])
  }

  function fetch(kind, url) {
    if (!url || netProcess.running) return
    pendingKind = kind
    refreshing = true
    errorText = ""
    netProcess.command = curlCommand(url)
    netProcess.running = true
  }

  function ensureData(force) {
    if (!apiBase) {
      errorText = "Set a Dhwani API address"
      return
    }
    var now = Date.now()
    if (tab === 0 && (force || !trending.length || !Model.isFresh(trendingAt, now, staleAfterMs))) fetch("trending", Model.feedUrl(apiBase))
    else if (tab === 2 && !openShow && (force || !shows.length || !Model.isFresh(showsAt, now, staleAfterMs))) fetch("shows", Model.podcastsUrl(apiBase, 0))
    else if (tab === 2 && openShow && (force || !showEpisodes.length || !Model.isFresh(showAt, now, staleAfterMs))) fetch("show", Model.showUrl(apiBase, openShow.podcastId, 0))
  }

  function refresh() {
    if (tab === 1) {
      errorText = ""
      return
    }
    ensureData(true)
  }

  function applyNetwork(raw) {
    if (String(raw || "").length > 1048576) {
      errorText = "Dhwani returned too much data"
      return
    }
    var kind = pendingKind
    if (kind === "trending") {
      var feed = Model.parseTrending(raw, episodeLimit)
      if (!feed.ok) { errorText = feed.error; return }
      trending = feed.episodes
      trendingAt = Date.now()
    } else if (kind === "shows" || kind === "moreShows") {
      var list = Model.parsePodcasts(raw)
      if (!list.ok) { errorText = list.error; return }
      shows = kind === "moreShows" ? shows.concat(list.shows) : list.shows
      showsTotal = list.total
      showsAt = Date.now()
    } else if (kind === "show" || kind === "moreShow") {
      var detail = Model.parseShow(raw)
      if (!detail.ok) { errorText = detail.error; return }
      if (detail.show) openShow = detail.show
      showEpisodes = kind === "moreShow" ? showEpisodes.concat(detail.episodes) : detail.episodes
      showTotal = detail.total
      showAt = Date.now()
    }
    errorText = ""
    restoreIndex()
    saveSoon()
  }

  function conciseError(raw) {
    var text = String(raw || "").replace(/\s+/g, " ").trim()
    return text.length > 100 ? text.substring(0, 97) + "…" : text
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
    saveSoon()
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
    if (netProcess.running || tab !== 2) return
    if (!openShow && shows.length && shows.length < showsTotal && selectedIndex > shows.length - 4)
      fetch("moreShows", Model.podcastsUrl(apiBase, shows.length))
    else if (openShow && showEpisodes.length && showEpisodes.length < showTotal && selectedIndex > showEpisodes.length - 4)
      fetch("moreShow", Model.showUrl(apiBase, openShow.podcastId, showEpisodes.length))
  }

  function playerFor(item) {
    if (!item || item.kind === "show") return null
    var label = Model.playbackTitle(item)
    for (var i = 0; i < mprisPlayers.length; i++) {
      var player = mprisPlayers[i]
      var app = String(player.identity || player.desktopEntry || "").toLowerCase()
      if (app === "mpv" && String(player.trackTitle || "") === label) return player
    }
    return null
  }

  function allEpisodes() {
    return trending.concat(queue).concat(showEpisodes)
  }

  function findCurrentPlayback() {
    var items = allEpisodes()
    for (var i = 0; i < items.length; i++) {
      var player = playerFor(items[i])
      if (player) return { episode: items[i], player: player }
    }
    return null
  }

  function togglePlayer(player) {
    if (!player) return false
    if (player.isPlaying && player.canPause) player.pause()
    else if (!player.isPlaying && player.canPlay) player.play()
    else if (player.canTogglePlaying) player.togglePlaying()
    else return false
    errorText = ""
    rememberPlayback()
    return true
  }

  function seekBy(seconds) {
    if (!canSeek) return false
    playbackPlayer.seek(seconds)
    errorText = ""
    rememberPlayback()
    return true
  }

  function seekTo(progress) {
    if (!canSeek || !playbackPlayer.positionSupported || playbackLength <= 0) return false
    playbackPlayer.position = Math.max(0, Math.min(1, progress)) * playbackLength
    errorText = ""
    rememberPlayback()
    return true
  }

  function rememberPlayback() {
    if (!currentPlayback) return
    queue = Model.rememberPosition(queue, currentPlayback.episode, playbackPosition, playbackLength)
    saveSoon()
  }

  function playEpisode(item) {
    if (!item || item.kind === "show" || !item.audioUrl || playerProcess.running) return
    queue = Model.enqueue(queue, item)
    saveSoon()
    var player = playerFor(item)
    if (player) {
      togglePlayer(player)
      return
    }
    launchingEpisodeId = item.episodeId || item.audioUrl
    pendingSeek = item.position > 5 ? item.position : 0
    errorText = ""
    playerProcess.command = ["python3", helperPath, item.audioUrl, Model.playbackTitle(item)]
    playerProcess.running = true
  }

  function activateSelected() {
    var item = visibleRows[selectedIndex]
    if (!item) return
    if (item.kind === "show") {
      openShow = item
      showEpisodes = []
      showTotal = item.episodeCount || 0
      selectedIndex = 0
      showIndex = 0
      ensureData(false)
      saveSoon()
      return
    }
    playEpisode(item)
  }

  function back() {
    if (tab === 2 && openShow) {
      saveCurrentIndex()
      openShow = null
      showEpisodes = []
      restoreIndex()
      saveSoon()
      return
    }
    close()
  }

  function applyState(raw) {
    var state = Model.parseState(raw)
    queue = state.queue
    tab = state.nav.tab
    trendingIndex = state.nav.trendingIndex
    queueIndex = state.nav.queueIndex
    showsIndex = state.nav.showsIndex
    showIndex = state.nav.showIndex
    var cache = state.cache || {}
    if (cache.trending && cache.trending.episodes) {
      trending = cache.trending.episodes
      trendingAt = Number(cache.trending.fetchedAt) || 0
    }
    if (cache.shows && cache.shows.items) {
      shows = cache.shows.items
      showsTotal = Number(cache.shows.total) || shows.length
      showsAt = Number(cache.shows.fetchedAt) || 0
    }
    if (state.nav.openShowId && cache.showsById && cache.showsById[state.nav.openShowId]) {
      var cachedShow = cache.showsById[state.nav.openShowId]
      openShow = { kind: "show", podcastId: state.nav.openShowId, title: state.nav.openShowTitle || cachedShow.title, podcastTitle: state.nav.openShowTitle || cachedShow.title }
      showEpisodes = cachedShow.episodes || []
      showTotal = Number(cachedShow.total) || showEpisodes.length
      showAt = Number(cachedShow.fetchedAt) || 0
    }
    stateReady = true
    restoreIndex()
  }

  function dumpState() {
    var showsById = {}
    if (openShow) showsById[openShow.podcastId] = { fetchedAt: showAt, title: openShow.title, episodes: showEpisodes, total: showTotal }
    return JSON.stringify({
      schemaVersion: 1,
      queue: queue,
      nav: {
        tab: tab,
        trendingIndex: trendingIndex,
        queueIndex: queueIndex,
        showsIndex: showsIndex,
        showIndex: showIndex,
        openShowId: openShow ? openShow.podcastId : "",
        openShowTitle: openShow ? openShow.title : ""
      },
      cache: {
        trending: { fetchedAt: trendingAt, episodes: trending },
        shows: { fetchedAt: showsAt, items: shows, total: showsTotal },
        showsById: showsById
      }
    })
  }

  function saveState() {
    if (!stateReady) return
    stateFile.setText(dumpState())
  }

  function saveSoon() { saveTimer.restart() }

  onCurrentPlaybackChanged: {
    if (currentPlayback && pendingSeek > 0 && playbackLength > 0) {
      seekTo(pendingSeek / playbackLength)
      pendingSeek = 0
    }
  }

  Process {
    id: netProcess
    command: []
    stdout: StdioCollector { id: netStdout; waitForEnd: true }
    stderr: StdioCollector { id: netStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyNetwork(netStdout.text)
      else root.errorText = root.conciseError(netStderr.text) || "Dhwani is out of reach"
      root.pendingKind = ""
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

  Process {
    id: ensureStateDir
    command: ["mkdir", "-p", root.stateDir]
    running: true
    onExited: stateFile.reload()
  }

  FileView {
    id: stateFile
    path: root.stateDir + "/state.json"
    atomicWrites: true
    printErrors: false
    onLoaded: {
      if (root.stateReady) return
      root.applyState(text())
      if (root.opened) root.ensureData(false)
    }
    onLoadFailed: {
      if (root.stateReady) return
      root.applyState("")
      if (root.opened) root.ensureData(false)
    }
  }

  Timer {
    id: saveTimer
    interval: 250
    repeat: false
    onTriggered: root.saveState()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.playbackPlayer && root.playbackPlayer.isPlaying && root.playbackPlayer.positionSupported
    onTriggered: if (root.playbackPlayer) root.playbackPlayer.positionChanged()
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.playbackPlayer !== null
    onTriggered: root.rememberPlayback()
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
        if (dx) root.switchTab(dx)
        else if (dy) root.moveCursor(dy)
      }
      onActivateRequested: root.activateSelected()
      onCloseRequested: root.back()
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
                root.saveSoon()
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
            enabled: root.canSeek && root.playbackPlayer.positionSupported && root.playbackLength > 0
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: function(mouse) { root.seekTo(mouse.x / width) }
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
              tooltipText: "Back 15 seconds"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              size: Style.space(30)
              radius: size / 2
              enabled: root.canSeek
              onClicked: root.seekBy(-15)
            }

            PanelActionButton {
              iconText: root.playbackPlayer && root.playbackPlayer.isPlaying ? "󰏤" : "󰐊"
              tooltipText: root.playbackPlayer && root.playbackPlayer.isPlaying ? "Pause · enter or space" : "Play · enter or space"
              foreground: root.playbackPlayer && root.playbackPlayer.isPlaying ? Color.accent : root.foreground
              hoverColor: Color.accent
              fontFamily: root.fontFamily
              size: Style.space(34)
              radius: size / 2
              bordered: true
              enabled: root.playbackPlayer !== null
              onClicked: root.togglePlayer(root.playbackPlayer)
            }

            PanelActionButton {
              iconText: "+30"
              tooltipText: "Forward 30 seconds"
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              size: Style.space(30)
              radius: size / 2
              enabled: root.canSeek
              onClicked: root.seekBy(30)
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
          text: root.errorText && root.visibleRows.length ? root.errorText : (root.launchingEpisodeId ? "Opening episode…" : (root.openShow && root.tab === 2 ? "esc back  ·  ↑↓ choose  ·  enter play" : "←→ tabs  ·  ↑↓ choose  ·  enter  ·  r refresh"))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
