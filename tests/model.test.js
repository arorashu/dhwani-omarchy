const assert = require('assert');
const Model = require('../Model.js');

assert.strictEqual(Model.feedUrl('http://127.0.0.1:8791///'), 'http://127.0.0.1:8791/v1/foryou/all');
assert.strictEqual(Model.feedUrl('--config=/tmp/evil'), '');
assert.strictEqual(Model.podcastsUrl('https://api-v1.dhwani.io/', 20), 'https://api-v1.dhwani.io/v1/podcasts?limit=20&offset=20');
assert.strictEqual(Model.showUrl('https://api-v1.dhwani.io', '../etc', 0), '');
assert.strictEqual(
  Model.showUrl('https://api-v1.dhwani.io', '9QqWbjH5mqlrsiaHMba1', 20),
  'https://api-v1.dhwani.io/v1/podcasts/9QqWbjH5mqlrsiaHMba1?limit=20&offset=20'
);
assert.ok(Model.curlHeaders().includes('Origin: https://podcast.dhwani.io'));
const manifest = require('../manifest.json');
const userAgents = Model.curlHeaders().filter((header) => header.startsWith('User-Agent:'));
assert.deepStrictEqual(userAgents, [
  `User-Agent: Dhwani-Omarchy/${manifest.version} (+https://github.com/arorashu/dhwani-omarchy)`,
]);
let jobs = Model.scheduleFetch([], 'trending', 'https://api.example/t');
jobs = Model.scheduleFetch(jobs, 'shows', 'https://api.example/s');
assert.strictEqual(jobs.length, 2);
jobs = Model.scheduleFetch(jobs, 'trending', 'https://api.example/t2');
assert.strictEqual(jobs[0].url, 'https://api.example/t2');
jobs = Model.scheduleFetch(jobs, 'moreShows', 'https://api.example/s2');
jobs = Model.scheduleFetch(jobs, 'shows', 'https://api.example/s0');
assert.deepStrictEqual(jobs.map((job) => job.kind), ['trending', 'shows']);
const taken = Model.takeFetch(jobs);
assert.strictEqual(taken.job.kind, 'trending');
assert.strictEqual(taken.rest.length, 1);
assert.strictEqual(Model.playbackTitle({ title: 'Episode', podcastTitle: 'Podcast' }), 'Episode · Podcast');
assert.strictEqual(Model.formatDuration(59), '1m');
assert.strictEqual(Model.formatDuration(3661), '1h 01m');
assert.strictEqual(Model.formatPosition(0), '0:00');
assert.strictEqual(Model.formatPosition(65.9), '1:05');
assert.strictEqual(Model.formatPosition(3661), '1:01:01');
assert.strictEqual(Model.playbackProgress(30, 120), 0.25);
assert.strictEqual(Model.playbackProgress(-1, 120), 0);
assert.strictEqual(Model.playbackProgress(140, 120), 1);
assert.strictEqual(Model.playbackProgress(10, 0), 0);
assert.strictEqual(Model.isFresh(1000, 1000 + 599000, 600000), true);
assert.strictEqual(Model.isFresh(1000, 1000 + 600000, 600000), false);

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

const trending = Model.parseTrending(JSON.stringify(payload), 7);
assert.deepStrictEqual(trending.episodes.map((episode) => episode.episodeId), ['episode001', 'episode002']);

const podcasts = Model.parsePodcasts(JSON.stringify({
  total: 88,
  offset: 0,
  podcasts: [
    { podcast_id: '9QqWbjH5mqlrsiaHMba1', title: 'Y Combinator Startup Podcast', artwork_url: 'https://cdn.example.test/a.jpg', episode_count: 79 },
    { podcast_id: 'bad', title: 'Ignored' },
  ],
}));
assert.strictEqual(podcasts.ok, true);
assert.strictEqual(podcasts.total, 88);
assert.strictEqual(podcasts.shows[0].kind, 'show');
assert.strictEqual(podcasts.shows.length, 1);
assert.strictEqual(Model.mergeShows(podcasts.shows, podcasts.shows).length, 1);

const show = Model.parseShow(JSON.stringify({
  podcast: { podcast_id: '9QqWbjH5mqlrsiaHMba1', title: 'Y Combinator Startup Podcast' },
  total_episodes: 79,
  offset: 0,
  episodes: [{
    video_id: 'IuiARqppaF',
    title: 'Paul Graham On Startups',
    duration: 1284,
    podcast_id: '9QqWbjH5mqlrsiaHMba1',
    media_options: [{ is_primary: true, path: 'https://cdn.example.test/pg.mp3' }],
  }],
}));
assert.strictEqual(show.ok, true);
assert.strictEqual(show.episodes[0].podcastTitle, 'Y Combinator Startup Podcast');
assert.strictEqual(show.episodes[0].episodeId, 'IuiARqppaF');

const stacked = Model.enqueue(Model.enqueue([], show.episodes[0]), Object.assign({}, show.episodes[0], { title: 'Updated' }));
assert.strictEqual(stacked.length, 1);
assert.strictEqual(stacked[0].title, 'Updated');
const remembered = Model.rememberPosition(stacked, stacked[0], 42, 1284);
assert.strictEqual(remembered[0].position, 42);
const merged = Model.mergeQueue(
  [{ episodeId: 'old1', title: 'Old', audioUrl: 'https://cdn.example.test/old.mp3', podcastTitle: 'P' }],
  stacked
);
assert.strictEqual(merged[0].episodeId, stacked[0].episodeId);
assert.strictEqual(merged[1].episodeId, 'old1');

const restored = Model.parseState(JSON.stringify({
  schemaVersion: 1,
  queue: stacked,
  nav: { tab: 2, openShowId: '9QqWbjH5mqlrsiaHMba1' },
}));
assert.strictEqual(restored.queue[0].audioUrl, 'https://cdn.example.test/pg.mp3');
assert.strictEqual(restored.nav.tab, 2);

console.log('Model tests passed');
