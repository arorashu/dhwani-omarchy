# Dhwani for Omarchy

A keyboard-first podcast panel for Omarchy. Browse Dhwani's anonymous RSS catalog, find episodes or shows by title, and listen through the desktop's native media controls.

![Omarchy plugin](https://img.shields.io/badge/Omarchy-4.0%2B-black)
[![CI](https://github.com/arorashu/dhwani-omarchy/actions/workflows/ci.yml/badge.svg)](https://github.com/arorashu/dhwani-omarchy/actions/workflows/ci.yml)

## Features

- Trending episodes, listening queue, and paginated show catalog
- Case-insensitive title search for episodes and shows
- Optional episode search within one show
- RSS audio playback through a dedicated `mpv` instance
- Play, pause, seek, and progress through Omarchy's MPRIS media surface
- Saved listening positions and local queue state
- Episode artwork with a cached show-artwork fallback
- Native Omarchy theme, typography, spacing, and panel behavior

Dhwani intentionally has no account screen, transcript reader, or second media player. It provides a small listening doorway and lets Omarchy handle playback controls.

## Requirements

- Omarchy 4.0 or newer
- `curl`
- Python 3.10 or newer
- `mpv`
- `mpv-mpris`

Current Omarchy installations include the media components. Community plugins run unsandboxed, so review the seven installed files before enabling the plugin.

## Install

```bash
omarchy plugin add https://github.com/arorashu/dhwani-omarchy.git --enable
```

Enable Omarchy's media widget if it is not already in the bar:

```bash
omarchy plugin enable omarchy.media --section center --after io.dhwani.listen
```

Update or remove the plugin:

```bash
omarchy plugin update io.dhwani.listen
omarchy plugin remove io.dhwani.listen
```

### Optional keyboard shortcut

Add this to `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + CTRL + M", "Dhwani", "omarchy-shell shell toggle io.dhwani.listen")
```

Check that the chord is available with `omarchy menu keybindings --print`, then run `hyprctl reload`.

## Use

Open Dhwani from its bar icon. Press `/` to search; search starts in **Episodes** mode, and `Tab` switches between **Episodes** and **Shows**.

| Input | Action |
| --- | --- |
| `←` / `→` | Switch Trending, Queue, and All Shows |
| `/` | Open title search |
| `Tab` | Switch episode/show search mode |
| `Esc` | Clear show scope, leave search, go back, or close |
| `↑` / `↓` or `j` / `k` | Move selection |
| `Enter` | Open a show, play an episode, or toggle the selected episode |
| `Space` | Play or pause the current episode |
| `h` / `l` | Seek back 15 seconds or forward 30 seconds |
| `r` | Refresh the current remote list |
| Progress bar | Seek within the current episode |
| Right-click bar icon | Refresh and open |

Playback continues after the panel closes. Pause it from Dhwani or any MPRIS client; stop it through MPRIS before disabling or removing the plugin.

## Configure

The bar settings expose:

- `apiBase` — Dhwani API URL; defaults to `https://api-v1.dhwani.io`
- `episodeLimit` — initial trending item count; defaults to 10
- `staleAfterSec` — client cache lifetime; defaults to 600 seconds

Example `shell.json` entry:

```json
{
  "id": "io.dhwani.listen",
  "apiBase": "https://api-v1.dhwani.io",
  "episodeLimit": 10,
  "staleAfterSec": 600
}
```

Queue, navigation cache, and listening positions are stored locally in:

```text
~/.local/state/dhwani-omarchy/state.json
```

Dhwani restricts that directory to the current user (`0700`) and the state file to owner read/write (`0600`) before loading or saving it.

## Privacy and API use

Dhwani works without a login. Requests identify the plugin version for server diagnostics:

```http
Origin: https://podcast.dhwani.io
User-Agent: Dhwani-Omarchy/0.2.0 (+https://github.com/arorashu/dhwani-omarchy)
```

The plugin sends no account, installation identifier, or playback telemetry. API requests cover the anonymous feed, show catalog, show episodes, and title search. Artwork and audio are fetched from the URLs supplied by the catalog.

Only HTTP(S) non-YouTube audio sources are accepted. API responses are capped at 1 MiB.

## Local development

Install a local checkout by copying the seven plugin files:

```bash
omarchy plugin validate .
mkdir -p ~/.config/omarchy/plugins/io.dhwani.listen
cp -a manifest.json BarWidget.qml Panel.qml Service.qml Model.js play.py state_storage.py \
  ~/.config/omarchy/plugins/io.dhwani.listen/
omarchy-shell shell rescanPlugins
omarchy plugin enable io.dhwani.listen --section center
```

Saved plugin files reload automatically. If compiled QML remains stale, let the watcher settle before running `omarchy restart shell`; do not chain copying directly into a restart on Quickshell 0.3.1 ([Quickshell #956](https://github.com/quickshell-mirror/quickshell/issues/956)).

See [CONTRIBUTING.md](CONTRIBUTING.md) for validation and test commands. The suite distinguishes mocked JavaScript extracted from QML, real offscreen QML persistence, and isolated mpv/MPRIS playback. There is not yet a complete panel-driven playback E2E test.

## Security

See [SECURITY.md](SECURITY.md) to report vulnerabilities privately. Omarchy plugins execute as unsandboxed user code; marketplace validation is not a security guarantee.

## License

[MIT](LICENSE)
