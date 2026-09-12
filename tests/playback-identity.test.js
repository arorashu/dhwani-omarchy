const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const Model = require('../Model.js');

// Playback identity in Service.qml: duplicate-titled episodes must resolve by the
// real MPRIS xesam:url AND the expected human label. These are the real product
// functions extracted into a VM with mocked MPRIS players; the companion private
// pipeline/offscreen check exercises the live metadata source.

const source = fs.readFileSync(require.resolve('../Service.qml'), 'utf8');

const A = {
  kind: 'episode',
  episodeId: 'A',
  podcastId: 'abcdefghijklmnopqrst',
  title: 'Trailer',
  podcastTitle: 'Show',
  audioUrl: 'http://127.0.0.1:9/episode-a.wav',
  duration: 600,
  position: 10,
};
const B = { ...A, episodeId: 'B', audioUrl: 'http://127.0.0.1:9/episode-b.wav', position: 20 };
const LABEL = Model.playbackTitle(A);
assert.strictEqual(Model.playbackTitle(B), LABEL, 'fixtures must share one label');

function mpvPlayer(url, title) {
  return {
    identity: 'mpv',
    trackTitle: title === undefined ? LABEL : title,
    metadata: { 'xesam:url': url, 'mpris:trackid': '/0', 'xesam:title': LABEL },
  };
}

function makeContext(overrides) {
  const context = {
    Model,
    mprisPlayers: [],
    trending: [],
    queue: [],
    showsById: {},
    pendingSeek: 0,
    pendingSeekEpisodeId: '',
    playbackLength: 0,
    playbackPosition: 0,
    queuedId: '',
    launchingEpisodeId: '',
    errorText: '',
    playerProcess: { running: false, command: [] },
    helperPath: '/test/play.py',
    saves: 0,
    toggles: 0,
    sought: [],
    saveState() { context.saves++; },
    saveSoon() {},
    togglePlaying() { context.toggles++; },
    seekTo(progress) { context.sought.push(progress); return true; },
  };
  Object.defineProperty(context, 'currentPlayback', {
    get() { return context.findCurrentPlayback(); },
    configurable: true,
  });
  Object.defineProperty(context, 'playbackPlayer', {
    get() {
      const playback = context.findCurrentPlayback();
      return playback ? playback.player : null;
    },
    configurable: true,
  });
  for (const name of [
    'mpvPlayerMedia', 'playerFor', 'allEpisodes', 'findCurrentPlayback',
    'playEpisode', 'resumePendingPlayback', 'playbackHelperExited',
    'rememberPlayback', 'capturePlaying',
  ]) {
    const match = source.match(new RegExp(`  function ${name}\\([^]*?\\n  \\}`));
    assert.ok(match, `Service.qml must define ${name}`);
    context[name] = vm.runInNewContext(`(${match[0].trim()})`, context);
  }
  Object.assign(context, overrides || {});
  return context;
}

// 1. URL+label identity separates two episodes that share a human title.
let c = makeContext({ trending: [A], queue: [B], mprisPlayers: [mpvPlayer(A.audioUrl)] });
assert.strictEqual(c.playerFor(A), c.mprisPlayers[0]);
assert.strictEqual(c.playerFor(B), null, 'the shared label must not match B to A');
assert.strictEqual(c.findCurrentPlayback().episode.episodeId, 'A');

// 2. First-title-match no longer wins: B is playing but A sits first in the catalog.
c = makeContext({ trending: [A], queue: [B], mprisPlayers: [mpvPlayer(B.audioUrl)] });
assert.strictEqual(c.findCurrentPlayback().episode.episodeId, 'B');
assert.strictEqual(c.playerFor(A), null, 'A must not be claimed while B plays');
assert.strictEqual(c.playerFor(B), c.mprisPlayers[0]);

