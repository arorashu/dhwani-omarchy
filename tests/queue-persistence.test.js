const { test } = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');
const Model = require('../Model.js');

const fixtures = path.join(__dirname, 'fixtures');
const read = (name) => fs.readFileSync(path.join(fixtures, name), 'utf8');

// Pure Model checks retained from the old, misleadingly named test_e2e.py.
// test_qml_runtime.py separately covers real QML FileView persistence.

test('recorded API responses become playable episodes and shows', () => {
  const trending = Model.parseTrending(read('trending.json'), 10);
  assert.strictEqual(trending.ok, true);
  assert.deepStrictEqual(
    trending.episodes.map((item) => item.episodeId),
    ['AOW3VXulOz', 'ydMOiRDhLM', 'mixedRSS001']
  );
  assert.strictEqual(trending.episodes[2].audioUrl, 'https://cdn.example.test/mixed.mp3');
  assert.ok(trending.episodes.every((item) => !item.audioUrl.includes('youtube.com')));

  const shows = Model.parsePodcasts(read('podcasts.json'));
  assert.strictEqual(shows.ok, true);
  assert.strictEqual(shows.total, 2);
  assert.strictEqual(shows.shows.length, 2);

  const show = Model.parseShow(read('show.json'));
  assert.strictEqual(show.ok, true);
  assert.strictEqual(show.episodes[0].podcastTitle, 'Y Combinator Startup Podcast');
});

test('replaying an episode moves it to the top and preserves its position', () => {
  const trending = Model.parseTrending(read('trending.json'), 10);
  const show = Model.parseShow(read('show.json'));
  let queue = Model.enqueue([], trending.episodes[1]);
  queue = Model.enqueue(queue, show.episodes[0]);
  queue = Model.enqueue(queue, trending.episodes[1]);
  queue = Model.rememberPosition(queue, queue[0], 1122, 4424);

  assert.deepStrictEqual(queue.map((item) => item.episodeId), ['ydMOiRDhLM', 'IuiARqppaF']);
  assert.strictEqual(queue[0].position, 1122);

  const restored = Model.parseState(JSON.stringify({ schemaVersion: 1, queue, nav: { tab: 1 } }));
  assert.strictEqual(restored.nav.tab, 1);
  assert.strictEqual(restored.queue[0].audioUrl, 'https://cdn.example.test/sonos.mp3');
  assert.strictEqual(restored.queue[0].position, 1122);
  assert.strictEqual(restored.queue[1].episodeId, 'IuiARqppaF');
});

test('restoring a queue drops YouTube rows without losing playable progress', () => {
  const restored = Model.parseState(JSON.stringify({
    schemaVersion: 1,
    queue: [
      { kind: 'episode', episodeId: 'yt', title: 'Old YouTube', audioUrl: 'https://www.youtube.com/watch?v=abc' },
      { kind: 'episode', episodeId: 'ok', title: 'Keep', audioUrl: 'https://cdn.example.test/keep.mp3', position: 12 },
    ],
    nav: {},
  }));

  assert.deepStrictEqual(restored.queue.map((item) => item.episodeId), ['ok']);
  assert.strictEqual(restored.queue[0].position, 12);
});
