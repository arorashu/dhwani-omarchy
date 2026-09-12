const assert = require('assert');
const Model = require('../Model.js');
const { qmlFunctions } = require('./qml-vm');

// Search orchestration in Service.qml: generation-stamped responses, immediate
// result invalidation, raw offsets, debounce, failure retryability, and obsolete-job
// cleanup. This runs the extracted QML JavaScript in a VM with the properties the
// functions touch; it is not a live QML test.

const SERVICE = require.resolve('../Service.qml');

function makeContext() {
  const context = {
    Model,
    Date: { now: () => 1000000 },
    apiBase: 'https://api.example.test',
    staleAfterMs: 600000,
    episodeLimit: 10,
    searchQuery: '',
    searchKind: 'episodes',
    searchPodcastId: '',
    searchEpisodes: [],
    searchShows: [],
    searchTotal: 0,
    searchNextOffset: 0,
    searchRequestedOffset: -1,
    searchLoading: false,
    searchError: '',
    searchGeneration: 0,
    pendingGeneration: -1,
    pendingKind: '',
    fetchQueue: [],
    queue: [],
    queuedId: '',
    stateReady: false,
    shows: [],
    showsById: {},
    showsTotal: 0,
    showsNextOffset: 0,
    showsAt: 0,
    trending: [],
    trendingAt: 0,
    errorText: '',
    timerRestarts: 0,
    timerStops: 0,
    searchTimer: {
      restart() { context.timerRestarts++; },
      stop() { context.timerStops++; },
    },
    request(kind, url, token) {
      context.fetchQueue = Model.scheduleFetch(context.fetchQueue, kind, url, token);
    },
    saveSoon() {},
    saveState() {},
  };
  const names = [
    'beginSearch', 'applyNetworkFailure', 'runSearch', 'pageSearch', 'clearSearch', 'applyNetwork',
    'pageShows', 'pageShow', 'showRecord', 'putShow', 'showNextOffset', 'applyState', 'dumpState',
  ];
  qmlFunctions(SERVICE, names, context);
  return context;
}

const episode = (id, title) => ({
  video_id: id,
  title,
  podcast_id: '9QqWbjH5mqlrsiaHMba1',
  podcast_title: 'Show',
  media_options: [{ source_type: 'RSS', path: `https://cdn.example.test/${id}.mp3` }],
});

function searchResponse(kind, query, offset, total) {
  return JSON.stringify({
    query,
    kind,
    limit: 20,
    offset,
    total,
    episodes: kind === 'episodes' ? [episode(`${query}${offset}`, `${query} ${offset}`)] : [],
    podcasts: kind === 'shows' ? [{ podcast_id: '9QqWbjH5mqlrsiaHMba1', title: query, episode_count: 5 }] : [],
  });
}

// Intent changes bump the generation, clear visible rows, mark pending, and drop obsolete jobs.
const c = makeContext();
c.searchEpisodes = [episode('old', 'old result')];
c.fetchQueue = Model.scheduleFetch([], 'search', 'https://api.example.test/old', 0);
c.fetchQueue = Model.scheduleFetch(c.fetchQueue, 'moreSearch', 'https://api.example.test/oldpage', 0);
c.beginSearch('episodes', '  a  ', '');
assert.strictEqual(c.searchGeneration, 1);
assert.strictEqual(c.searchQuery, 'a', 'queries are trimmed');
assert.strictEqual(c.searchEpisodes.length, 0, 'old rows are invalidated immediately');
assert.strictEqual(c.searchTotal, 0);
assert.strictEqual(c.searchNextOffset, 0);
assert.strictEqual(c.searchLoading, true, 'pending state is immediate, not debounced');
assert.strictEqual(c.fetchQueue.length, 0, 'obsolete queued searches are dropped on intent change');
assert.strictEqual(c.timerRestarts, 1);
c.beginSearch('episodes', 'ab', '');
assert.strictEqual(c.searchGeneration, 2);
assert.strictEqual(c.timerRestarts, 2);
assert.strictEqual(c.fetchQueue.length, 0, 'typing must not issue a request per keystroke');

