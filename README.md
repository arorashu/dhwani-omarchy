# Dhwani for Omarchy

A small native doorway to Dhwani: click the bar icon, choose an episode, and keep working with playback in Omarchy's existing media surface.

> This first release is a private developer preview. It reads the public Dhwani API as a logged-out radio, then keeps a local listening queue.

![Omarchy plugin](https://img.shields.io/badge/Omarchy-4.0%2B-black)
[![CI](https://github.com/arorashu/dhwani-omarchy/actions/workflows/ci.yml/badge.svg)](https://github.com/arorashu/dhwani-omarchy/actions/workflows/ci.yml)

## The first cut

- one quiet bar icon
- one keyboard-first listening panel
- Trending, Queue, and All Shows tabs
- `/` title search across episodes and shows, with optional per-show episode scope
- paginated show lists and in-show episode lists
- a local queue that stacks newly played episodes on top
- 10-minute client-side cache so tab switches do not refetch
- audio handed to a dedicated, single-owner `mpv` instance
- play/pause and 15-second back/30-second forward actions
- a clickable progress bar with elapsed and total time
- reactive playback feedback through the panel and Omarchy's existing MPRIS media surface
- live Omarchy theme, font, spacing, and panel behavior

There is deliberately no account screen, transcript reader, queue manager, or second media player here. The plugin asks Dhwani what is worth hearing and lets the OS do the rest.

## Requirements

Omarchy 4.0 or newer, plus `curl`, Python 3.10 or newer, `mpv`, and `mpv-mpris`. Current Omarchy installations include these media pieces.

## Install

Omarchy plugins execute unsandboxed code. Read the five small source files before enabling this one.

While the repository is private, install it through SSH:

```bash
omarchy plugin add git@github.com:arorashu/dhwani-omarchy.git --enable
```

Use the HTTPS URL after the repository becomes public:

```bash
omarchy plugin add https://github.com/arorashu/dhwani-omarchy.git --enable
```

To install a local checkout instead:

```bash
omarchy plugin validate .
mkdir -p ~/.config/omarchy/plugins/io.dhwani.listen
cp -a manifest.json BarWidget.qml Panel.qml Service.qml Model.js play.py \
  ~/.config/omarchy/plugins/io.dhwani.listen/
omarchy-shell shell rescanPlugins
omarchy plugin enable io.dhwani.listen --section center
```

Enable Omarchy's media widget if it is not already in the bar:

```bash
omarchy plugin enable omarchy.media --section center --after io.dhwani.listen
```

Update or remove a Git installation with `omarchy plugin update io.dhwani.listen` or `omarchy plugin remove io.dhwani.listen`.

During local development, repeat the `cp` command after editing this checkout. Omarchy 4.0.2 notices plugin changes but can reuse stale compiled QML ([#6981](https://github.com/omacom/omarchy/issues/6981)). If a visible change stays stale, let the watcher settle for several seconds before running `omarchy restart shell`; do not chain the copy directly into a restart on Quickshell 0.3.1 ([#956](https://github.com/quickshell-mirror/quickshell/issues/956)).

Optional Hyprland shortcut in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + M", "Dhwani", "omarchy-shell shell toggle io.dhwani.listen")
```

Check that the chord is free with `omarchy menu keybindings --print`, then run `hyprctl reload`.

## Configure

The defaults point at the public API. Omarchy's bar settings expose:

- `apiBase`
- `episodeLimit`
- `staleAfterSec` (client cache TTL; default 10 minutes)

The corresponding `shell.json` entry is plain data:

```json
{
  "id": "io.dhwani.listen",
  "apiBase": "https://api-v1.dhwani.io",
  "episodeLimit": 10,
  "staleAfterSec": 600
}
```

Local listening state lives in `~/.local/state/dhwani-omarchy/state.json`.

## API contract

Anonymous requests send `Origin: https://podcast.dhwani.io` and a Dhwani user agent:

```http
GET /v1/foryou/all
GET /v1/podcasts?limit=20&offset=0
GET /v1/podcasts/{podcast_id}?limit=20&offset=0
GET /v1/search/titles?q=sleep&kind=episodes&limit=20&offset=0
Accept: application/json
Origin: https://podcast.dhwani.io
User-Agent: Dhwani-Omarchy/0.1.0 (+https://github.com/arorashu/dhwani-omarchy)
```

The API User-Agent identifies the plugin and its release version for server-side diagnostics. It carries no account or installation identifier and grants no special access. It applies to API requests, not artwork or `mpv` audio requests; the plugin sends no playback telemetry. Release changes must update `manifest.json` and `Model.js` together; the model tests enforce version agreement.

A playable item needs only:

```json
{
  "episode_id": "AbCdEf1234",
  "podcast_id": "AbCdEf1234GhIjKl5678",
  "title": "Episode title",
  "podcast_title": "Podcast title",
  "artwork_url": "https://…",
  "duration": 3600,
  "media_options": [
    {
      "is_primary": true,
      "path": "https://cdn.example/episode.mp3"
    }
  ]
}
```

Only HTTP(S) media is accepted and responses are capped at 1 MiB. The QML process owns transport; `Model.js` owns source mapping and validation; `play.py` owns the local player boundary.

## Local API

Use a separate database on the shared development Postgres server:

```bash
createdb -h localhost -p 5433 --template=dhwani_template dhwani_omarchy

APP_ENV=dev AUTH_PROVIDER=local DB_BACKEND=postgres \
POSTGRES_HOST=localhost POSTGRES_PORT=5433 POSTGRES_DB=dhwani_omarchy \
STORAGE_BASE_PATH="$HOME/dhwani-data/dev/omarchy" \
uv run --project server --extra server \
uvicorn server.pod_router:app --host 127.0.0.1 --port 8791
```

The plugin needs neither the UI nor the ML server to browse and play already-ingested RSS episodes. A fresh database is empty: run Dhwani's normal RSS ingestion and recommendation generation first.

Playback continues when the panel or shell closes, appears through MPRIS, and normally exits at end of track. Pause it from the panel or a MPRIS client; stop it through MPRIS before disabling or removing the plugin.

## Test

```bash
omarchy plugin validate .
imports=$(mktemp -d)
ln -s /usr/share/omarchy/shell "$imports/qs"
/usr/lib/qt6/bin/qmllint -I "$imports" BarWidget.qml Panel.qml
rm -rf "$imports"
node tests/model.test.js
node tests/service.test.js
node tests/artwork.test.js
node tests/search.test.js
node tests/fixture-flow.test.js
node tests/panel.test.js
python3 tests/test_qml_runtime.py
python3 tests/test_play.py
python3 tests/test_qml_contract.py
python3 tests/test_playback_pipeline.py
ruff check play.py tests
ruff format --check play.py tests
```

The offscreen runtime test requires Quickshell, curl, and `dbus-run-session`. It uses a local fixture API and isolated state/D-Bus session to verify image bindings, request deduplication, QML persistence, search-state generation handling, pagination, and scope. It does not test the full panel, desktop integration, or playback. `tests/fixture-flow.test.js` covers the fixture-to-queue data flow, not a running desktop.

The isolated playback proof (`test_playback_pipeline.py`) is always strict: it needs `mpv`, `mpv-mpris`, `dbus-run-session`, systemd `busctl`, and `quickshell`, and fails rather than skipping when one is missing. It drives a private sandboxed mpv/MPRIS bus and an offscreen `Service.qml`; it never touches the user's own player or session.

## Controls

- `super` + `ctrl` + `m`: open or close (when the optional binding above is installed)
- click: open or close
- right-click: refresh and open
- `←` / `→`: switch Trending, Queue, and All Shows
- `/`: open title search; `tab` switches Episodes/Shows, `esc` clears scope then leaves search
- `h` / `l`: back 15 seconds / forward 30 seconds
- `↑` / `↓` or `j` / `k`: choose
- `enter`: open a show, play an episode, or toggle the selected episode if already playing
- `space`: play/pause the current episode
- click the progress bar or −15 / +30: seek
- `r`: refresh the current remote list, ignoring cache
- `escape`: leave a show, or close

The in-panel bindings are fixed in this release. Configure the global open/close shortcut in Hyprland using the optional binding in [Install](#install); the plugin does not reserve a global shortcut automatically.

## License

MIT
