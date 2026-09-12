const assert = require('assert');
const fs = require('fs');
const vm = require('vm');
const { qmlFunctions, qmlBinding } = require('./qml-source-harness');

// Panel.qml orchestration in a VM with mocked panel/listen state. Not a live
// QML or full-panel test; it exercises the real product functions and binding.

const PANEL = require.resolve('../Panel.qml');

// 1. Refresh button binding: an active search is always retryable, including
// when it was started from the Queue tab (the original regression).
const enabledExpression = qmlBinding(PANEL, 'refreshButton', 'enabled');
const buttonEnabled = (refreshing, tab, searchActive) =>
  vm.runInNewContext(`(${enabledExpression})`, { root: { refreshing, tab, searchActive } });
assert.strictEqual(buttonEnabled(false, 1, true), true, 'active Queue search stays refreshable');
assert.strictEqual(buttonEnabled(false, 1, false), false, 'Queue has no origin to refresh');
assert.strictEqual(buttonEnabled(false, 0, false), true);
assert.strictEqual(buttonEnabled(false, 2, false), true);
assert.strictEqual(buttonEnabled(false, 0, true), true);
assert.strictEqual(buttonEnabled(true, 0, false), false, 'an in-flight refresh disables the button');
assert.strictEqual(buttonEnabled(true, 1, true), false);

function panelContext(overrides) {
  const context = {
    listen: {
      calls: [],
      configure() {},
      ensureTrending(force) { context.listen.calls.push(['ensureTrending', force]); },
      ensureShows(force) {
        context.order.push('ensureShows');
        context.listen.calls.push(['ensureShows', force]);
      },
      ensureShow(id, force) { context.listen.calls.push(['ensureShow', id, force]); },
      ensureArtwork() {},
      beginSearch(kind, text, scope) { context.listen.calls.push(['beginSearch', kind, text, scope]); },
    },
    order: [],
    searchActive: false,
    tab: 0,
    searchKind: 'episodes',
    searchText: '',
    searchPodcastId: '',
    searchPodcastTitle: '',
    searchIndex: 0,
    selectedIndex: 0,
    apiBase: 'https://api.example.test',
    episodeLimit: 10,
    staleAfterMs: 600000,
    openShow: null,
    visibleRows: [],
    saveCurrentIndex() { context.order.push('saveCurrentIndex'); },
    restoreIndex() { context.order.push('restoreIndex'); },
    close() { context.order.push('close'); },
  };
  qmlFunctions(PANEL, ['ensureData', 'refresh', 'back', 'setSearchKind'], context);
  if (overrides) Object.assign(context, overrides);
  return context;
}

// 2. refresh() retries an active search before the Queue-tab early return.
let c = panelContext({ searchActive: true, tab: 1, searchKind: 'episodes', searchText: 'alpha', searchPodcastId: 'p1' });
c.refresh();
assert.deepStrictEqual(c.listen.calls, [['beginSearch', 'episodes', 'alpha', 'p1']]);

c = panelContext({ tab: 1 });
c.refresh();
assert.deepStrictEqual(c.listen.calls, [], 'Queue without search has nothing to refresh');

c = panelContext({ tab: 0 });
c.refresh();
assert.deepStrictEqual(c.listen.calls, [['ensureTrending', true]], 'refresh forces a cached list');

c = panelContext({ tab: 2, openShow: null });
c.refresh();
assert.deepStrictEqual(c.listen.calls, [['ensureShows', true]]);

c = panelContext({ tab: 2, openShow: { podcastId: 'p1' } });
c.refresh();
assert.deepStrictEqual(c.listen.calls, [['ensureShow', 'p1', true]]);