// 3. Selecting B while A plays launches B instead of toggling A.
c = makeContext({
  trending: [A],
  queue: [B],
  mprisPlayers: [mpvPlayer(A.audioUrl)],
  rememberPlayback() {},
});
c.playEpisode(B);
assert.strictEqual(c.toggles, 0, 'B must not toggle the A player');
assert.strictEqual(c.playerProcess.running, true, 'B is launched instead');
assert.strictEqual(c.pendingSeekEpisodeId, 'B');
assert.strictEqual(c.pendingSeek, 20, 'B resumes from its own saved position');
assert.strictEqual(c.queue[0].episodeId, 'B');

// 4. Selecting the actually-playing A still toggles.
c = makeContext({
  trending: [A],
  queue: [B],
  mprisPlayers: [mpvPlayer(A.audioUrl)],
  rememberPlayback() {},
});
c.playEpisode(A);
assert.strictEqual(c.toggles, 1);
assert.strictEqual(c.playerProcess.running, false);

// 5. Selecting the actually-playing B toggles B, not A.
c = makeContext({
  trending: [A],
  queue: [B],
  mprisPlayers: [mpvPlayer(B.audioUrl)],
  rememberPlayback() {},
});
c.playEpisode(B);
assert.strictEqual(c.toggles, 1);
assert.strictEqual(c.playerProcess.running, false);

// 6. The current position is saved against the row the URL identifies, not the
//    first row with the same label.
c = makeContext({
  trending: [],
  queue: [A, B],
  mprisPlayers: [mpvPlayer(B.audioUrl)],
  queuedId: 'B',
  playbackPosition: 300,
  playbackLength: 600,
});
assert.strictEqual(c.findCurrentPlayback().episode.episodeId, 'B');
c.rememberPlayback();
assert.strictEqual(c.queue.find((row) => row.episodeId === 'B').position, 300);
assert.strictEqual(c.queue.find((row) => row.episodeId === 'A').position, 10);

// 7. Stale metadata transition: while B is launching, MPRIS still reports A.
//    Nothing may be attributed to A, and once the URL flips the resume seeks B
//    and clears the transition marker.
c = makeContext({
  trending: [],
  queue: [A, B],
  mprisPlayers: [mpvPlayer(A.audioUrl)],
  pendingSeekEpisodeId: 'B',
  pendingSeek: 20,
  playbackLength: 45,
  queuedId: 'B',
});
assert.strictEqual(c.findCurrentPlayback(), null, 'stale A metadata is not the incoming B');
c.rememberPlayback();
assert.strictEqual(c.queue.find((row) => row.episodeId === 'B').position, 20);
assert.strictEqual(c.queue.find((row) => row.episodeId === 'A').position, 10);
c.mprisPlayers[0].metadata['xesam:url'] = B.audioUrl;
assert.strictEqual(c.findCurrentPlayback().episode.episodeId, 'B');
c.resumePendingPlayback();
assert.deepStrictEqual(c.sought, [20 / 45]);
assert.strictEqual(c.pendingSeek, 0);
assert.strictEqual(c.pendingSeekEpisodeId, '');

// Reselecting A while B is pending must issue a new load, not toggle through
// playbackPlayer (which is intentionally null during the stale-metadata window).
c = makeContext({
  trending: [A],
  queue: [B],
  mprisPlayers: [mpvPlayer(A.audioUrl)],
  pendingSeekEpisodeId: 'B',
  pendingSeek: 20,
});
assert.strictEqual(c.currentPlayback, null);
c.playEpisode(A);
assert.strictEqual(c.toggles, 0, 'a pending different track must not take the toggle path');
assert.strictEqual(c.playerProcess.running, true);
assert.strictEqual(c.playerProcess.command[2], A.audioUrl);
assert.strictEqual(c.pendingSeekEpisodeId, 'A');

// 8. A confirmed launch that needs no seek also clears the marker (so a paused
//    zero-position track cannot suppress identity forever).
c = makeContext({
  trending: [A],
  queue: [B],
  mprisPlayers: [mpvPlayer(B.audioUrl)],
  pendingSeekEpisodeId: 'B',
  pendingSeek: 0,
  playbackLength: 45,
});
c.resumePendingPlayback();
assert.deepStrictEqual(c.sought, []);
assert.strictEqual(c.pendingSeekEpisodeId, '');