// Whitespace-only input clears cleanly.
c.beginSearch('episodes', '   ', '');
assert.strictEqual(c.searchQuery, '');
assert.strictEqual(c.searchLoading, false);
assert.strictEqual(c.searchEpisodes.length, 0);
assert.strictEqual(c.searchTotal, 0);

// runSearch stamps the queued job with the current generation and starts at offset 0.
c.beginSearch('episodes', 'ab', '');
c.runSearch();
assert.strictEqual(c.fetchQueue.length, 1);
assert.strictEqual(c.fetchQueue[0].kind, 'search');
assert.strictEqual(c.fetchQueue[0].token, c.searchGeneration);
assert.ok(c.fetchQueue[0].url.includes('offset=0'));
assert.ok(c.fetchQueue[0].url.includes('kind=episodes'));

// Apply page 0 for the current generation.
c.pendingKind = 'search';
c.pendingGeneration = c.searchGeneration;
c.applyNetwork(searchResponse('episodes', 'ab', 0, 41));
assert.strictEqual(c.searchEpisodes.length, 1);
assert.strictEqual(c.searchTotal, 41);
assert.strictEqual(c.searchNextOffset, 20);
assert.strictEqual(c.searchLoading, false);

// A -> B -> A: a later page stamped with the first A generation must not land.
c.beginSearch('episodes', 'b', '');
c.beginSearch('episodes', 'ab', '');
const genA2 = c.searchGeneration;
const staleGen = genA2 - 1;
const before = c.searchEpisodes;
c.pendingKind = 'moreSearch';
c.pendingGeneration = staleGen;
c.applyNetwork(searchResponse('episodes', 'b', 20, 99));
assert.strictEqual(c.searchEpisodes, before, 'stale later page for the first A is discarded');
assert.strictEqual(c.searchNextOffset, 0, 'stale response cannot advance the fresh search');
assert.strictEqual(c.searchLoading, true);

// The fresh generation applies page 0 and then a later page.
c.pendingGeneration = genA2;
c.applyNetwork(searchResponse('episodes', 'ab', 0, 41));
assert.strictEqual(c.searchEpisodes.length, 1);
assert.strictEqual(c.searchNextOffset, 20);
c.pendingKind = 'moreSearch';
c.applyNetwork(searchResponse('episodes', 'ab', 20, 41));
assert.strictEqual(c.searchEpisodes.length, 2);
assert.strictEqual(c.searchNextOffset, 40);

// A stale oversized/error payload is rejected before it can touch current state.
c.searchError = '';
c.pendingKind = 'search';
c.pendingGeneration = staleGen;
c.applyNetwork('x'.repeat(1048577));
assert.strictEqual(c.searchError, '', 'stale failure must not set the current search error');
assert.strictEqual(c.searchLoading, false, 'stale failure must not change loading state');
assert.strictEqual(c.searchEpisodes.length, 2);

// A matching-generation parse failure is retryable: the requested offset resets.
c.pendingGeneration = genA2;
c.applyNetwork('{');
assert.strictEqual(c.searchError !== '', true);
assert.strictEqual(c.searchLoading, false);
assert.strictEqual(c.searchRequestedOffset, -1);

// A matching-generation network failure is also retryable.
c.searchError = '';
c.applyNetworkFailure('moreSearch', genA2, 'Dhwani is out of reach');
assert.strictEqual(c.searchError, 'Dhwani is out of reach');
assert.strictEqual(c.searchLoading, false);
assert.strictEqual(c.searchRequestedOffset, -1);
// A stale network failure is ignored.
c.searchError = 'keep';
c.applyNetworkFailure('search', staleGen, 'stale failure');
assert.strictEqual(c.searchError, 'keep');
c.applyNetworkFailure('trending', -1, 'browse failure');
assert.strictEqual(c.errorText, 'browse failure');