// 3. back() from a show restores the saved cursor, then asks for All Shows
// again (a show opened from Trending search may sit on a cold All Shows cache).
c = panelContext({ tab: 2, openShow: { podcastId: 'p1' } });
c.back();
assert.strictEqual(c.openShow, null);
assert.deepStrictEqual(c.order, ['saveCurrentIndex', 'restoreIndex', 'ensureShows']);
assert.deepStrictEqual(c.listen.calls, [['ensureShows', false]]);

c = panelContext({ tab: 2, openShow: null });
c.back();
assert.deepStrictEqual(c.order, ['close'], 'ordinary All Shows back closes the panel');
assert.deepStrictEqual(c.listen.calls, []);

c = panelContext({ tab: 0 });
c.back();
assert.deepStrictEqual(c.order, ['close']);

// 4. setSearchKind() switches mode, resets the cursor, and drops episode scope
// when entering Shows; switching back keeps whatever scope remains.
c = panelContext({ searchKind: 'episodes', searchText: 'alpha', searchPodcastId: 'p1', searchPodcastTitle: 'Show' });
c.setSearchKind('shows');
assert.strictEqual(c.searchKind, 'shows');
assert.strictEqual(c.searchPodcastId, '');
assert.strictEqual(c.searchPodcastTitle, '');
assert.strictEqual(c.searchIndex, 0);
assert.deepStrictEqual(c.listen.calls, [['beginSearch', 'shows', 'alpha', '']]);

c = panelContext({ searchKind: 'shows', searchText: 'alpha', searchPodcastId: 'p1' });
c.setSearchKind('episodes');
assert.strictEqual(c.searchKind, 'episodes');
assert.strictEqual(c.searchPodcastId, 'p1');
assert.deepStrictEqual(c.listen.calls, [['beginSearch', 'episodes', 'alpha', 'p1']]);

c = panelContext({ searchKind: 'shows' });
c.setSearchKind('nonsense');
assert.strictEqual(c.searchKind, 'episodes', 'unknown kind falls back to episodes');

// 5. The search field's Keys.onPressed handler: native Tab/Backtab toggles the
// mode, keeps focus in the field, and consumes the event so focus cannot leave.
function searchKeyHandler(calls, kind) {
  const source = fs.readFileSync(PANEL, 'utf8');
  const match = source.match(/Keys\.onPressed: (function\(event\) \{[\s\S]*?\n {12}\})/);
  assert.ok(match, 'searchField must define Keys.onPressed');
  const root = {
    searchKind: kind || 'shows',
    setSearchKind(kind) { calls.push(['setSearchKind', kind]); root.searchKind = kind; },
    searchEscape() { calls.push('searchEscape'); },
    moveCursor(delta) { calls.push(['moveCursor', delta]); },
    activateSearchSelection() { calls.push('activateSearchSelection'); },
  };
  const handler = vm.runInNewContext(`(${match[1]})`, {
    Qt: { Key_Tab: 1, Key_Backtab: 2, Key_Escape: 3, Key_Down: 4, Key_Up: 5, Key_Return: 6, Key_Enter: 7 },
    root,
    searchField: { forceActiveFocus() { calls.push('forceActiveFocus'); } },
  });
  return handler;
}

let calls = [];
let handler = searchKeyHandler(calls);
let event = { key: 1, accepted: false };
handler(event);
assert.deepStrictEqual(calls, [['setSearchKind', 'episodes'], 'forceActiveFocus']);
assert.strictEqual(event.accepted, true);

calls = [];
handler = searchKeyHandler(calls, 'episodes');
event = { key: 2, accepted: false };
handler(event);
assert.deepStrictEqual(calls, [['setSearchKind', 'shows'], 'forceActiveFocus']);
assert.strictEqual(event.accepted, true);

calls = [];
handler = searchKeyHandler(calls);
event = { key: 3, accepted: false };
handler(event);
assert.deepStrictEqual(calls, ['searchEscape'], 'Escape keeps its own binding');
assert.strictEqual(event.accepted, true);

console.log('Panel behavior tests passed (real Panel.qml JavaScript, mocked panel state)');
