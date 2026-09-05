function clean(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function normalizeBaseUrl(value) {
  var url = clean(value).replace(/\/+$/, "")
  return /^https?:\/\/[^\s]+$/i.test(url) ? url : ""
}

function originHeader() {
  return "https://podcast.dhwani.io"
}

function userAgent() {
  return "Dhwani-Omarchy/0.1 (+https://github.com/arorashu/dhwani-omarchy)"
}

function curlHeaders() {
  return [
    "-H", "Accept: application/json",
    "-H", "Origin: " + originHeader(),
    "-H", "User-Agent: " + userAgent(),
  ]
}

function pageSize() {
  return 20
}

function feedUrl(baseUrl) {
  var base = normalizeBaseUrl(baseUrl)
  return base ? base + "/v1/foryou/all" : ""
}

function podcastsUrl(baseUrl, offset) {
  var base = normalizeBaseUrl(baseUrl)
  return base ? base + "/v1/podcasts?limit=" + pageSize() + "&offset=" + Math.max(0, parseInt(offset, 10) || 0) : ""
}

function showUrl(baseUrl, podcastId, offset) {
  var base = normalizeBaseUrl(baseUrl)
  var id = clean(podcastId)
  if (!base || !/^[A-Za-z0-9]{20}$/.test(id)) return ""
  return base + "/v1/podcasts/" + id + "?limit=" + pageSize() + "&offset=" + Math.max(0, parseInt(offset, 10) || 0)
}

function playableUrl(options) {
  if (!Array.isArray(options)) return ""
  var ordered = []
  for (var i = 0; i < options.length; i++) if (options[i] && options[i].is_primary === true) ordered.push(options[i])
  for (var j = 0; j < options.length; j++) if (ordered.indexOf(options[j]) === -1) ordered.push(options[j])
  for (var k = 0; k < ordered.length; k++) {
    var option = ordered[k] || {}
    var url = clean(option.path || option.source_id)
    if (/^https?:\/\/[^\s]+$/i.test(url)) return url
  }
  return ""
}

function decodePayload(raw) {
  var payload
  try {
    payload = JSON.parse(String(raw || ""))
  } catch (e) {
    return { ok: false, error: "Dhwani returned unreadable data" }
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload))
    return { ok: false, error: "Dhwani returned no feed" }
  if (payload.detail) {
    var detail = typeof payload.detail === "string" ? clean(payload.detail) : ""
    return { ok: false, error: detail || "Dhwani request failed" }
  }
  return { ok: true, error: "", payload: payload }
}

function episode(item, fallbackPodcast) {
  if (!item || typeof item !== "object") return null
  var audioUrl = playableUrl(item.media_options)
  var title = clean(item.title)
  if (!audioUrl || !title) return null
  var podcastTitle = clean(item.podcast_title) || clean(fallbackPodcast && fallbackPodcast.title) || "Podcast"
  var artwork = clean(item.artwork_url) || clean(fallbackPodcast && fallbackPodcast.artwork_url)
  return {
    kind: "episode",
    episodeId: clean(item.episode_id || item.video_id),
    podcastId: clean(item.podcast_id || (fallbackPodcast && fallbackPodcast.podcast_id)),
    title: title,
    podcastTitle: podcastTitle,
    artworkUrl: /^https?:\/\//i.test(artwork) ? artwork : "",
    audioUrl: audioUrl,
    duration: Math.max(0, parseInt(item.duration, 10) || 0),
    position: Math.max(0, Number(item.position) || 0),
  }
}

function showItem(item) {
  if (!item || typeof item !== "object") return null
  var title = clean(item.title)
  var podcastId = clean(item.podcast_id)
  if (!title || !/^[A-Za-z0-9]{20}$/.test(podcastId)) return null
  return {
    kind: "show",
    podcastId: podcastId,
    title: title,
    podcastTitle: title,
    artworkUrl: /^https?:\/\//i.test(clean(item.artwork_url)) ? clean(item.artwork_url) : "",
    episodeCount: Math.max(0, parseInt(item.episode_count, 10) || 0),
  }
}

function uniqueEpisodes(source, limit, fallbackPodcast) {
  var cap = Math.max(1, parseInt(limit, 10) || 20)
  var seen = {}
  var episodes = []
  for (var i = 0; i < source.length && episodes.length < cap; i++) {
    var normalized = episode(source[i], fallbackPodcast)
    if (!normalized) continue
    var key = normalized.episodeId || normalized.audioUrl
    if (seen[key]) continue
    seen[key] = true
    episodes.push(normalized)
  }
  return episodes
}

