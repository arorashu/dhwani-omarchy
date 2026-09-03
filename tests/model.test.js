const assert = require('assert');
const Model = require('../Model.js');

assert.strictEqual(Model.feedUrl('http://127.0.0.1:8791///'), 'http://127.0.0.1:8791/v1/foryou/all');
assert.strictEqual(Model.feedUrl('--config=/tmp/evil'), '');
assert.strictEqual(Model.playbackTitle({ title: 'Episode', podcastTitle: 'Podcast' }), 'Episode · Podcast');
assert.strictEqual(Model.formatDuration(59), '1m');
assert.strictEqual(Model.formatDuration(3661), '1h 01m');

const media = [
  { path: 'file:///tmp/not-a-podcast.mp3' },
  { source_id: 'https://cdn.example.test/secondary.mp3' },
  { is_primary: true, path: 'https://cdn.example.test/primary.mp3' },
];
assert.strictEqual(Model.playableUrl(media), 'https://cdn.example.test/primary.mp3');

const payload = {
  daily_listen: {
    episode_id: 'episode001',
    podcast_id: 'podcast000000000000001',
    title: 'A deliberate first listen',
    podcast_title: 'Signal',
    duration: 3661,
    media_options: media,
  },
  picks: [],
  trending: [
    {
      episode_id: 'episode001',
      title: 'Duplicate',
      podcast_title: 'Signal',
      media_options: media,
    },
    {
      episode_id: 'episode002',
      title: 'A second listen',
      podcast_title: 'Texture',
      media_options: [{ path: 'https://cdn.example.test/second.mp3' }],
    },
    {
      episode_id: 'episode003',
      title: 'Local files are ignored',
      podcast_title: 'Texture',
      media_options: [{ path: '/tmp/audio.mp3' }],
    },
  ],
};
const feed = Model.parseFeed(JSON.stringify(payload), 7);
assert.strictEqual(feed.ok, true);
assert.deepStrictEqual(feed.episodes.map((episode) => episode.episodeId), ['episode001', 'episode002']);
assert.strictEqual(feed.episodes[0].audioUrl, 'https://cdn.example.test/primary.mp3');
assert.strictEqual(Model.parseFeed('{', 7).ok, false);
assert.strictEqual(Model.parseFeed('[]', 7).ok, false);
assert.strictEqual(Model.parseFeed('{"detail":{"message":"nope"}}', 7).error, 'Dhwani request failed');

console.log('Model tests passed');