// An empty/invalid apiBase must fail the pending debounce instead of leaving the
// permanent "Searching…" spinner up (finding 1b).
const noBase = makeContext();
noBase.apiBase = '';
noBase.beginSearch('episodes', 'alpha', '');
assert.strictEqual(noBase.searchLoading, true, 'the debounce marks pending immediately');
noBase.runSearch();
assert.strictEqual(noBase.searchLoading, false, 'an unusable base must not stay loading');
assert.strictEqual(noBase.searchRequestedOffset, -1);
assert.ok(noBase.searchError !== '', 'the failure is visible to the user');
assert.strictEqual(noBase.fetchQueue.length, 0);

// The exact finding-1 repro no longer throws and issues a request.
const astral = makeContext();
astral.beginSearch('episodes', 'a'.repeat(99) + '🙂', '');
astral.runSearch();
assert.strictEqual(astral.searchLoading, true);
assert.strictEqual(astral.fetchQueue.length, 1);
assert.ok(decodeURIComponent(astral.fetchQueue[0].url.split('q=')[1].split('&')[0]).endsWith('🙂'));

// A query that still cannot be encoded (a lone surrogate) fails retryably rather
// than aborting the timer handler with searchLoading left true.
const unencodable = makeContext();
unencodable.searchQuery = 'a'.repeat(99) + '\uD83D';
unencodable.searchLoading = true;
unencodable.runSearch();
assert.strictEqual(unencodable.searchLoading, false);
assert.strictEqual(unencodable.searchRequestedOffset, -1);
assert.ok(unencodable.searchError !== '');
assert.strictEqual(unencodable.fetchQueue.length, 0);

// pageSearch has the same failure class: it must not stay loading if the next
// page URL cannot be built.
const badPage = makeContext();
badPage.beginSearch('episodes', 'alpha', '');
badPage.searchTotal = 41;
badPage.searchNextOffset = 20;
badPage.searchLoading = false;
badPage.searchQuery = 'a'.repeat(99) + '\uD83D';
badPage.pageSearch();
assert.strictEqual(badPage.searchLoading, false);
assert.strictEqual(badPage.searchRequestedOffset, -1);
assert.ok(badPage.searchError !== '');
assert.strictEqual(badPage.fetchQueue.length, 0);

// Pagination uses the server next offset, is not re-requested while loading, stops at total.
c.searchLoading = false;
c.searchRequestedOffset = -1;
c.fetchQueue = [];
c.pageSearch();
assert.strictEqual(c.fetchQueue.length, 1);
assert.ok(c.fetchQueue[0].url.includes('offset=40'));
assert.strictEqual(c.searchLoading, true);
assert.strictEqual(c.searchRequestedOffset, 40);
c.pageSearch();
assert.strictEqual(c.fetchQueue.length, 1, 'duplicate page requests are suppressed while loading');
c.searchLoading = false;
c.searchNextOffset = 41;
c.pageSearch();
assert.strictEqual(c.fetchQueue.length, 1, 'no request past the total');

// clearSearch resets state, bumps the generation, and drops obsolete queued jobs.
c.fetchQueue = Model.scheduleFetch(c.fetchQueue, 'search', 'https://api.example.test/s', genA2);
c.fetchQueue = Model.scheduleFetch(c.fetchQueue, 'moreSearch', 'https://api.example.test/m', genA2);
const beforeClear = c.searchGeneration;
c.clearSearch();
assert.strictEqual(c.fetchQueue.length, 0);
assert.strictEqual(c.searchTotal, 0);
assert.strictEqual(c.searchNextOffset, 0);
assert.strictEqual(c.searchLoading, false);
assert.strictEqual(c.searchGeneration, beforeClear + 1);

// Scope is carried into episode URLs and ignored for shows.
c.beginSearch('episodes', 'ab', '9QqWbjH5mqlrsiaHMba1');
assert.ok(Model.titleSearchUrl(c.apiBase, 'episodes', 'ab', 0, c.searchPodcastId).includes('podcast_id=9QqWbjH5mqlrsiaHMba1'));
c.beginSearch('shows', 'ab', '9QqWbjH5mqlrsiaHMba1');
assert.strictEqual(c.searchPodcastId, '', 'shows drop the episode scope');
c.runSearch();
assert.strictEqual(c.fetchQueue[c.fetchQueue.length - 1].token, c.searchGeneration);
assert.ok(c.fetchQueue[c.fetchQueue.length - 1].url.includes('kind=shows'));
assert.ok(!c.fetchQueue[c.fetchQueue.length - 1].url.includes('podcast_id'));

