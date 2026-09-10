import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import "Model.js" as Model

Item {
  id: root
  property var shell: null
  property var manifest: null
  property var pluginRegistry: null

  property var queue: []
  property var trending: []
  property var shows: []
  property var showsById: ({})
  property var artworkRequested: ({})
  property int showsTotal: 0
  property double trendingAt: 0
  property double showsAt: 0
  property string queuedId: ""
  property string launchingEpisodeId: ""
  property string pendingKind: ""
  property var fetchQueue: []
  property string apiBase: ""
  property int episodeLimit: 10
  property int staleAfterMs: 600000
  property real pendingSeek: 0
  property bool stateReady: false
  property bool hydrating: false
  property string errorText: ""
  property bool refreshing: false

  readonly property var mprisPlayers: Mpris.players ? Mpris.players.values : []
  readonly property var currentPlayback: findCurrentPlayback()
  readonly property var playbackPlayer: currentPlayback ? currentPlayback.player : null
  readonly property real playbackPosition: playbackPlayer && playbackPlayer.positionSupported ? Math.max(0, Number(playbackPlayer.position) || 0) : 0
  readonly property real playbackLength: playbackPlayer && playbackPlayer.lengthSupported ? Math.max(0, Number(playbackPlayer.length) || 0) : (currentPlayback ? currentPlayback.episode.duration : 0)
  readonly property bool canSeek: playbackPlayer !== null && playbackPlayer.canSeek === true
  readonly property string helperPath: decodeURIComponent(String(Qt.resolvedUrl("play.py")).replace(/^file:\/\//, ""))
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/dhwani-omarchy"

  function configure(base, limit, ttl) {
    if (base) apiBase = base
    if (limit) episodeLimit = limit
    if (ttl) staleAfterMs = ttl
  }

  function curlCommand(url) {
    return ["curl", "-fsSL", "--max-time", "12", "--max-filesize", "1048576", "--proto", "=http,https", "--proto-redir", "=http,https"].concat(Model.curlHeaders()).concat(["--", url])
  }

  function request(kind, url) {
    if (!kind || !url) return
    fetchQueue = Model.scheduleFetch(fetchQueue, kind, url)
    kickFetch()
  }

  function kickFetch() {
    if (netProcess.running) return
    var taken = Model.takeFetch(fetchQueue)
    if (!taken.job) return
    fetchQueue = taken.rest
    pendingKind = taken.job.kind
    refreshing = true
    errorText = ""
    netProcess.command = curlCommand(taken.job.url)
    netProcess.running = true
  }

  function ensureTrending(force) {
    if (!apiBase) return
    if (!force && trending.length && Model.isFresh(trendingAt, Date.now(), staleAfterMs)) return
    request("trending", Model.feedUrl(apiBase))
  }

  function ensureShows(force) {
    if (!apiBase) return
    if (!force && shows.length && Model.isFresh(showsAt, Date.now(), staleAfterMs)) return
    request("shows", Model.podcastsUrl(apiBase, 0))
  }

  function ensureShow(podcastId, force) {
    if (!apiBase || !podcastId) return
    var cached = showsById[podcastId]
    if (!force && cached && cached.episodes && cached.episodes.length && Model.isFresh(cached.fetchedAt, Date.now(), staleAfterMs)) return
    request("show", Model.showUrl(apiBase, podcastId, 0))
  }

  function pageShows() {
    if (!apiBase || !shows.length || shows.length >= showsTotal) return
    request("moreShows", Model.podcastsUrl(apiBase, shows.length))
  }

  function pageShow(podcastId) {
    var cached = showsById[podcastId]
    if (!apiBase || !cached || !cached.episodes || cached.episodes.length >= cached.total) return
    request("moreShow", Model.showUrl(apiBase, podcastId, cached.episodes.length))
  }

  function showRecord(podcastId) {
    return (showsById && podcastId && showsById[podcastId]) ? showsById[podcastId] : { episodes: [], total: 0, fetchedAt: 0, title: "" }
  }

  function putShow(podcastId, record) {
    var next = {}
    for (var key in showsById) next[key] = showsById[key]
    next[podcastId] = record
    showsById = next
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
      shows = kind === "moreShows" ? Model.mergeShows(shows, list.shows) : list.shows
      showsTotal = list.total
      showsAt = Date.now()
    } else if (kind === "show" || kind === "moreShow" || kind.indexOf("artwork:") === 0) {
      var detail = Model.parseShow(raw)
      if (!detail.ok) { errorText = detail.error; return }
      var id = detail.show ? detail.show.podcastId : ""
      if (!id) return
      var previous = showRecord(id)
      if (kind.indexOf("artwork:") === 0) {
        // Artwork lookups must not populate episodes or refresh their timestamp.
        previous.title = detail.show.title
        previous.artworkUrl = detail.show.artworkUrl
        putShow(id, previous)
      } else {
        putShow(id, {
          title: detail.show.title,
          artworkUrl: detail.show.artworkUrl,
          episodes: kind === "moreShow" ? Model.mergeEpisodes(previous.episodes, detail.episodes) : detail.episodes,
          total: detail.total,
          fetchedAt: Date.now()
        })
      }
    }
    errorText = ""
    saveSoon()
  }

  function artworkFor(item) {
    if (item.artworkUrl) return item.artworkUrl
    var cached = showRecord(item.podcastId)
    if (cached.artworkUrl) return cached.artworkUrl
    for (var i = 0; i < shows.length; i++)
      if (shows[i].podcastId === item.podcastId) return shows[i].artworkUrl || ""
    return ""
  }

  function ensureArtwork(items) {
    // Reuse saved artwork until show browsing updates it; retry misses after the TTL.
    if (!apiBase) return
    for (var i = 0; i < items.length; i++) {
      var item = items[i]
      if (item.kind === "show" || artworkFor(item)) continue
      var url = Model.showUrl(apiBase, item.podcastId, 0, 1)
      if (!url || Model.isFresh(artworkRequested[item.podcastId], Date.now(), staleAfterMs)) continue
      artworkRequested[item.podcastId] = Date.now()
      request("artwork:" + item.podcastId, url)
    }
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
    var items = trending.concat(queue)
    for (var id in showsById) {
      var record = showsById[id]
      if (record && record.episodes) items = items.concat(record.episodes)
    }
    return items
  }

  function findCurrentPlayback() {
    var items = allEpisodes()
    for (var i = 0; i < items.length; i++) {
      var player = playerFor(items[i])
      if (player) return { episode: items[i], player: player }
    }
    return null
  }

  function togglePlaying() {
    var player = playbackPlayer
    if (!player) return false
    if (player.isPlaying && player.canPause) player.pause()
    else if (!player.isPlaying && player.canPlay) player.play()
    else if (player.canTogglePlaying) player.togglePlaying()
    else return false
    rememberPlayback()
    return true
  }

  function seekBy(seconds) {
    if (!canSeek) return false
    playbackPlayer.seek(seconds)
    rememberPlayback()
    return true
  }

  function seekTo(progress) {
    if (!canSeek || !playbackPlayer.positionSupported || playbackLength <= 0) return false
    playbackPlayer.position = Math.max(0, Math.min(1, progress)) * playbackLength
    rememberPlayback()
    return true
  }

  function capturePlaying() {
    if (!currentPlayback) return
    var item = currentPlayback.episode
    var key = Model.episodeKey(item)
    if (!key || key === queuedId) return
    queue = Model.enqueue(queue, item)
    queuedId = key
    saveState()
  }

  function rememberPlayback() {
    if (!currentPlayback) return
    capturePlaying()
    queue = Model.rememberPosition(queue, currentPlayback.episode, playbackPosition, playbackLength)
    saveSoon()
  }

  function playEpisode(item) {
    if (!item || item.kind === "show" || !item.audioUrl || playerProcess.running) return
    queue = Model.enqueue(queue, item)
    queuedId = Model.episodeKey(item)
    saveState()
    var player = playerFor(item)
    if (player) {
      togglePlaying()
      return
    }
    launchingEpisodeId = item.episodeId || item.audioUrl
    pendingSeek = item.position > 5 ? item.position : 0
    errorText = ""
    playerProcess.command = ["python3", helperPath, item.audioUrl, Model.playbackTitle(item)]
    playerProcess.running = true
  }

  function applyState(raw, diskWins) {
    var state = Model.parseState(raw)
    queue = diskWins ? state.queue : Model.mergeQueue(state.queue, queue)
    queuedId = queue.length ? Model.episodeKey(queue[0]) : ""
    if (stateReady) return
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
    if (cache.showsById && typeof cache.showsById === "object") showsById = cache.showsById
  }

  function dumpState() {
    return JSON.stringify({
      schemaVersion: 1,
      queue: queue,
      nav: { tab: 0, trendingIndex: 0, queueIndex: 0, showsIndex: 0, showIndex: 0, openShowId: "", openShowTitle: "" },
      cache: {
        trending: { fetchedAt: trendingAt, episodes: trending },
        shows: { fetchedAt: showsAt, items: shows, total: showsTotal },
        showsById: showsById
      }
    })
  }

  function saveState() {
    if (hydrating) {
      saveTimer.restart()
      return
    }
    hydrating = true
    stateFile.setText(dumpState())
    Qt.callLater(function() { hydrating = false })
  }

  function saveSoon() { saveTimer.restart() }

  Process {
    id: netProcess
    command: []
    stdout: StdioCollector { id: netStdout; waitForEnd: true }
    stderr: StdioCollector { id: netStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode === 0) root.applyNetwork(netStdout.text)
      else root.errorText = (netStderr.text || "").replace(/\s+/g, " ").trim() || "Dhwani is out of reach"
      root.pendingKind = ""
      root.kickFetch()
    }
  }

  Process {
    id: playerProcess
    command: []
    stderr: StdioCollector { id: playerStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.launchingEpisodeId = ""
      if (exitCode !== 0) root.errorText = (playerStderr.text || "").replace(/\s+/g, " ").trim() || "The episode could not start"
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
    watchChanges: true
    printErrors: false
    onFileChanged: if (!root.hydrating) reload()
    onLoaded: {
      if (root.hydrating) {
        root.stateReady = true
        return
      }
      var already = root.stateReady
      root.applyState(text(), already)
      root.stateReady = true
    }
    onLoadFailed: {
      if (root.stateReady || root.hydrating) return
      root.applyState("", false)
      root.stateReady = true
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
    running: root.playbackPlayer && root.playbackPlayer.isPlaying && root.playbackPlayer.positionSupported
    onTriggered: {
      if (root.playbackPlayer) root.playbackPlayer.positionChanged()
      root.capturePlaying()
      if (root.currentPlayback && root.pendingSeek > 0 && root.playbackLength > 0) {
        root.seekTo(root.pendingSeek / root.playbackLength)
        root.pendingSeek = 0
      }
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.playbackPlayer !== null
    onTriggered: root.rememberPlayback()
  }
}
