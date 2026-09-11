const assert = require('assert');
const Model = require('../Model.js');
const manifest = require('../manifest.json');

assert.strictEqual(Model.feedUrl('http://127.0.0.1:8791///'), 'http://127.0.0.1:8791/v1/foryou/all');
assert.strictEqual(Model.feedUrl('--config=/tmp/evil'), '');
assert.strictEqual(Model.podcastsUrl('https://api-v1.dhwani.io/', 20), 'https://api-v1.dhwani.io/v1/podcasts?limit=20&offset=20');
assert.strictEqual(Model.showUrl('https://api-v1.dhwani.io', '../etc', 0), '');
assert.strictEqual(
  Model.showUrl('https://api-v1.dhwani.io', '9QqWbjH5mqlrsiaHMba1', 20),
  'https://api-v1.dhwani.io/v1/podcasts/9QqWbjH5mqlrsiaHMba1?limit=20&offset=20'
);
assert.ok(Model.curlHeaders().includes('Origin: https://podcast.dhwani.io'));
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
assert.strictEqual(Model.playbackTitle(null), '');
assert.strictEqual(Model.playbackTitle({ title: '', podcastTitle: '' }), 'Dhwani');
assert.strictEqual(
  Model.playbackTitle({ title: '  spaced   title\n\nwith\ttabs  ', podcastTitle: '  Show  ' }),
  'spaced title with tabs · Show'
);
// Parity with play.py: cap at 240 Unicode code points, never split an emoji.
const cappedTitle = Model.playbackTitle({
  title: 'A'.repeat(230) + '\n\n  🙂' + 'B'.repeat(40),
  podcastTitle: 'Proof  Show',
});
assert.strictEqual(Array.from(cappedTitle).length, 240);
assert.strictEqual(Array.from(cappedTitle)[231], '🙂');
assert.strictEqual(cappedTitle.endsWith('B'.repeat(8)), true);
assert.strictEqual(cappedTitle.includes('\uFFFD'), false);
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
const freshRow = Object.assign({}, show.episodes[0], { title: 'Fresh metadata', position: 0 });
const resumed = Model.resumeEpisode(remembered, freshRow);
assert.strictEqual(resumed.position, 42);
assert.strictEqual(resumed.title, 'Fresh metadata');
assert.strictEqual(freshRow.position, 0);
assert.strictEqual(Model.resumeEpisode([], freshRow).position, 0);
const rewound = Model.rememberPosition(remembered, remembered[0], 0, 1284);
assert.strictEqual(Model.resumeEpisode(rewound, resumed).position, 0);
assert.strictEqual(Model.mergeQueue(remembered, rewound)[0].position, 0);
const urlOnly = Object.assign({}, freshRow, { episodeId: '' });
assert.strictEqual(Model.resumeEpisode([Object.assign({}, urlOnly, { position: 21 })], urlOnly).position, 21);
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

// Title search URL, payload, and source policy
assert.strictEqual(
  Model.titleSearchUrl('https://api-v1.dhwani.io/', 'episodes', ' sleep ', 20, '9QqWbjH5mqlrsiaHMba1'),
  'https://api-v1.dhwani.io/v1/search/titles?q=sleep&kind=episodes&limit=20&offset=20&podcast_id=9QqWbjH5mqlrsiaHMba1'
);
assert.strictEqual(
  Model.titleSearchUrl('https://api-v1.dhwani.io', 'shows', 'sleep', 0, '9QqWbjH5mqlrsiaHMba1'),
  'https://api-v1.dhwani.io/v1/search/titles?q=sleep&kind=shows&limit=20&offset=0'
);
assert.strictEqual(Model.titleSearchUrl('https://api-v1.dhwani.io', 'episodes', '   ', 0, ''), '');
assert.strictEqual(Model.titleSearchUrl('https://api-v1.dhwani.io', 'episodes', 'x'.repeat(150), 0, '').includes('x'.repeat(101)), false);

const youtubePrimary = { is_primary: true, source_type: 'YouTube', mime_type: 'video/mp4', path: 'https://www.youtube.com/watch?v=abc' };
const rssAudio = { source_type: 'RSS', mime_type: 'audio/mpeg', path: 'https://cdn.example.test/audio.mp3' };
assert.strictEqual(Model.playableUrl([youtubePrimary, rssAudio]), 'https://cdn.example.test/audio.mp3');
assert.strictEqual(
  Model.playableUrl([{ is_primary: true, path: 'https://cdn.example.test/no-metadata.mp3' }, rssAudio]),
  'https://cdn.example.test/no-metadata.mp3'
);
assert.strictEqual(Model.playableUrl([youtubePrimary]), '');
assert.strictEqual(Model.playableUrl([{ path: 'https://youtu.be/abc' }]), '');
assert.strictEqual(Model.playableUrl([{ source_type: 'RSS', path: 'https://www.youtube.com/watch?v=abc' }]), '');
assert.strictEqual(Model.playableUrl([{ mime_type: 'video/mp4', path: 'https://cdn.example.test/video.mp4' }]), '');
assert.strictEqual(Model.isPlayableAudioUrl('https://www.youtube.com/watch?v=abc'), false);
assert.strictEqual(Model.isPlayableAudioUrl('https://youtube.com./watch?v=abc'), false);
assert.strictEqual(Model.isYouTubeUrl('https://www.youtube.com./watch?v=abc'), true);
assert.strictEqual(Model.isPlayableAudioUrl('https://cdn.example.test/a.mp3'), true);
assert.strictEqual(Model.playableUrl([{ is_primary: true, path: 'https://cdn.example.test/primary.mp3' }]), 'https://cdn.example.test/primary.mp3');

