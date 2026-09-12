const assert = require('assert');
const Model = require('../Model.js');
const { qmlFunctions } = require('./qml-vm');

const SERVICE = require.resolve('../Service.qml');

const oldEpisode = { episodeId: 'old', title: 'Old', audioUrl: 'https://example.test/old.mp3', position: 10 };
const freshEpisode = { episodeId: 'new', title: 'Fresh title', audioUrl: 'https://example.test/new.mp3', position: 0 };
let saves = 0;
let toggles = 0;
const context = {
  Model,
  queue: [oldEpisode, { ...freshEpisode, position: 80 }],
  playerProcess: { running: false },
  helperPath: '/test/play.py',
  playerFor: () => null,
  saveState: () => { saves++; },
  rememberPlayback: () => {
    context.queue = Model.rememberPosition(context.queue, oldEpisode, 123, 900);
  },
  togglePlaying: () => { toggles++; },
};
const { playEpisode, resumePendingPlayback } = qmlFunctions(
  SERVICE,
  ['playEpisode', 'resumePendingPlayback'],
  context
);
playEpisode(freshEpisode);
assert.strictEqual(context.queue[0].position, 80);
assert.strictEqual(context.queue[0].title, 'Fresh title');
assert.strictEqual(context.queue[1].position, 123);
assert.strictEqual(context.pendingSeek, 80);
assert.strictEqual(context.pendingSeekEpisodeId, 'new');
assert.strictEqual(context.playerProcess.running, true);
assert.strictEqual(saves, 1);
assert.strictEqual(freshEpisode.position, 0);

let sought = null;
context.currentPlayback = { episode: oldEpisode };
context.playbackLength = 200;
context.seekTo = (progress) => { sought = progress; return true; };
resumePendingPlayback();
assert.strictEqual(sought, null, 'Never seek the outgoing track to the incoming position');
assert.strictEqual(context.pendingSeek, 80);
context.currentPlayback = { episode: freshEpisode };
context.seekTo = () => false;
resumePendingPlayback();
assert.strictEqual(context.pendingSeek, 80, 'Keep the resume request until seeking is supported');
context.seekTo = (progress) => { sought = progress; return true; };
resumePendingPlayback();
assert.strictEqual(sought, 0.4);
assert.strictEqual(context.pendingSeek, 0);
assert.strictEqual(context.pendingSeekEpisodeId, '');

context.playerProcess = { running: false };
context.playerFor = () => ({});
playEpisode(freshEpisode);
assert.strictEqual(toggles, 1);
assert.strictEqual(context.playerProcess.running, false, 'An existing player should toggle, not relaunch');
assert.strictEqual(context.queue[0].position, 80);

console.log('Service orchestration tests passed (extracted JavaScript, not a live QML test)');