// Show/episode pagination uses raw server offsets, never rendered row counts.
const showsContext = makeContext();
showsContext.shows = [{ kind: 'show', podcastId: '9QqWbjH5mqlrsiaHMba1' }];
showsContext.showsTotal = 80;
showsContext.showsNextOffset = 20;
showsContext.pageShows();
assert.strictEqual(showsContext.fetchQueue.length, 1);
assert.ok(showsContext.fetchQueue[0].url.endsWith('offset=20'));
showsContext.fetchQueue = [];
showsContext.showsNextOffset = 80;
showsContext.pageShows();
assert.strictEqual(showsContext.fetchQueue.length, 0);

const showContext = makeContext();
showContext.showsById = { '9QqWbjH5mqlrsiaHMba1': { episodes: [episode('x', 'One')], total: 80, nextOffset: 20 } };
showContext.pageShow('9QqWbjH5mqlrsiaHMba1');
assert.strictEqual(showContext.fetchQueue.length, 1);
assert.ok(showContext.fetchQueue[0].url.endsWith('offset=20'), 'raw offset, not the one rendered row');
showContext.fetchQueue = [];
showContext.showsById = { '9QqWbjH5mqlrsiaHMba1': { episodes: [episode('x', 'One')], total: 1, nextOffset: 1 } };
showContext.pageShow('9QqWbjH5mqlrsiaHMba1');
assert.strictEqual(showContext.fetchQueue.length, 0);
// Records persisted before nextOffset existed fall back to the loaded length.
assert.strictEqual(showContext.showNextOffset(showContext.showsById['9QqWbjH5mqlrsiaHMba1']), 1);

// Hydration (Service.applyState): persisted YouTube rows never reach Trending or a
// show's episode list, raw offsets survive the restart, and original metadata is kept.
const SHOW_ID = '9QqWbjH5mqlrsiaHMba1';
const cachedRss = {
  kind: 'episode', episodeId: 'cached-rss', podcastId: SHOW_ID, title: 'Cached RSS',
  podcastTitle: 'Founders', artworkUrl: 'https://img.example.test/f.png',
  audioUrl: 'https://cdn.example.test/cached.mp3', duration: 600, position: 12,
  publication_date: '2025-01-02T03:04:05+00:00',
};
const cachedYoutube = {
  kind: 'episode', episodeId: 'cached-yt', podcastId: SHOW_ID, title: 'Cached YouTube',
  podcastTitle: 'Founders', audioUrl: 'https://www.youtube.com/watch?v=abc', position: 4,
};
const persistedShow = {
  kind: 'show', podcastId: SHOW_ID, title: 'Founders',
  artworkUrl: 'https://img.example.test/f.png', episodeCount: 88,
};

function persistedState(cache) {
  return JSON.stringify({ schemaVersion: 1, queue: [], nav: {}, cache });
}

