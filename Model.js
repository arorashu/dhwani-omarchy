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
  return "Dhwani-Omarchy/0.2.0 (+https://github.com/arorashu/dhwani-omarchy)"
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

function hostOf(url) {
  var match = /^https?:\/\/([^/?#]+)/i.exec(clean(url))
  if (!match) return ""
  return match[1].split("@").pop().split(":")[0].toLowerCase().replace(/\.$/, "")
}

function isYouTubeUrl(url) {
  var host = hostOf(url)
  return /(^|\.)(youtube\.com|youtu\.be|youtube-nocookie\.com)$/.test(host)
}

function isPlayableAudioUrl(url) {
  return /^https?:\/\/[^\s]+$/i.test(clean(url)) && !isYouTubeUrl(url)
}

function isAudioOption(option) {
  if (!option || typeof option !== "object") return false
  if (clean(option.source_type).toLowerCase() === "youtube") return false
  if (clean(option.mime_type || option.mimeType).toLowerCase().indexOf("video/") === 0) return false
  return !isYouTubeUrl(clean(option.path || option.source_id))
}

function feedUrl(baseUrl) {
  var base = normalizeBaseUrl(baseUrl)
  return base ? base + "/v1/foryou/all" : ""
}

function podcastsUrl(baseUrl, offset) {
  var base = normalizeBaseUrl(baseUrl)
  return base ? base + "/v1/podcasts?limit=" + pageSize() + "&offset=" + Math.max(0, parseInt(offset, 10) || 0) : ""
}

function showUrl(baseUrl, podcastId, offset, limit) {
  var base = normalizeBaseUrl(baseUrl)
  var id = clean(podcastId)
  if (!base || !/^[A-Za-z0-9]{20}$/.test(id)) return ""
  return base + "/v1/podcasts/" + id + "?limit=" + (limit || pageSize()) + "&offset=" + Math.max(0, parseInt(offset, 10) || 0)
}

function playableUrl(options) {
  if (!Array.isArray(options)) return ""
  var ranked = []
  for (var i = 0; i < options.length; i++) {
    var option = options[i]
    if (!option) continue
    var audio = isAudioOption(option)
    ranked.push({ option: option, rank: (audio ? 2 : 0) + (option.is_primary === true ? 1 : 0), index: i })
  }
  ranked.sort(function(a, b) { return b.rank - a.rank || a.index - b.index })
  for (var k = 0; k < ranked.length; k++) {
    if (!isAudioOption(ranked[k].option)) continue
    var url = clean(ranked[k].option.path || ranked[k].option.source_id)
    if (isPlayableAudioUrl(url)) return url
  }
  return ""
}

function titleSearchUrl(baseUrl, kind, query, offset, podcastId) {
  var base = normalizeBaseUrl(baseUrl)
  var text = clean(query).slice(0, 100)
  if (!base || !text) return ""
  var mode = kind === "shows" ? "shows" : "episodes"
  var url = base + "/v1/search/titles?q=" + encodeURIComponent(text) + "&kind=" + mode
    + "&limit=" + pageSize() + "&offset=" + Math.max(0, parseInt(offset, 10) || 0)
  var id = clean(podcastId)
  if (mode === "episodes" && /^[A-Za-z0-9]{20}$/.test(id)) url += "&podcast_id=" + id
  return url
}

function searchKey(kind, query, podcastId) {
  return (kind === "shows" ? "shows" : "episodes") + "\u0000" + clean(query) + "\u0000" + clean(podcastId)
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
  var episodeArtwork = clean(item.artwork_url)
  var showArtwork = clean(item.podcast_artwork_url) || clean(fallbackPodcast && fallbackPodcast.artwork_url)
  var artwork = /^https?:\/\//i.test(episodeArtwork) ? episodeArtwork : showArtwork
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

function parseTitleSearch(raw) {
  var empty = { ok: false, error: "", kind: "episodes", query: "", episodes: [], shows: [], total: 0, limit: 0, offset: 0, nextOffset: 0 }
  var decoded = decodePayload(raw)
  if (!decoded.ok) return Object.assign(empty, { error: decoded.error })
  var payload = decoded.payload
  var kind = payload.kind === "shows" ? "shows" : "episodes"
  var offset = Math.max(0, parseInt(payload.offset, 10) || 0)
  var limit = Math.max(0, parseInt(payload.limit, 10) || 0)
  var source = Array.isArray(payload[kind === "shows" ? "podcasts" : "episodes"]) ? payload[kind === "shows" ? "podcasts" : "episodes"] : []
  return {
    ok: true,
    error: "",
    kind: kind,
    query: clean(payload.query),
    episodes: kind === "shows" ? [] : uniqueEpisodes(source, source.length || 1),
    shows: kind === "shows" ? parseShows(source) : [],
    total: Math.max(0, parseInt(payload.total, 10) || 0),
    limit: limit,
    offset: offset,
    nextOffset: offset + (limit || source.length),
  }
}

function parseShows(source) {
  var shows = []
  var seen = {}
  for (var i = 0; i < source.length; i++) {
    var show = showItem(source[i])
    if (!show || seen[show.podcastId]) continue
    seen[show.podcastId] = true
    shows.push(show)
  }
  return shows
}

function parseTrending(raw, limit) {
  var decoded = decodePayload(raw)
  if (!decoded.ok) return { ok: false, error: decoded.error, episodes: [] }
  var source = Array.isArray(decoded.payload.trending) ? decoded.payload.trending : []
  return { ok: true, error: "", episodes: uniqueEpisodes(source, limit), generatedAt: clean(decoded.payload.generated_at) }
}

function parsePodcasts(raw) {
  var decoded = decodePayload(raw)
  if (!decoded.ok) return { ok: false, error: decoded.error, shows: [], total: 0, limit: 0, offset: 0, nextOffset: 0 }
  var payload = decoded.payload
  var source = Array.isArray(payload.podcasts) ? payload.podcasts : []
  var shows = parseShows(source)
  var offset = Math.max(0, parseInt(payload.offset, 10) || 0)
  var limit = Math.max(0, parseInt(payload.limit, 10) || 0)
  return {
    ok: true,
    error: "",
    shows: shows,
    total: Math.max(shows.length, parseInt(payload.total, 10) || 0),
    limit: limit,
    offset: offset,
    nextOffset: offset + (limit || source.length),
  }
}

function parseShow(raw) {
  var decoded = decodePayload(raw)
  if (!decoded.ok) return { ok: false, error: decoded.error, episodes: [], total: 0, limit: 0, offset: 0, nextOffset: 0, show: null }
  var payload = decoded.payload
  var podcast = payload.podcast && typeof payload.podcast === "object" ? payload.podcast : {}
  var show = showItem(podcast)
  var source = Array.isArray(payload.episodes) ? payload.episodes : []
  var offset = Math.max(0, parseInt(payload.offset, 10) || 0)
  var limit = Math.max(0, parseInt(payload.limit, 10) || 0)
  return {
    ok: true,
    error: "",
    show: show,
    episodes: uniqueEpisodes(source, source.length || 1, podcast),
    total: Math.max(0, parseInt(payload.total_episodes, 10) || 0),
    limit: limit,
    offset: offset,
    nextOffset: offset + (limit || source.length),
  }
}

var playbackTitleLimit = 240
// play.py normalizes the label with Python's str.split(), whose whitespace set
// differs from JS \s: it includes \x1c-\x1f and \x85 and excludes the BOM.
// Mirror Python exactly so the Model label equals what mpv/MPRIS reports.
var playbackWhitespace = /[\t\n\v\f\r\x1c-\x1f \x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000]+/g

function playbackTitle(item) {
  if (!item) return ""
  var title = clean(item.title)
  var podcast = clean(item.podcastTitle)
  var label = (title + (podcast ? " · " + podcast : ""))
    .replace(playbackWhitespace, " ")
    .replace(/^ +| +$/g, "")
  // Cap by Unicode code point, like Python's str slice, so an emoji at the
  // boundary is never split in half (JS slice would cut a surrogate pair).
  var points = Array.from(label)
  if (points.length > playbackTitleLimit) label = points.slice(0, playbackTitleLimit).join("")
  return label || "Dhwani"
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
    var audioUrl = clean(item.audioUrl)
    if (!isPlayableAudioUrl(audioUrl)) return null
    return {
      kind: "episode",
      episodeId: clean(item.episodeId || item.episode_id || item.video_id),
      podcastId: clean(item.podcastId || item.podcast_id),
      title: clean(item.title),
      podcastTitle: clean(item.podcastTitle || item.podcast_title) || "Podcast",
      artworkUrl: /^https?:\/\//i.test(clean(item.artworkUrl || item.artwork_url)) ? clean(item.artworkUrl || item.artwork_url) : "",
      audioUrl: audioUrl,
      duration: Math.max(0, parseInt(item.duration, 10) || 0),
      position: Math.max(0, Number(item.position) || 0),
    }
  }
  return episode(item)
}

function resumeEpisode(queue, item) {
  var incoming = coerceEpisode(item)
  if (!incoming) return null
  var source = Array.isArray(queue) ? queue : []
  for (var i = 0; i < source.length; i++) {
    if (episodeKey(source[i]) !== episodeKey(incoming)) continue
    incoming.position = Math.max(0, Number(source[i].position) || 0)
    break
  }
  return incoming
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

function mergeEpisodes(existing, incoming) {
  var next = Array.isArray(existing) ? existing.slice() : []
  var seen = {}
  for (var i = 0; i < next.length; i++) seen[episodeKey(next[i])] = true
  var extra = Array.isArray(incoming) ? incoming : []
  for (var j = 0; j < extra.length; j++) {
    var item = extra[j]
    var key = episodeKey(item)
    if (!key || seen[key]) continue
    seen[key] = true
    next.push(item)
  }
  return next
}

function mergeShows(existing, incoming) {
  var next = Array.isArray(existing) ? existing.slice() : []
  var seen = {}
  for (var i = 0; i < next.length; i++) seen[next[i] && next[i].podcastId] = true
  var extra = Array.isArray(incoming) ? incoming : []
  for (var j = 0; j < extra.length; j++) {
    var show = extra[j]
    if (!show || !show.podcastId || seen[show.podcastId]) continue
    seen[show.podcastId] = true
    next.push(show)
  }
  return next
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

function scheduleFetch(pending, kind, url, token) {
  if (!kind || !url) return Array.isArray(pending) ? pending.slice() : []
  var source = Array.isArray(pending) ? pending : []
  var next = []
  var dropMore = kind === "shows" ? "moreShows" : (kind === "show" ? "moreShow" : (kind === "search" ? "moreSearch" : ""))
  var replaced = false
  for (var i = 0; i < source.length; i++) {
    var job = source[i]
    if (!job) continue
    if (dropMore && job.kind === dropMore) continue
    if (job.kind === kind) {
      next.push({ kind: kind, url: url, token: token })
      replaced = true
    } else next.push(job)
  }
  if (!replaced) next.push({ kind: kind, url: url, token: token })
  return next
}

function dropFetches(pending, kinds) {
  var source = Array.isArray(pending) ? pending : []
  var drop = Array.isArray(kinds) ? kinds : [kinds]
  var next = []
  for (var i = 0; i < source.length; i++) {
    if (source[i] && drop.indexOf(source[i].kind) === -1) next.push(source[i])
  }
  return next
}

function takeFetch(pending) {
  var source = Array.isArray(pending) ? pending : []
  if (!source.length) return { job: null, rest: [] }
  var index = 0
  for (var i = 0; i < source.length; i++) {
    // Speculative artwork lookups wait behind everything the user asked for.
    if (source[i] && String(source[i].kind).indexOf("artwork:") !== 0) { index = i; break }
  }
  return { job: source[index], rest: source.slice(0, index).concat(source.slice(index + 1)) }
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
    isPlayableAudioUrl: isPlayableAudioUrl,
    isYouTubeUrl: isYouTubeUrl,
    isAudioOption: isAudioOption,
    titleSearchUrl: titleSearchUrl,
    searchKey: searchKey,
    playbackTitle: playbackTitle,
    parseFeed: parseFeed,
    parseTrending: parseTrending,
    parsePodcasts: parsePodcasts,
    parseShow: parseShow,
    parseTitleSearch: parseTitleSearch,
    formatDuration: formatDuration,
    formatPosition: formatPosition,
    playbackProgress: playbackProgress,
    episodeKey: episodeKey,
    enqueue: enqueue,
    resumeEpisode: resumeEpisode,
    mergeEpisodes: mergeEpisodes,
    mergeShows: mergeShows,
    mergeQueue: mergeQueue,
    rememberPosition: rememberPosition,
    scheduleFetch: scheduleFetch,
    dropFetches: dropFetches,
    takeFetch: takeFetch,
    isFresh: isFresh,
    parseState: parseState,
    emptyState: emptyState,
    coerceEpisode: coerceEpisode,
    pageSize: pageSize,
  }
}
