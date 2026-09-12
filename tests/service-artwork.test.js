const { test } = require('node:test');
const assert = require('node:assert');
const Model = require('../Model.js');
const { qmlFunctions } = require('./qml-source-harness');

const SERVICE = require.resolve('../Service.qml');

// Service artwork lookup/cache orchestration: which shows get a speculative
// lookup, how results are cached and reused, and that hydration never overwrites
// episode data. The real Service.qml JavaScript runs with a mocked API/state;
// this is not rendering and not live QML.

function makeService() {
  const env = { now: 1000000, saves: 0 };
  const service = qmlFunctions(
    SERVICE,
    ['showRecord', 'putShow', 'artworkFor', 'ensureArtwork', 'applyNetwork', 'dumpState'],
    {
      Model,
      Date: { now: () => env.now },
      apiBase: 'https://api.example.test',
      staleAfterMs: 600000,
      shows: [], showsById: {}, artworkRequested: {}, fetchQueue: [], pendingKind: '', errorText: '',
      queue: [], trending: [], trendingAt: 0, showsAt: 0, showsTotal: 0, showsNextOffset: 0,
      request(kind, url) { service.fetchQueue = Model.scheduleFetch(service.fetchQueue, kind, url); },
      saveSoon() { env.saves++; },
    }
  );
  return { service, env };
}

const FOUNDERS_ID = 'BgvRZTg8v9GYMpbxcvFk';
const LEX_ID = 'XgosndFz4gzOM4oHrfYI';
const founders = () => ({ kind: 'episode', podcastId: FOUNDERS_ID, artworkUrl: '' });
const lex = () => ({ kind: 'episode', podcastId: LEX_ID, artworkUrl: '' });
const showDetail = (podcastId, artworkUrl, episodes) => JSON.stringify({
  podcast: { podcast_id: podcastId, title: 'Founders', artwork_url: artworkUrl },
  episodes: episodes || [],
  total_episodes: 80,
});

test('a cold feed queues one artwork lookup per distinct show', () => {
  const { service } = makeService();
  const ownArtwork = { ...founders(), artworkUrl: 'https://example.test/episode.png' };

  service.ensureArtwork([founders(), { ...founders() }, lex(), ownArtwork]);
  assert.strictEqual(service.fetchQueue.length, 2);
  assert.ok(service.fetchQueue.every(job => job.url.endsWith('?limit=1&offset=0')));
  assert.ok(Model.showUrl(service.apiBase, FOUNDERS_ID, 0).endsWith('?limit=20&offset=0'));
  assert.deepStrictEqual(service.fetchQueue.map(job => job.kind), [
    `artwork:${FOUNDERS_ID}`, `artwork:${LEX_ID}`,
  ]);

  service.ensureArtwork([founders(), lex()]);
  assert.strictEqual(service.fetchQueue.length, 2, 'an already-queued lookup is not queued twice');
  assert.strictEqual(service.artworkFor(ownArtwork), ownArtwork.artworkUrl, 'episode artwork is used as-is');
});

test('artwork hydration fills the show without overwriting paginated episode data', () => {
  const { service, env } = makeService();
  const pages = [{ episodeId: 'kept', title: 'Already loaded' }];
  const foundersRow = founders();
  service.showsById[FOUNDERS_ID] = { episodes: pages, total: 80, fetchedAt: 42 };
  service.pendingKind = `artwork:${FOUNDERS_ID}`;

  service.applyNetwork(showDetail(FOUNDERS_ID, 'https://example.test/show.png'));

  assert.strictEqual(service.artworkFor(foundersRow), 'https://example.test/show.png');
  assert.strictEqual(foundersRow.artworkUrl, '', 'do not rewrite episode artwork');
  assert.strictEqual(service.showsById[FOUNDERS_ID].episodes, pages);
  assert.strictEqual(service.showsById[FOUNDERS_ID].total, 80);
  assert.strictEqual(service.showsById[FOUNDERS_ID].fetchedAt, 42);
  assert.strictEqual(env.saves, 1);
});

test('an artwork hit is reused through the persisted show cache', () => {
  const { service } = makeService();
  service.showsById[FOUNDERS_ID] = {
    title: 'Founders', artworkUrl: 'https://example.test/show.png',
    episodes: [], total: 0, nextOffset: 0, fetchedAt: 1,
  };
  const restored = Model.parseState(service.dumpState());
  service.showsById = restored.cache.showsById;
  service.artworkRequested = {};
  service.fetchQueue = [];

  service.ensureArtwork([founders()]);
  assert.strictEqual(service.artworkFor(founders()), 'https://example.test/show.png');
  assert.strictEqual(service.fetchQueue.length, 0, 'persisted artwork needs no new request');
});

test('an artwork hit is reused from the already-loaded show list', () => {
  const { service } = makeService();
  service.shows = [{ podcastId: LEX_ID, artworkUrl: 'https://example.test/lex.png' }];

  service.ensureArtwork([lex()]);
  assert.strictEqual(service.artworkFor(lex()), 'https://example.test/lex.png');
  assert.strictEqual(service.fetchQueue.length, 0, 'the loaded show list needs no new request');
});

test('a missing artwork lookup is not retried until the cache TTL expires', () => {
  const { service, env } = makeService();
  service.ensureArtwork([lex()]);
  assert.strictEqual(service.fetchQueue.length, 1);

  service.fetchQueue = [];
  service.ensureArtwork([lex()]);
  assert.strictEqual(service.fetchQueue.length, 0, 'a remembered miss is not retried every render');

  env.now += service.staleAfterMs + 1;
  service.ensureArtwork([lex()]);
  assert.strictEqual(service.fetchQueue.length, 1, 'the miss is retried after the TTL');
});

test('invalid show ids and show rows are left to their own loaders', () => {
  const { service } = makeService();
  service.ensureArtwork([{ ...lex(), podcastId: '../invalid' }, { ...lex(), kind: 'show' }]);
  assert.strictEqual(service.fetchQueue.length, 0);
});

test('a cold artwork lookup discards the endpoint incidental episode page', () => {
  const { service } = makeService();
  service.pendingKind = `artwork:${FOUNDERS_ID}`;

  service.applyNetwork(showDetail(FOUNDERS_ID, 'https://example.test/show.png', [{
    episode_id: 'abcdefghij',
    title: 'Incidental episode',
    media_options: [{ path: 'https://example.test/audio.mp3', source_type: 'RSS' }],
  }]));

  const record = service.showsById[FOUNDERS_ID];
  assert.strictEqual(service.artworkFor(founders()), 'https://example.test/show.png');
  assert.strictEqual(record.episodes.length, 0);
  assert.strictEqual(record.total, 0);
  assert.strictEqual(record.fetchedAt, 0);
});