const hydrated = makeContext();
hydrated.applyState(persistedState({
  trending: { fetchedAt: 111, episodes: [cachedRss, cachedYoutube] },
  shows: { fetchedAt: 222, items: [persistedShow], total: 88, nextOffset: 20 },
  showsById: {
    [SHOW_ID]: {
      title: 'Founders', artworkUrl: 'https://img.example.test/f.png', fetchedAt: 333,
      total: 88, nextOffset: 20, episodes: [cachedYoutube, cachedRss],
    },
  },
}), false);
assert.strictEqual(hydrated.trending.length, 1, 'YouTube trending rows are dropped on hydration');
assert.strictEqual(hydrated.trending[0].episodeId, 'cached-rss');
assert.strictEqual(hydrated.trending[0].position, 12);
assert.strictEqual(hydrated.trending[0].duration, 600);
assert.strictEqual(hydrated.trending[0].publication_date, '2025-01-02T03:04:05+00:00', 'hydration must not re-normalize valid rows away');
assert.strictEqual(hydrated.trendingAt, 111);
const hydratedRecord = hydrated.showsById[SHOW_ID];
assert.strictEqual(hydratedRecord.episodes.length, 1, 'YouTube show rows are dropped on hydration');
assert.strictEqual(hydratedRecord.episodes[0].episodeId, 'cached-rss');
assert.strictEqual(hydratedRecord.episodes[0].publication_date, '2025-01-02T03:04:05+00:00');
assert.strictEqual(hydratedRecord.nextOffset, 20, 'raw show offset is preserved even though a row was dropped');
assert.strictEqual(hydratedRecord.total, 88);
assert.strictEqual(hydratedRecord.artworkUrl, 'https://img.example.test/f.png');
assert.strictEqual(hydratedRecord.title, 'Founders');
assert.strictEqual(hydratedRecord.fetchedAt, 333);
assert.strictEqual(hydrated.showsNextOffset, 20, 'All Shows pagination offset is restored from disk');
assert.strictEqual(hydrated.showsTotal, 88);
assert.strictEqual(hydrated.showsAt, 222);
assert.deepStrictEqual(hydrated.shows[0], persistedShow);

// dumpState roundtrip: the restored offset is written back and re-read.
const dumped = JSON.parse(hydrated.dumpState());
assert.strictEqual(dumped.cache.shows.nextOffset, 20);
assert.strictEqual(dumped.cache.showsById[SHOW_ID].nextOffset, 20);
const roundtrip = makeContext();
roundtrip.applyState(hydrated.dumpState(), false);
assert.strictEqual(roundtrip.showsNextOffset, 20, 'a real dump/apply roundtrip keeps pagination working');
assert.strictEqual(roundtrip.showsById[SHOW_ID].nextOffset, 20);
assert.strictEqual(roundtrip.showsById[SHOW_ID].episodes.length, 1);
roundtrip.fetchQueue = [];
roundtrip.pageShows();
assert.strictEqual(roundtrip.fetchQueue.length, 1, 'pageShows can advance after a restart');
assert.ok(roundtrip.fetchQueue[0].url.endsWith('offset=20'), 'pageShows uses the raw stored offset');
roundtrip.fetchQueue = [];
roundtrip.pageShow(SHOW_ID);
assert.strictEqual(roundtrip.fetchQueue.length, 1, 'pageShow can advance after a restart');
assert.ok(roundtrip.fetchQueue[0].url.endsWith('offset=20'));

// An all-excluded persisted page keeps its stored offset for the next page request.
const allExcluded = makeContext();
allExcluded.applyState(persistedState({
  showsById: { [SHOW_ID]: { title: 'Founders', total: 40, nextOffset: 20, episodes: [cachedYoutube] } },
}), false);
assert.strictEqual(allExcluded.showsById[SHOW_ID].episodes.length, 0);
assert.strictEqual(allExcluded.showsById[SHOW_ID].nextOffset, 20, 'a stored offset outlives a fully-filtered page');

// Legacy persisted records have no nextOffset: infer the original count before filtering.
const legacy = makeContext();
legacy.applyState(persistedState({
  shows: { fetchedAt: 5, items: [persistedShow], total: 88 },
  showsById: { [SHOW_ID]: { title: 'Founders', total: 88, episodes: [cachedRss, cachedYoutube] } },
}), false);
assert.strictEqual(legacy.showsNextOffset, 1, 'legacy All Shows uses the stored show count');
assert.strictEqual(legacy.showsById[SHOW_ID].nextOffset, 2, 'legacy show count is taken before filtering');
assert.strictEqual(legacy.showsById[SHOW_ID].episodes.length, 1);
assert.strictEqual(legacy.showsById[SHOW_ID].total, 88);

console.log('Search orchestration tests passed (extracted JavaScript, not a live QML test)');
