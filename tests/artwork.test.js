const assert = require('assert');
const Model = require('../Model.js');
const { qmlFunctions } = require('./qml-vm');

const SERVICE = require.resolve('../Service.qml');
let now = 1000000;
let saves = 0;
const service = qmlFunctions(
  SERVICE,
  ['showRecord', 'putShow', 'artworkFor', 'ensureArtwork', 'applyNetwork', 'dumpState'],
  {
    Model, Date: { now: () => now }, apiBase: 'https://api.example.test', staleAfterMs: 600000,
    shows: [], showsById: {}, artworkRequested: {}, fetchQueue: [], pendingKind: '', errorText: '',
    queue: [], trending: [], trendingAt: 0, showsAt: 0, showsTotal: 0, showsNextOffset: 0,
    request(kind, url) { service.fetchQueue = Model.scheduleFetch(service.fetchQueue, kind, url); },
    saveSoon() { saves++; },
  }
);
const founders = { kind: 'episode', podcastId: 'BgvRZTg8v9GYMpbxcvFk', artworkUrl: '' };
const lex = { kind: 'episode', podcastId: 'XgosndFz4gzOM4oHrfYI', artworkUrl: '' };
const ownArtwork = { ...founders, artworkUrl: 'https://example.test/episode.png' };

// A cold feed requests once per show, without collapsing different shows into one job.
service.ensureArtwork([founders, { ...founders }, lex, ownArtwork]);
assert.strictEqual(service.fetchQueue.length, 2);
assert.ok(service.fetchQueue.every(job => job.url.endsWith('?limit=1&offset=0')));
assert.ok(Model.showUrl(service.apiBase, founders.podcastId, 0).endsWith('?limit=20&offset=0'));
assert.deepStrictEqual(service.fetchQueue.map(job => job.kind), [
  `artwork:${founders.podcastId}`, `artwork:${lex.podcastId}`,
]);
service.ensureArtwork([founders, lex]);
assert.strictEqual(service.fetchQueue.length, 2);
assert.strictEqual(service.artworkFor(ownArtwork), ownArtwork.artworkUrl);

// Hydrate show artwork without overwriting already-paginated episode data.
const pages = [{ episodeId: 'kept', title: 'Already loaded' }];
service.showsById[founders.podcastId] = { episodes: pages, total: 80, fetchedAt: 42 };
service.pendingKind = `artwork:${founders.podcastId}`;
service.applyNetwork(JSON.stringify({
  podcast: { podcast_id: founders.podcastId, title: 'Founders', artwork_url: 'https://example.test/show.png' },
  episodes: [], total_episodes: 80,
}));
assert.strictEqual(service.artworkFor(founders), 'https://example.test/show.png');
assert.strictEqual(founders.artworkUrl, '', 'Do not rewrite episode artwork');
assert.strictEqual(service.artworkFor(ownArtwork), ownArtwork.artworkUrl);
assert.strictEqual(service.showsById[founders.podcastId].episodes, pages);
assert.strictEqual(service.showsById[founders.podcastId].total, 80);
assert.strictEqual(service.showsById[founders.podcastId].fetchedAt, 42);
assert.strictEqual(saves, 1);

// Artwork uses the existing persisted show cache and the already-loaded show list.
const restored = Model.parseState(service.dumpState());
service.showsById = restored.cache.showsById;
service.artworkRequested = {};
service.fetchQueue = [];
service.ensureArtwork([founders]);
assert.strictEqual(service.fetchQueue.length, 0);
service.shows = [{ podcastId: lex.podcastId, artworkUrl: 'https://example.test/lex.png' }];
service.ensureArtwork([lex]);
assert.strictEqual(service.artworkFor(lex), 'https://example.test/lex.png');
assert.strictEqual(service.fetchQueue.length, 0);

// Failed/missing-artwork attempts are not repeated every render; retry after the cache TTL.
service.shows = [];
service.ensureArtwork([lex]);
service.fetchQueue = [];
service.ensureArtwork([lex]);
assert.strictEqual(service.fetchQueue.length, 0);
now += service.staleAfterMs + 1;
service.ensureArtwork([lex]);
assert.strictEqual(service.fetchQueue.length, 1);
service.fetchQueue = [];
service.ensureArtwork([{ ...lex, podcastId: '../invalid' }, { ...lex, kind: 'show' }]);
assert.strictEqual(service.fetchQueue.length, 0);

// A cold artwork lookup must discard the endpoint's incidental episode page.
service.showsById = {};
service.pendingKind = `artwork:${founders.podcastId}`;
service.applyNetwork(JSON.stringify({
  podcast: { podcast_id: founders.podcastId, title: 'Founders', artwork_url: 'https://example.test/show.png' },
  episodes: [{ episode_id: 'abcdefghij', title: 'Incidental episode',
    media_options: [{ path: 'https://example.test/audio.mp3', source_type: 'RSS' }] }],
  total_episodes: 80,
}));
assert.strictEqual(service.artworkFor(founders), 'https://example.test/show.png');
assert.strictEqual(service.showsById[founders.podcastId].episodes.length, 0);
assert.strictEqual(service.showsById[founders.podcastId].total, 0);
assert.strictEqual(service.showsById[founders.podcastId].fetchedAt, 0);

console.log('Artwork resolution tests passed (service JavaScript, not live QML)');