// 9. A failed helper clears the marker so the still-valid previous playback is
//    claimable again; a successful exit leaves an unconfirmed marker alone.
c = makeContext({
  trending: [A],
  queue: [B],
  mprisPlayers: [mpvPlayer(A.audioUrl)],
  pendingSeekEpisodeId: 'B',
  pendingSeek: 20,
  launchingEpisodeId: 'B',
});
assert.strictEqual(c.findCurrentPlayback(), null);
c.playbackHelperExited(1, 'player exploded');
assert.strictEqual(c.pendingSeekEpisodeId, '');
assert.strictEqual(c.pendingSeek, 0);
assert.strictEqual(c.launchingEpisodeId, '');
assert.strictEqual(c.errorText, 'player exploded');
assert.strictEqual(c.findCurrentPlayback().episode.episodeId, 'A', 'old valid playback is visible again');
c = makeContext({ trending: [A], queue: [B], mprisPlayers: [mpvPlayer(A.audioUrl)], pendingSeekEpisodeId: 'B' });
c.playbackHelperExited(0, '');
assert.strictEqual(c.pendingSeekEpisodeId, 'B');

// 10. Missing URL metadata claims nothing: no fallback, no guessed position, and
//     B still launches rather than toggling a same-titled sibling.
for (const metadata of [{}, undefined]) {
  const player = { identity: 'mpv', trackTitle: LABEL };
  if (metadata !== undefined) player.metadata = metadata;
  c = makeContext({ trending: [A], queue: [B], mprisPlayers: [player] });
  assert.strictEqual(c.playerFor(A), null);
  assert.strictEqual(c.playerFor(B), null);
  assert.strictEqual(c.findCurrentPlayback(), null);
  c.rememberPlayback();
  assert.strictEqual(c.queue[0].position, 20, 'no position may be written to a guess');
}
// The same holds even when only one catalog row carries the label: loaded pages
// are incomplete, so local uniqueness is not safe identity.
c = makeContext({ trending: [A], queue: [], mprisPlayers: [{ identity: 'mpv', trackTitle: LABEL, metadata: {} }] });
assert.strictEqual(c.playerFor(A), null);
assert.strictEqual(c.findCurrentPlayback(), null);

// 11. URL alone is not enough: mixed stale metadata (matching URL, wrong label)
//     and an unrelated mpv instance must not be claimed.
c = makeContext({ trending: [A], queue: [B], mprisPlayers: [mpvPlayer(A.audioUrl, 'Something Else · Show')] });
assert.strictEqual(c.playerFor(A), null);
assert.strictEqual(c.findCurrentPlayback(), null);
c = makeContext({ trending: [A], queue: [B], mprisPlayers: [mpvPlayer('http://127.0.0.1:9/other.wav')] });
assert.strictEqual(c.playerFor(A), null);
assert.strictEqual(c.playerFor(B), null);
assert.strictEqual(c.findCurrentPlayback(), null);

// 12. Only the player whose URL and label both match is chosen, and non-mpv
//     players are ignored entirely.
c = makeContext({
  trending: [A],
  queue: [B],
  mprisPlayers: [mpvPlayer(A.audioUrl, 'Other · Show'), mpvPlayer(A.audioUrl)],
});
assert.strictEqual(c.playerFor(A), c.mprisPlayers[1]);
c = makeContext({
  trending: [A],
  queue: [B],
  mprisPlayers: [{ identity: 'Spotify', trackTitle: LABEL, metadata: { 'xesam:url': A.audioUrl } }],
});
assert.strictEqual(c.playerFor(A), null);

// 13. A cold/reloaded service derives identity from live metadata alone: no
//     in-memory launch marker is required to pick B over the first A row.
c = makeContext({ trending: [A], queue: [B], mprisPlayers: [mpvPlayer(B.audioUrl)] });
assert.strictEqual(c.pendingSeekEpisodeId, '');
assert.strictEqual(c.findCurrentPlayback().episode.episodeId, 'B');

console.log('Playback identity tests passed (real Service functions, mocked MPRIS metadata)');