function parseFeed(raw, limit) {
  var decoded = decodePayload(raw)
  if (!decoded.ok) return { ok: false, error: decoded.error, episodes: [] }
  var payload = decoded.payload
  var source = []
  if (payload.daily_listen) source.push(payload.daily_listen)
  var groups = [payload.picks, payload.trending]
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i]
    if (!Array.isArray(group)) continue
    for (var j = 0; j < group.length; j++) source.push(group[j])
  }
  return { ok: true, error: "", episodes: uniqueEpisodes(source, limit), generatedAt: clean(payload.generated_at) }
}

function parseTrending(raw, limit) {
  var decoded = decodePayload(raw)
  if (!decoded.ok) return { ok: false, error: decoded.error, episodes: [] }
  var source = Array.isArray(decoded.payload.trending) ? decoded.payload.trending : []
  return { ok: true, error: "", episodes: uniqueEpisodes(source, limit), generatedAt: clean(decoded.payload.generated_at) }
}

function parsePodcasts(raw) {
  var decoded = decodePayload(raw)
  if (!decoded.ok) return { ok: false, error: decoded.error, shows: [], total: 0, offset: 0 }
  var payload = decoded.payload
  var source = Array.isArray(payload.podcasts) ? payload.podcasts : []
  var shows = []
  var seen = {}
  for (var i = 0; i < source.length; i++) {
    var show = showItem(source[i])
    if (!show || seen[show.podcastId]) continue
    seen[show.podcastId] = true
    shows.push(show)
  }
  return {
    ok: true,
    error: "",
    shows: shows,
    total: Math.max(shows.length, parseInt(payload.total, 10) || 0),
    offset: Math.max(0, parseInt(payload.offset, 10) || 0),
  }
}

function parseShow(raw) {
  var decoded = decodePayload(raw)
  if (!decoded.ok) return { ok: false, error: decoded.error, episodes: [], total: 0, offset: 0, show: null }
  var payload = decoded.payload
  var podcast = payload.podcast && typeof payload.podcast === "object" ? payload.podcast : {}
  var show = showItem(podcast)
  var source = Array.isArray(payload.episodes) ? payload.episodes : []
  return {
    ok: true,
    error: "",
    show: show,
    episodes: uniqueEpisodes(source, source.length || 1, podcast),
    total: Math.max(0, parseInt(payload.total_episodes, 10) || 0),
    offset: Math.max(0, parseInt(payload.offset, 10) || 0),
  }
}

function playbackTitle(item) {
  if (!item) return ""
  var title = clean(item.title)
  var podcast = clean(item.podcastTitle)
  return title + (podcast ? " · " + podcast : "")
}

function formatDuration(seconds) {
  var value = Math.max(0, Math.round(Number(seconds) || 0))
  if (!value) return ""
  var hours = Math.floor(value / 3600)
  var minutes = Math.floor((value % 3600) / 60)
  if (hours) return hours + "h " + (minutes < 10 ? "0" : "") + minutes + "m"
  return Math.max(1, minutes) + "m"
}

function formatPosition(seconds) {
  var value = Math.max(0, Math.floor(Number(seconds) || 0))
  var hours = Math.floor(value / 3600)
  var minutes = Math.floor((value % 3600) / 60)
  var remainder = value % 60
  var secondsText = (remainder < 10 ? "0" : "") + remainder
  if (hours) return hours + ":" + (minutes < 10 ? "0" : "") + minutes + ":" + secondsText
  return minutes + ":" + secondsText
}

function playbackProgress(position, length) {
  var total = Number(length) || 0
  if (total <= 0) return 0
  return Math.max(0, Math.min(1, (Number(position) || 0) / total))
}

function episodeKey(item) {
  return item ? clean(item.episodeId || item.audioUrl) : ""
}

function coerceEpisode(item) {
  if (!item || typeof item !== "object") return null
  if (item.audioUrl && item.title && item.kind !== "show") {
    return {
      kind: "episode",
      episodeId: clean(item.episodeId || item.episode_id || item.video_id),
      podcastId: clean(item.podcastId || item.podcast_id),
      title: clean(item.title),
      podcastTitle: clean(item.podcastTitle || item.podcast_title) || "Podcast",
      artworkUrl: /^https?:\/\//i.test(clean(item.artworkUrl || item.artwork_url)) ? clean(item.artworkUrl || item.artwork_url) : "",
      audioUrl: clean(item.audioUrl),
      duration: Math.max(0, parseInt(item.duration, 10) || 0),
      position: Math.max(0, Number(item.position) || 0),
    }
  }
  return episode(item)
}

