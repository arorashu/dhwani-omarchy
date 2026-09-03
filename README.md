# Dhwani for Omarchy

A small native doorway to Dhwani: click the bar icon, choose an episode, and keep working with playback in Omarchy's existing media surface.

> This first release is a private developer preview. Its default API is local and must be running with populated podcast data before installation.

![Omarchy plugin](https://img.shields.io/badge/Omarchy-4.0%2B-black)
[![CI](https://github.com/arorashu/dhwani-omarchy/actions/workflows/ci.yml/badge.svg)](https://github.com/arorashu/dhwani-omarchy/actions/workflows/ci.yml)

## The first cut

- one quiet bar icon
- one keyboard-first listening panel
- a short, de-duplicated feed from Dhwani
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
cp -a manifest.json BarWidget.qml Panel.qml Model.js play.py \
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

The defaults point to the isolated local API at `http://127.0.0.1:8791`. Omarchy's bar settings expose:

- `apiBase`
- `episodeLimit`
- `staleAfterSec` (the age that triggers a fetch when the panel opens)

The corresponding `shell.json` entry is plain data:

```json
{
  "id": "io.dhwani.listen",
  "apiBase": "http://127.0.0.1:8791",
  "episodeLimit": 7,
  "staleAfterSec": 300
}
```

## API contract

The plugin performs one anonymous request:

```http
GET /v1/foryou/all
Accept: application/json
```

It reads `daily_listen`, `picks`, `trending`, then category rows, in that order. A playable item needs only:

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
python3 tests/test_play.py
ruff check play.py tests/test_play.py
ruff format --check play.py tests/test_play.py
```

## Controls

- `super` + `ctrl` + `m`: open or close (when the optional binding above is installed)
- click: open or close
- right-click: refresh and open
- `↑` / `↓` or `j` / `k`: choose
- `←` or `h`: back 15 seconds
- `→` or `l`: forward 30 seconds
- `enter` or `space`: play an episode, or toggle play/pause on the current one
- click the progress bar: seek to a position
- `r`: refresh
- `escape`: close

## License

MIT
