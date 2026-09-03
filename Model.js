function clean(value) {
  return String(value === undefined || value === null ? "" : value).replace(/^\s+|\s+$/g, "")
}

function normalizeBaseUrl(value) {
  var url = clean(value).replace(/\/+$/, "")
  return /^https?:\/\/[^\s]+$/i.test(url) ? url : ""
}

function feedUrl(baseUrl) {
  var base = normalizeBaseUrl(baseUrl)
  return base ? base + "/v1/foryou/all" : ""
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

function candidates(payload) {
  var result = []
  if (payload && payload.daily_listen) result.push(payload.daily_listen)
  var groups = [payload && payload.picks, payload && payload.trending]
  for (var i = 0; i < groups.length; i++) {
    var group = groups[i]
    if (!Array.isArray(group)) continue
    for (var j = 0; j < group.length; j++) result.push(group[j])
  }
  var categories = payload && payload.categories
  if (categories && typeof categories === "object") {
    var names = Object.keys(categories).sort()
    for (var n = 0; n < names.length; n++) {
      var items = categories[names[n]]
      if (!Array.isArray(items)) continue
      for (var m = 0; m < items.length; m++) result.push(items[m])
    }
  }
  return result
}

function episode(item) {
  if (!item || typeof item !== "object") return null
  var audioUrl = playableUrl(item.media_options)
  var title = clean(item.title)
  if (!audioUrl || !title) return null
  return {
    episodeId: clean(item.episode_id || item.video_id),
    podcastId: clean(item.podcast_id),
    title: title,
    podcastTitle: clean(item.podcast_title) || "Podcast",
    artworkUrl: /^https?:\/\//i.test(clean(item.artwork_url)) ? clean(item.artwork_url) : "",
    audioUrl: audioUrl,
    duration: Math.max(0, parseInt(item.duration, 10) || 0)
  }
}

function playbackTitle(item) {
  if (!item) return ""
  var title = clean(item.title)
  var podcast = clean(item.podcastTitle)
  return title + (podcast ? " · " + podcast : "")
}

function parseFeed(raw, limit) {
  var payload
  try {
    payload = JSON.parse(String(raw || ""))
  } catch (e) {
    return { ok: false, error: "Dhwani returned unreadable data", episodes: [] }
  }
  if (!payload || typeof payload !== "object" || Array.isArray(payload))
    return { ok: false, error: "Dhwani returned no feed", episodes: [] }
  if (payload.detail) {
    var detail = typeof payload.detail === "string" ? clean(payload.detail) : ""
    return { ok: false, error: detail || "Dhwani request failed", episodes: [] }
  }

  var cap = Math.max(1, parseInt(limit, 10) || 7)
  var seen = {}
  var episodes = []
  var source = candidates(payload)
  for (var i = 0; i < source.length && episodes.length < cap; i++) {
    var normalized = episode(source[i])
    if (!normalized) continue
    var key = normalized.episodeId || normalized.audioUrl
    if (seen[key]) continue
    seen[key] = true
    episodes.push(normalized)
  }
  return { ok: true, error: "", episodes: episodes, generatedAt: clean(payload.generated_at) }
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

if (typeof module !== "undefined") {
  module.exports = {
    normalizeBaseUrl: normalizeBaseUrl,
    feedUrl: feedUrl,
    playableUrl: playableUrl,
    playbackTitle: playbackTitle,
    parseFeed: parseFeed,
    formatDuration: formatDuration,
    formatPosition: formatPosition,
    playbackProgress: playbackProgress
  }
}
