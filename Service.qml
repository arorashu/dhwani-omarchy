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
  property int showsNextOffset: 0
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
  property string pendingSeekEpisodeId: ""
  property bool stateReady: false
  property bool hydrating: false
  property string errorText: ""
  property bool refreshing: false
  property string searchQuery: ""
  property string searchKind: "episodes"
  property string searchPodcastId: ""
  property var searchEpisodes: []
  property var searchShows: []
  property int searchTotal: 0
  property int searchNextOffset: 0
  property int searchRequestedOffset: -1
  property bool searchLoading: false
  property string searchError: ""
  property int searchGeneration: 0
  property int pendingGeneration: -1

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

  function request(kind, url, token) {
    if (!kind || !url) return
    fetchQueue = Model.scheduleFetch(fetchQueue, kind, url, token)
    kickFetch()
  }

  function kickFetch() {
    if (netProcess.running) return
    var taken = Model.takeFetch(fetchQueue)
    if (!taken.job) return
    fetchQueue = taken.rest
    pendingKind = taken.job.kind
    pendingGeneration = Number(taken.job.token)
    if (isNaN(pendingGeneration)) pendingGeneration = -1
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
    if (!apiBase || showsNextOffset <= 0 || showsNextOffset >= showsTotal) return
    request("moreShows", Model.podcastsUrl(apiBase, showsNextOffset))
  }

  function pageShow(podcastId) {
    var cached = showsById[podcastId]
    if (!apiBase || !cached) return
    var next = showNextOffset(cached)
    if (next <= 0 || next >= cached.total) return
    request("moreShow", Model.showUrl(apiBase, podcastId, next))
  }

  function showNextOffset(record) {
    if (!record) return 0
    if (record.nextOffset !== undefined && record.nextOffset !== null) return Math.max(0, parseInt(record.nextOffset, 10) || 0)
    return record.episodes ? record.episodes.length : 0
  }

  function showRecord(podcastId) {
    return (showsById && podcastId && showsById[podcastId]) ? showsById[podcastId] : { episodes: [], total: 0, nextOffset: 0, fetchedAt: 0, title: "" }
  }

  function beginSearch(kind, query, podcastId) {
    searchGeneration = searchGeneration + 1
    searchKind = kind === "shows" ? "shows" : "episodes"
    searchQuery = String(query || "").trim()
    searchPodcastId = searchKind === "episodes" ? String(podcastId || "") : ""
    searchError = ""
    searchRequestedOffset = -1
    fetchQueue = Model.dropFetches(fetchQueue, ["search", "moreSearch"])
    searchEpisodes = []
    searchShows = []
    searchTotal = 0
    searchNextOffset = 0
    if (!searchQuery) {
      searchTimer.stop()
      searchLoading = false
      return
    }
    // Invalidate the previous query's rows before the debounce fires; the pending
    // state must not advertise results the user can still play.
    searchLoading = true
    searchTimer.restart()
  }

  function applyNetworkFailure(kind, generation, message) {
    if (kind === "search" || kind === "moreSearch") {
      if (generation !== searchGeneration) return
      searchLoading = false
      searchRequestedOffset = -1
      searchError = message
      return
    }
    errorText = message
  }

  function runSearch() {
    var url = ""
    if (apiBase && searchQuery) {
      try {
        url = Model.titleSearchUrl(apiBase, searchKind, searchQuery, 0, searchPodcastId)
      } catch (e) {
        url = ""
      }
    }
    if (!url) {
      // A missing base or a query that cannot be encoded must fail the pending
      // search instead of leaving the debounce's "Searching…" state up forever.
      searchLoading = false
      searchRequestedOffset = -1
      searchError = searchQuery ? (apiBase ? "Dhwani could not search that query" : "Dhwani search is unavailable") : ""
      return
    }
    searchLoading = true
    searchRequestedOffset = 0
    searchNextOffset = 0
    request("search", url, searchGeneration)
  }

  function pageSearch() {
    if (!apiBase || !searchQuery || searchLoading) return
    if (searchNextOffset <= 0 || searchNextOffset >= searchTotal) return
    if (searchRequestedOffset === searchNextOffset) return
    var url = ""
    try {
      url = Model.titleSearchUrl(apiBase, searchKind, searchQuery, searchNextOffset, searchPodcastId)
    } catch (e) {
      url = ""
    }
    if (!url) {
      searchLoading = false
      searchRequestedOffset = -1
      searchError = "Dhwani could not search that query"
      return
    }
    searchLoading = true
    searchRequestedOffset = searchNextOffset
    request("moreSearch", url, searchGeneration)
  }

  function clearSearch() {
    searchTimer.stop()
    searchGeneration = searchGeneration + 1
    searchQuery = ""
    searchPodcastId = ""
    searchEpisodes = []
    searchShows = []
    searchTotal = 0
    searchNextOffset = 0
    searchRequestedOffset = -1
    searchLoading = false
    searchError = ""
    fetchQueue = Model.dropFetches(fetchQueue, ["search", "moreSearch"])
  }

  function putShow(podcastId, record) {
    var next = {}
    for (var key in showsById) next[key] = showsById[key]
    next[podcastId] = record
    showsById = next
  }

  function applyNetwork(raw) {
    var kind = pendingKind
    var searching = kind === "search" || kind === "moreSearch"
    // Reject a stale generation before any size/parse branch can touch current state.
    if (searching && pendingGeneration !== searchGeneration) return
    if (String(raw || "").length > 1048576) {
      if (searching) applyNetworkFailure(kind, pendingGeneration, "Dhwani returned too much data")
      else errorText = "Dhwani returned too much data"
      return
    }
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
      showsNextOffset = list.nextOffset
      showsAt = Date.now()
    } else if (kind === "search" || kind === "moreSearch") {
      var found = Model.parseTitleSearch(raw)
      if (!found.ok) { applyNetworkFailure(kind, pendingGeneration, found.error); return }
      searchLoading = false
      searchError = ""
      searchRequestedOffset = -1
      if (found.kind === "shows") {
        searchShows = kind === "moreSearch" ? Model.mergeShows(searchShows, found.shows) : found.shows
        searchEpisodes = []
      } else {
        searchEpisodes = kind === "moreSearch" ? Model.mergeEpisodes(searchEpisodes, found.episodes) : found.episodes
        searchShows = []
      }
      searchTotal = found.total
      searchNextOffset = found.nextOffset
      return
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
          nextOffset: detail.nextOffset,
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

  function mpvPlayerMedia(player) {
    if (!player) return null
    var app = String(player.identity || player.desktopEntry || "").toLowerCase()
    if (app !== "mpv") return null
    var map = player.metadata && typeof player.metadata === "object" ? player.metadata : null
    var url = map && map["xesam:url"] !== undefined && map["xesam:url"] !== null ? String(map["xesam:url"]) : ""
    return { player: player, url: url, label: String(player.trackTitle || "") }
  }

  // Identify the mpv player actually playing `item`. MPRIS xesam:url (mpv's
  // loaded path) is the identity source, and it must agree with the expected
  // human label: the loaded catalog pages are incomplete, so local title
  // uniqueness is not proof, and requiring both also ignores mixed old/new
  // metadata and unrelated mpv instances. Without usable metadata no row is
  // claimed (rather than guessing from a title).
  function playerFor(item) {
    if (!item || item.kind === "show") return null
    var url = String(item.audioUrl || "")
    if (!url) return null
    var label = Model.playbackTitle(item)
    for (var i = 0; i < mprisPlayers.length; i++) {
      var media = mpvPlayerMedia(mprisPlayers[i])
      if (media && media.url === url && media.label === label) return media.player
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
      if (!player) continue
      // A just-launched track can briefly leave the previous track's metadata
      // on the bus. Never report the old row (and never save its position) for
      // the incoming episode while that transition is unconfirmed.
      if (pendingSeekEpisodeId && Model.episodeKey(items[i]) !== pendingSeekEpisodeId) return null
      return { episode: items[i], player: player }
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
    queue = Model.enqueue(queue, Model.resumeEpisode(queue, item))
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
    if (!item || item.kind === "show" || !Model.isPlayableAudioUrl(item.audioUrl) || playerProcess.running) return
    rememberPlayback()
    item = Model.resumeEpisode(queue, item)
    if (!item) return
    queue = Model.enqueue(queue, item)
    queuedId = Model.episodeKey(item)
    saveState()
    var player = playerFor(item)
    // A different pending load must be replaced, even if old metadata still
    // matches this item; playbackPlayer is guarded during that transition.
    if (player && (!pendingSeekEpisodeId || pendingSeekEpisodeId === Model.episodeKey(item))) {
      togglePlaying()
      return
    }
    launchingEpisodeId = item.episodeId || item.audioUrl
    pendingSeek = item.position > 5 ? item.position : 0
    pendingSeekEpisodeId = Model.episodeKey(item)
    errorText = ""
    playerProcess.command = ["python3", helperPath, item.audioUrl, Model.playbackTitle(item)]
    playerProcess.running = true
  }

  function resumePendingPlayback() {
    if (!currentPlayback || !pendingSeekEpisodeId) return
    if (Model.episodeKey(currentPlayback.episode) !== pendingSeekEpisodeId) return
    if (pendingSeek > 0) {
      if (playbackLength <= 0) return
      if (!seekTo(pendingSeek / playbackLength)) return
    }
    // The requested episode is confirmed as the current one: clear the
    // transition marker so later external playback resolves normally.
    pendingSeek = 0
    pendingSeekEpisodeId = ""
  }

  function playbackHelperExited(exitCode, stderrText) {
    launchingEpisodeId = ""
    if (exitCode === 0) return
    errorText = String(stderrText || "").replace(/\s+/g, " ").trim() || "The episode could not start"
    // A failed launch must not leave the transition guard suppressing the
    // still-valid previous playback forever.
    pendingSeek = 0
    pendingSeekEpisodeId = ""
  }

  function applyState(raw, diskWins) {
    var state = Model.parseState(raw)
    queue = diskWins ? state.queue : Model.mergeQueue(state.queue, queue)
    queuedId = queue.length ? Model.episodeKey(queue[0]) : ""
    if (stateReady) return
    var cache = state.cache || {}
    if (cache.trending && cache.trending.episodes) {
      // Cached rows predate the current playback policy: drop unplayable
      // (YouTube) rows while keeping the saved row objects and metadata.
      trending = Model.filterCachedEpisodes(cache.trending.episodes)
      trendingAt = Number(cache.trending.fetchedAt) || 0
    }
    if (cache.shows && cache.shows.items) {
      shows = cache.shows.items
      showsTotal = Number(cache.shows.total) || shows.length
      // Raw list offset, so pagination survives a restart; legacy states fall
      // back to the stored show count (before any row is filtered).
      showsNextOffset = Model.cachedNextOffset(cache.shows, shows.length)
      showsAt = Number(cache.shows.fetchedAt) || 0
    }
    if (cache.showsById && typeof cache.showsById === "object") {
      var records = {}
      for (var id in cache.showsById) {
        if (!Object.prototype.hasOwnProperty.call(cache.showsById, id)) continue
        var record = cache.showsById[id]
        if (!record || typeof record !== "object") continue
        var loaded = Array.isArray(record.episodes) ? record.episodes.length : 0
        var copy = {}
        for (var field in record)
          if (Object.prototype.hasOwnProperty.call(record, field)) copy[field] = record[field]
        copy.episodes = Model.filterCachedEpisodes(record.episodes)
        copy.nextOffset = Model.cachedNextOffset(record, loaded)
        records[id] = copy
      }
      showsById = records
    }
  }

  function dumpState() {
    return JSON.stringify({
      schemaVersion: 1,
      queue: queue,
      nav: { tab: 0, trendingIndex: 0, queueIndex: 0, showsIndex: 0, showIndex: 0, openShowId: "", openShowTitle: "" },
      cache: {
        trending: { fetchedAt: trendingAt, episodes: trending },
        shows: { fetchedAt: showsAt, items: shows, total: showsTotal, nextOffset: showsNextOffset },
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
      var kind = root.pendingKind
      var generation = root.pendingGeneration
      if (exitCode === 0) root.applyNetwork(netStdout.text)
      else root.applyNetworkFailure(kind, generation, (netStderr.text || "").replace(/\s+/g, " ").trim() || "Dhwani is out of reach")
      root.pendingKind = ""
      root.pendingGeneration = -1
      root.kickFetch()
    }
  }

  Process {
    id: playerProcess
    command: []
    stderr: StdioCollector { id: playerStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.playbackHelperExited(exitCode, playerStderr.text)
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
    id: searchTimer
    interval: 250
    repeat: false
    onTriggered: root.runSearch()
  }

  Timer {
    // Confirming a launch must not depend on the player already reporting
    // "playing": a paused, zero-position track still has to clear the marker.
    interval: 250
    repeat: true
    running: root.pendingSeekEpisodeId !== ""
    onTriggered: root.resumePendingPlayback()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.playbackPlayer && root.playbackPlayer.isPlaying && root.playbackPlayer.positionSupported
    onTriggered: {
      if (root.playbackPlayer) root.playbackPlayer.positionChanged()
      root.capturePlaying()
      root.resumePendingPlayback()
    }
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.playbackPlayer !== null
    onTriggered: root.rememberPlayback()
  }
}