const searchPayload = {
  query: 'sleep',
  kind: 'episodes',
  limit: 20,
  offset: 40,
  total: 87,
  episodes: [
    {
      video_id: 'ep1',
      podcast_id: '9QqWbjH5mqlrsiaHMba1',
      title: 'Sleep',
      podcast_title: 'Show',
      artwork_url: '',
      podcast_artwork_url: 'https://cdn.example.test/show.png',
      media_options: [rssAudio],
    },
    { video_id: 'ep2', title: 'YouTube only', media_options: [youtubePrimary] },
  ],
};
const search = Model.parseTitleSearch(JSON.stringify(searchPayload));
assert.strictEqual(search.ok, true);
assert.strictEqual(search.kind, 'episodes');
assert.strictEqual(search.total, 87);
assert.strictEqual(search.nextOffset, 60);
assert.deepStrictEqual(search.episodes.map((item) => item.episodeId), ['ep1']);
assert.strictEqual(search.episodes[0].artworkUrl, 'https://cdn.example.test/show.png');
assert.strictEqual(search.shows.length, 0);

const showSearch = Model.parseTitleSearch(
  JSON.stringify({
    query: 'sleep',
    kind: 'shows',
    limit: 20,
    offset: 0,
    total: 3,
    podcasts: [
      { podcast_id: '9QqWbjH5mqlrsiaHMba1', title: 'Sleep Show', artwork_url: 'https://cdn.example.test/s.png', episode_count: 5 },
    ],
  })
);
assert.strictEqual(showSearch.kind, 'shows');
assert.strictEqual(showSearch.shows.length, 1);
assert.strictEqual(showSearch.shows[0].episodeCount, 5);
assert.deepStrictEqual(showSearch.episodes, []);
assert.strictEqual(Model.parseTitleSearch('{').ok, false);
const emptySearch = Model.parseTitleSearch(
  JSON.stringify({ query: 'zzz', kind: 'episodes', limit: 20, offset: 0, total: 0, episodes: [] })
);
assert.strictEqual(emptySearch.ok, true);
assert.strictEqual(emptySearch.error, '');
assert.strictEqual(emptySearch.total, 0);
assert.notStrictEqual(Model.searchKey('episodes', 'a', ''), Model.searchKey('shows', 'a', ''));
assert.notStrictEqual(Model.searchKey('episodes', 'a', ''), Model.searchKey('episodes', 'a', '9QqWbjH5mqlrsiaHMba1'));

assert.strictEqual(
  Model.coerceEpisode({ episodeId: 'yt', title: 'Old', audioUrl: 'https://www.youtube.com/watch?v=abc' }),
  null
);
assert.strictEqual(
  Model.coerceEpisode({ episodeId: 'ok', title: 'Old', audioUrl: 'https://cdn.example.test/a.mp3' }).audioUrl,
  'https://cdn.example.test/a.mp3'
);
const youtubeState = Model.parseState(
  JSON.stringify({ schemaVersion: 1, queue: [{ episodeId: 'yt', title: 'Old', audioUrl: 'https://youtu.be/abc' }] })
);
assert.strictEqual(youtubeState.queue.length, 0);

let searchJobs = Model.scheduleFetch([], 'search', 'https://api.example/s1', 1);
searchJobs = Model.scheduleFetch(searchJobs, 'search', 'https://api.example/s2', 2);
assert.deepStrictEqual(searchJobs.map((job) => job.url), ['https://api.example/s2']);
assert.strictEqual(searchJobs[0].token, 2);
searchJobs = Model.scheduleFetch(searchJobs, 'moreSearch', 'https://api.example/s3', 2);
assert.deepStrictEqual(searchJobs.map((job) => job.kind), ['search', 'moreSearch']);
searchJobs = Model.scheduleFetch(searchJobs, 'search', 'https://api.example/s4', 3);
assert.deepStrictEqual(searchJobs.map((job) => job.kind), ['search']);
assert.strictEqual(Model.dropFetches(searchJobs, ['search', 'moreSearch']).length, 0);
const priority = Model.takeFetch([{ kind: 'artwork:abc', url: 'a' }, { kind: 'trending', url: 't' }]);
assert.strictEqual(priority.job.kind, 'trending');
assert.deepStrictEqual(priority.rest.map((job) => job.kind), ['artwork:abc']);

console.log('Model tests passed');
