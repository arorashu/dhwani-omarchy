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
  property bool searchActive: false
  property string searchText: ""
  property string searchKind: "episodes"
  property string searchPodcastId: ""
  property string searchPodcastTitle: ""
  property int searchIndex: 0
  property int savedTab: 0
  property int savedIndex: 0

  readonly property var barIdentity: hostWidget || root
  readonly property var listen: service || (bar && bar.shell && bar.shell.serviceFor ? bar.shell.serviceFor("io.dhwani.listen") : null)
  readonly property var queue: listen ? listen.queue : []
  readonly property var trending: listen ? listen.trending : []
  readonly property var shows: listen ? listen.shows : []
  readonly property var showRecord: listen && openShow ? listen.showRecord(openShow.podcastId) : { episodes: [], total: 0, nextOffset: 0 }
  readonly property var showEpisodes: showRecord.episodes || []
  readonly property var searchRows: listen ? (searchKind === "shows" ? listen.searchShows : listen.searchEpisodes) : []
  readonly property var visibleRows: searchActive ? searchRows : (tab === 1 ? queue : (tab === 2 ? (openShow ? showEpisodes : shows) : trending))
  readonly property bool searchLoading: listen ? listen.searchLoading : false
  readonly property string searchError: listen ? listen.searchError : ""
  readonly property string queryText: listen ? listen.searchQuery : ""
  readonly property bool showMoreAvailable: {
    if (!listen || !openShow) return false
    var record = listen.showRecord(openShow.podcastId)
    var next = record.nextOffset === undefined ? showEpisodes.length : record.nextOffset
    return next > 0 && next < record.total
  }
  readonly property bool canLoadMore: searchActive
    ? (listen && listen.searchNextOffset > 0 && listen.searchNextOffset < listen.searchTotal)
    : (tab === 2 ? (openShow ? showMoreAvailable : (listen && listen.showsNextOffset > 0 && listen.showsNextOffset < listen.showsTotal)) : false)
  readonly property string listMessage: {
    if (searchActive) {
      if (searchError) return searchError
      if (searchLoading) return "Searching Dhwani…"
      if (!queryText) return "Type to search titles"
      return "No matches for “" + queryText + "”"
    }
    if (refreshing) return "Listening for Dhwani…"
    if (errorText) return errorText
    return tab === 1 ? "Play something and it will land here" : "The listening queue is quiet"
  }
  readonly property string listIcon: {
    if (searchActive) return searchError ? "󰅚" : (searchLoading ? "󰑐" : "󰍉")
    return refreshing ? "󰑐" : (errorText ? "󰅚" : "󰐹")
  }
  readonly property bool listAlert: searchActive ? searchError !== "" : errorText !== ""
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
  onVisibleRowsChanged: Qt.callLater(function() {
    if (root.opened && root.listen) root.listen.ensureArtwork(root.visibleRows)
  })

  function open() {
    controller.show()
    Qt.callLater(function() {
      restoreIndex()
      moveCursor(0)
    })
    ensureData(false)
  }

  function close() {
    resetSearch()
    if (listen) listen.rememberPlayback()
    controller.hide()
  }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(barIdentity, direction)
    return false
  }

  function ensureData(force) {
    if (!listen || searchActive) return
    listen.configure(apiBase, episodeLimit, staleAfterMs)
    if (tab === 0) listen.ensureTrending(force)
    else if (tab === 2 && !openShow) listen.ensureShows(force)
    else if (tab === 2 && openShow) listen.ensureShow(openShow.podcastId, force)
    listen.ensureArtwork(visibleRows)
  }

  function refresh() {
    if (searchActive) {
      if (listen) listen.beginSearch(searchKind, searchText, searchPodcastId)
      return
    }
    if (tab === 1) return
    ensureData(true)
  }

  function openSearch() {
    if (!listen) return
    if (!searchActive) {
      savedTab = tab
      savedIndex = selectedIndex
      searchIndex = 0
      selectedIndex = 0
      searchText = ""
      searchKind = "episodes"
      searchPodcastId = tab === 2 && openShow ? openShow.podcastId : ""
      searchPodcastTitle = tab === 2 && openShow ? openShow.title : ""
    }
    searchActive = true
    if (searchField.text !== searchText) searchField.text = searchText
    Qt.callLater(function() { searchField.forceActiveFocus(); searchField.selectAll() })
  }

  function updateSearch(value) {
    searchText = String(value || "")
    searchIndex = 0
    selectedIndex = 0
    if (listen) listen.beginSearch(searchKind, searchText, searchPodcastId)
  }

  function setSearchKind(kind) {
    if (kind === "shows") {
      searchPodcastId = ""
      searchPodcastTitle = ""
    }
    searchKind = kind === "shows" ? "shows" : "episodes"
    searchIndex = 0
    selectedIndex = 0
    if (listen) listen.beginSearch(searchKind, searchText, searchPodcastId)
  }

  function clearScope() {
    searchPodcastId = ""
    searchPodcastTitle = ""
    if (listen) listen.beginSearch(searchKind, searchText, "")
  }

  function resetSearch() {
    if (listen) listen.clearSearch()
    searchActive = false
    searchText = ""
    searchPodcastId = ""
    searchPodcastTitle = ""
    searchIndex = 0
  }

  function exitSearch() {
    resetSearch()
    tab = savedTab
    restoreIndex()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function searchEscape() {
    if (searchActive && searchPodcastId) { clearScope(); return }
    if (searchActive) { exitSearch(); return }
    back()
  }

  function activateSearchSelection() {
    var item = searchRows[searchIndex]
    if (!item) { if (canLoadMore) loadMore(); return }
    selectedIndex = searchIndex
    if (item.kind === "show") {
      if (listen) listen.clearSearch()
      searchActive = false
      searchText = ""
      searchPodcastId = ""
      searchPodcastTitle = ""
      tab = 2
      openShow = item
      selectedIndex = 0
      showIndex = 0
      ensureData(false)
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
      return
    }
    if (listen) listen.playEpisode(item)
  }

  function loadMore() {
    if (!listen || !canLoadMore) return
    if (searchActive) listen.pageSearch()
    else if (tab === 2 && openShow) listen.pageShow(openShow.podcastId)
    else if (tab === 2) listen.pageShows()
  }

  function saveCurrentIndex() {
    if (searchActive) { searchIndex = selectedIndex; return }
    if (tab === 0) trendingIndex = selectedIndex
    else if (tab === 1) queueIndex = selectedIndex
    else if (openShow) showIndex = selectedIndex
    else showsIndex = selectedIndex
  }

  function restoreIndex() {
    var rows = visibleRows
    var index = searchActive ? searchIndex : (tab === 0 ? trendingIndex : (tab === 1 ? queueIndex : (openShow ? showIndex : showsIndex)))
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
    if (!listen) return
    if (searchActive) {
      if (searchRows.length && searchIndex > searchRows.length - 4) listen.pageSearch()
      return
    }
    if (tab !== 2) return
    if (!openShow && shows.length && selectedIndex > shows.length - 4) listen.pageShows()
    else if (openShow && showEpisodes.length && selectedIndex > showEpisodes.length - 4) listen.pageShow(openShow.podcastId)
  }

  function activateSelected() {
    if (searchActive) { searchIndex = selectedIndex; activateSearchSelection(); return }
    var item = visibleRows[selectedIndex]
    if (!item) { if (canLoadMore) loadMore(); return }
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
      // Leaving a show returns to All Shows: request the list when no fresh
      // cache exists (e.g. a show opened from Trending search on a cold cache).
      ensureData(false)
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
      blocked: searchField.activeFocus
      onMoveRequested: function(dx, dy) {
        if (root.searchActive) {
          if (dx < 0) root.exitSearch()
          else if (dy) root.moveCursor(dy)
          return
        }
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
      onCloseRequested: root.searchEscape()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) {
        if (text === "/") root.openSearch()
        else if (text === "r" || text === "R") root.refresh()
      }

      Shortcut {
        sequences: ["h"]
        enabled: root.opened && !root.searchActive
        onActivated: if (root.listen) root.listen.seekBy(-15)
      }
      Shortcut {
        sequences: ["l"]
        enabled: root.opened && !root.searchActive
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
            visible: !root.searchActive
            text: root.currentPlayback ? (root.currentPlayback.player.isPlaying ? "Playing now" : "Paused") : (root.openShow && root.tab === 2 ? root.openShow.title : "Something worth hearing")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }

          TextField {
            id: searchField
            width: parent.width
            visible: root.searchActive
            placeholderText: "Search titles"
            foreground: root.foreground
            font.family: root.fontFamily
            onTextChanged: if (root.searchActive && text !== root.searchText) root.updateSearch(text)
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Escape) {
                root.searchEscape()
                event.accepted = true
              } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                root.setSearchKind(root.searchKind === "shows" ? "episodes" : "shows")
                // Native Tab switches the search mode; keep typing in the field.
                searchField.forceActiveFocus()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                root.moveCursor(1)
                event.accepted = true
              } else if (event.key === Qt.Key_Up) {
                root.moveCursor(-1)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                root.activateSearchSelection()
                event.accepted = true
              }
            }
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
          // Queue has no origin to refresh, but an active search always does:
          // retry/refresh must stay available when search was entered from Queue.
          enabled: !root.refreshing && (root.searchActive || root.tab !== 1)
          onClicked: root.refresh()
        }
      }

      Row {
        id: tabBar
        visible: !root.searchActive
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

      Row {
        id: searchBar
        visible: root.searchActive
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Style.space(32)
        spacing: Style.space(12)
        leftPadding: Style.space(8)

        Text {
          text: "Episodes"
          color: root.searchKind === "episodes" ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: root.searchKind === "episodes"
          height: searchBar.height
          verticalAlignment: Text.AlignVCenter
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setSearchKind("episodes")
          }
        }

        Text {
          text: "Shows"
          color: root.searchKind === "shows" ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: root.searchKind === "shows"
          height: searchBar.height
          verticalAlignment: Text.AlignVCenter
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setSearchKind("shows")
          }
        }

        Text {
          text: "tab switches mode"
          color: root.dim
          opacity: 0.7
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          height: searchBar.height
          verticalAlignment: Text.AlignVCenter
        }

        Row {
          visible: root.searchPodcastId !== ""
          height: searchBar.height
          spacing: Style.space(4)

          Text {
            text: "in " + root.searchPodcastTitle
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
            width: Math.min(implicitWidth, Style.space(180))
          }

          Text {
            text: "✕"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            verticalAlignment: Text.AlignVCenter
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.clearScope()
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
            text: root.listIcon
            color: root.listAlert ? (root.bar ? root.bar.urgent : Color.urgent) : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.fontPx(2.2)
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(1, listArea.width - Style.space(48))
            text: root.listMessage
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.Wrap
            maximumLineCount: 3
            elide: Text.ElideRight
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.canLoadMore
            text: root.searchActive ? "enter for more results" : "enter for more"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            MouseArea {
              anchors.fill: parent
              cursorShape: Qt.PointingHandCursor
              onClicked: root.loadMore()
            }
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
                    source: root.listen ? root.listen.artworkFor(modelData) : modelData.artworkUrl
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
          text: root.searchActive
            ? "type to search  ·  tab episodes/shows  ·  ↑↓ choose  ·  enter open  ·  esc exit"
            : (root.errorText && root.visibleRows.length ? root.errorText : (root.launchingEpisodeId ? "Opening episode…" : (root.openShow && root.tab === 2 ? "esc/← back  ·  h/l seek  ·  enter play  ·  space pause" : "←→ tabs  ·  h/l seek  ·  enter play  ·  space pause")))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }
}
