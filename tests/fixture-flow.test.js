const assert = require('assert');
const fs = require('fs');
const path = require('path');
const Model = require('../Model.js');

// Fixture API JSON -> Model -> queue -> persisted-state roundtrip. Pure Node and
// pure Model.js: no running desktop, no QML, no Python state helper.

const FIXTURES = path.join(__dirname, 'fixtures');
const read = (name) => fs.readFileSync(path.join(FIXTURES, name), 'utf8');

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

let queue = [];
queue = Model.enqueue(queue, trending.episodes[1]);
queue = Model.enqueue(queue, show.episodes[0]);
queue = Model.enqueue(queue, trending.episodes[1]);
queue = Model.rememberPosition(queue, queue[0], 1122, 4424);
assert.deepStrictEqual(
  queue.map((item) => item.episodeId),
  ['ydMOiRDhLM', 'IuiARqppaF'],
  'replaying a stacked episode moves it back to the top'
);
assert.strictEqual(queue[0].position, 1122);

const restored = Model.parseState(JSON.stringify({ schemaVersion: 1, queue, nav: { tab: 1 } }));
assert.strictEqual(restored.nav.tab, 1);
assert.strictEqual(restored.queue[0].audioUrl, 'https://cdn.example.test/sonos.mp3');
assert.strictEqual(restored.queue[0].position, 1122);
assert.strictEqual(restored.queue[1].episodeId, 'IuiARqppaF');

// A persisted YouTube (unplayable) row is dropped while the rest survives.
const persisted = Model.parseState(
  JSON.stringify({
    schemaVersion: 1,
    queue: [
      { kind: 'episode', episodeId: 'yt', title: 'Old YouTube', audioUrl: 'https://www.youtube.com/watch?v=abc' },
      { kind: 'episode', episodeId: 'ok', title: 'Keep', audioUrl: 'https://cdn.example.test/keep.mp3', position: 12 },
    ],
    nav: {},
  })
);
assert.deepStrictEqual(persisted.queue.map((item) => item.episodeId), ['ok']);
assert.strictEqual(persisted.queue[0].position, 12);

console.log('Fixture flow tests passed (Model.js fixtures and persisted queue, no runtime)');