function enqueue(queue, item) {
  var incoming = coerceEpisode(item)
  if (!incoming) return Array.isArray(queue) ? queue.slice() : []
  var key = episodeKey(incoming)
  var next = [incoming]
  var source = Array.isArray(queue) ? queue : []
  for (var i = 0; i < source.length; i++) {
    if (episodeKey(source[i]) === key) continue
    next.push(source[i])
  }
  return next.slice(0, 100)
}

function mergeQueue(disk, memory) {
  var merged = Array.isArray(disk) ? disk.slice() : []
  var live = Array.isArray(memory) ? memory : []
  for (var i = live.length - 1; i >= 0; i--) merged = enqueue(merged, live[i])
  return merged
}

function rememberPosition(queue, item, position, duration) {
  var key = episodeKey(item)
  if (!key) return Array.isArray(queue) ? queue.slice() : []
  var next = []
  var source = Array.isArray(queue) ? queue : []
  for (var i = 0; i < source.length; i++) {
    var current = source[i]
    if (episodeKey(current) !== key) {
      next.push(current)
      continue
    }
    var copy = {}
    for (var field in current) if (Object.prototype.hasOwnProperty.call(current, field)) copy[field] = current[field]
    copy.position = Math.max(0, Number(position) || 0)
    if (duration) copy.duration = Math.max(copy.duration || 0, Number(duration) || 0)
    next.push(copy)
  }
  return next
}

function isFresh(fetchedAt, now, ttlMs) {
  var stamp = Number(fetchedAt) || 0
  var ttl = Math.max(30000, Number(ttlMs) || 600000)
  return stamp > 0 && now - stamp < ttl
}

function emptyNav() {
  return {
    tab: 0,
    trendingIndex: 0,
    queueIndex: 0,
    showsIndex: 0,
    showIndex: 0,
    openShowId: "",
    openShowTitle: "",
  }
}

function emptyState() {
  return { schemaVersion: 1, queue: [], nav: emptyNav(), cache: { trending: null, shows: null, showsById: {} } }
}

function parseState(raw) {
  var decoded = decodePayload(raw)
  if (!decoded.ok || decoded.payload.schemaVersion !== 1) return emptyState()
  var payload = decoded.payload
  var queue = []
  var source = Array.isArray(payload.queue) ? payload.queue : []
  for (var i = 0; i < source.length && queue.length < 100; i++) {
    var item = coerceEpisode(source[i])
    if (item) queue.push(item)
  }
  var navIn = payload.nav && typeof payload.nav === "object" ? payload.nav : {}
  var nav = emptyNav()
  nav.tab = Math.max(0, Math.min(2, parseInt(navIn.tab, 10) || 0))
  nav.trendingIndex = Math.max(0, parseInt(navIn.trendingIndex, 10) || 0)
  nav.queueIndex = Math.max(0, parseInt(navIn.queueIndex, 10) || 0)
  nav.showsIndex = Math.max(0, parseInt(navIn.showsIndex, 10) || 0)
  nav.showIndex = Math.max(0, parseInt(navIn.showIndex, 10) || 0)
  nav.openShowId = /^[A-Za-z0-9]{20}$/.test(clean(navIn.openShowId)) ? clean(navIn.openShowId) : ""
  nav.openShowTitle = clean(navIn.openShowTitle)
  return { schemaVersion: 1, queue: queue, nav: nav, cache: payload.cache && typeof payload.cache === "object" ? payload.cache : emptyState().cache }
}

if (typeof module !== "undefined") {
  module.exports = {
    normalizeBaseUrl: normalizeBaseUrl,
    feedUrl: feedUrl,
    podcastsUrl: podcastsUrl,
    showUrl: showUrl,
    curlHeaders: curlHeaders,
    playableUrl: playableUrl,
    playbackTitle: playbackTitle,
    parseFeed: parseFeed,
    parseTrending: parseTrending,
    parsePodcasts: parsePodcasts,
    parseShow: parseShow,
    formatDuration: formatDuration,
    formatPosition: formatPosition,
    playbackProgress: playbackProgress,
    episodeKey: episodeKey,
    enqueue: enqueue,
    mergeQueue: mergeQueue,
    rememberPosition: rememberPosition,
    isFresh: isFresh,
    parseState: parseState,
    emptyState: emptyState,
    coerceEpisode: coerceEpisode,
    pageSize: pageSize,
  }
}
