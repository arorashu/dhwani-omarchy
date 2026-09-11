"""Exercise the real QML service: HTTP queue, search state, images, and FileView."""

import json
import os
import struct
import subprocess
import tempfile
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
IDS = ("BgvRZTg8v9GYMpbxcvFk", "XgosndFz4gzOM4oHrfYI")
SEARCH_SHOW = "9QqWbjH5mqlrsiaHMba1"


def image_png():
    def chunk(kind, data):
        return (
            struct.pack("!I", len(data))
            + kind
            + data
            + struct.pack("!I", zlib.crc32(kind + data))
        )

    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack("!2I5B", 1, 1, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(b"\x00\xff\x00\x00"))
        + chunk(b"IEND", b"")
    )


def offscreen_env(folder: Path) -> dict:
    runtime = folder / "runtime"
    runtime.mkdir(mode=0o700, exist_ok=True)
    env = dict(
        os.environ,
        QT_QPA_PLATFORM="offscreen",
        QT_QPA_PLATFORMTHEME="",
        QT_QUICK_BACKEND="software",
        XDG_STATE_HOME=str(folder / "state"),
        XDG_CACHE_HOME=str(folder / "cache"),
        XDG_RUNTIME_DIR=str(runtime),
    )
    for key in ("WAYLAND_DISPLAY", "DISPLAY"):
        env.pop(key, None)
    return env


def run_quickshell(
    folder: Path, qml: str, base: str
) -> tuple[str, subprocess.CompletedProcess]:
    qml = qml.replace("PLUGIN_URL", ROOT.as_uri()).replace("API_BASE", base)
    config = folder / "shell.qml"
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(qml)
    result = subprocess.run(
        ["dbus-run-session", "--", "quickshell", "-p", str(config)],
        env=offscreen_env(folder),
        cwd=folder,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=False,
        text=True,
        timeout=40,
    )
    return result.stdout + result.stderr, result


def test_artwork_runtime(folder):
    lookups = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            if self.path == "/artwork.png":
                data, mime = image_png(), "image/png"
            elif self.path.startswith("/v1/podcasts/"):
                podcast_id = self.path.split("?")[0].rsplit("/", 1)[1]
                if podcast_id not in IDS:
                    self.send_error(404)
                    return
                lookups.append(self.path)
                data = json.dumps(
                    {
                        "podcast": {
                            "podcast_id": podcast_id,
                            "title": "Fixture show",
                            "artwork_url": f"{base}/artwork.png",
                        },
                        "episodes": [
                            {
                                "episode_id": "abcdefghij",
                                "title": "Incidental episode",
                                "media_options": [{"path": f"{base}/audio.mp3"}],
                            }
                        ],
                        "total_episodes": 80,
                    }
                ).encode()
                mime = "application/json"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    base = f"http://127.0.0.1:{server.server_port}"
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        rows = [
            {"kind": "episode", "podcastId": podcast_id, "artworkUrl": ""}
            for podcast_id in (IDS[0], IDS[0], IDS[1])
        ]
        template = (ROOT / "tests/fixtures/artwork-runtime.qml").read_text()
        template = template.replace("EPISODE_ROWS", json.dumps(rows))
        logs, result = run_quickshell(folder, template, base)
        assert result.returncode == 0, logs
        assert "ARTWORK_READY:3" in logs, logs
        assert sorted(lookups) == sorted(
            f"/v1/podcasts/{podcast_id}?limit=1&offset=0" for podcast_id in IDS
        ), (lookups, logs)
        state = json.loads((folder / "state/dhwani-omarchy/state.json").read_text())
        for podcast_id in IDS:
            record = state["cache"]["showsById"][podcast_id]
            assert record["artworkUrl"] == f"{base}/artwork.png"
            assert record["episodes"] == []
            assert record["fetchedAt"] == 0
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


def test_hydration_runtime(folder):
    state_dir = folder / "state" / "dhwani-omarchy"
    state_dir.mkdir(parents=True, exist_ok=True)
    rss_row = {
        "kind": "episode",
        "episodeId": "cached-rss",
        "podcastId": SEARCH_SHOW,
        "title": "Cached RSS",
        "podcastTitle": "Founders",
        "artworkUrl": "https://example.test/founders.png",
        "audioUrl": "https://example.test/cached.mp3",
        "duration": 600,
        "position": 12,
        "publication_date": "2025-01-02T03:04:05+00:00",
    }
    youtube_row = {
        "kind": "episode",
        "episodeId": "cached-yt",
        "podcastId": SEARCH_SHOW,
        "title": "Cached YouTube",
        "podcastTitle": "Founders",
        "audioUrl": "https://www.youtube.com/watch?v=abc",
        "position": 4,
    }
    (state_dir / "state.json").write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "queue": [rss_row, youtube_row],
                "nav": {},
                "cache": {
                    "trending": {"fetchedAt": 111, "episodes": [rss_row, youtube_row]},
                    "shows": {
                        "fetchedAt": 222,
                        "items": [
                            {
                                "kind": "show",
                                "podcastId": SEARCH_SHOW,
                                "title": "Founders",
                                "artworkUrl": "https://example.test/founders.png",
                                "episodeCount": 88,
                            }
                        ],
                        "total": 88,
                        "nextOffset": 20,
                    },
                    "showsById": {
                        SEARCH_SHOW: {
                            "title": "Founders",
                            "artworkUrl": "https://example.test/founders.png",
                            "fetchedAt": 333,
                            "total": 88,
                            "nextOffset": 20,
                            "episodes": [youtube_row, rss_row],
                        }
                    },
                },
            }
        )
    )
    logs, result = run_quickshell(
        folder,
        (ROOT / "tests/fixtures/hydration-runtime.qml").read_text(),
        "http://127.0.0.1:1",
    )
    assert result.returncode == 0, logs
    line = next((row for row in logs.splitlines() if "HYDRATION:" in row), None)
    assert line, logs
    report = json.loads(line.split("HYDRATION:", 1)[1])
    assert report["trending"] == 1, report
    assert report["trendingPosition"] == 12, report
    assert report["trendingPublished"] == "2025-01-02T03:04:05+00:00", report
    assert report["showEpisodes"] == 1, report
    assert report["showEpisodeId"] == "cached-rss", report
    assert report["showNextOffset"] == 20, report
    assert report["showTotal"] == 88, report
    assert report["showArtwork"] == "https://example.test/founders.png", report
    assert report["showFetchedAt"] == 333, report
    assert report["showsNextOffset"] == 20, report
    assert report["showsTotal"] == 88, report
    assert report["showsItems"] == 1, report
    assert report["queue"] == 1, report


def search_page(base: str, query: str, kind: str, offset: int, podcast_id: str):
    if query == "stale":
        time.sleep(1.2)
        count, total, title = 20, 99, "STALE episode"
    elif kind == "shows":
        return {
            "query": query,
            "kind": "shows",
            "limit": 20,
            "offset": offset,
            "total": 1,
            "podcasts": [
                {
                    "podcast_id": SEARCH_SHOW,
                    "title": "Alpha Show",
                    "artwork_url": f"{base}/artwork.png",
                    "episode_count": 12,
                }
            ],
            "episodes": [],
        }
    elif podcast_id:
        count, total, title = 3, 3, "Alpha scoped"
    else:
        count, total, title = min(20, max(0, 41 - offset)), 41, "Alpha"
    episodes = [
        {
            "video_id": f"{title.replace(' ', '')}{offset + index}",
            "podcast_id": SEARCH_SHOW,
            "title": f"{title} {offset + index}",
            "podcast_title": "Alpha Show",
            "duration": 600,
            "publication_date": "2025-01-01T00:00:00+00:00",
            "media_options": [
                {"is_primary": True, "source_type": "RSS", "path": f"{base}/audio.mp3"}
            ],
            "artwork_url": "",
            "podcast_artwork_url": f"{base}/artwork.png",
        }
        for index in range(count)
    ]
    return {
        "query": query,
        "kind": kind,
        "limit": 20,
        "offset": offset,
        "total": total,
        "podcast_id": podcast_id or None,
        "podcasts": [],
        "episodes": episodes,
    }


def test_search_runtime(folder):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            if self.path == "/artwork.png":
                data, mime = image_png(), "image/png"
            elif self.path.startswith("/v1/search/titles"):
                parsed = urlparse(self.path)
                query = parse_qs(parsed.query)
                requests.append(self.path)
                payload = search_page(
                    base,
                    query.get("q", [""])[0],
                    query.get("kind", ["episodes"])[0],
                    int(query.get("offset", ["0"])[0]),
                    query.get("podcast_id", [""])[0],
                )
                data, mime = json.dumps(payload).encode(), "application/json"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    base = f"http://127.0.0.1:{server.server_port}"
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        logs, result = run_quickshell(
            folder, (ROOT / "tests/fixtures/search-runtime.qml").read_text(), base
        )
        assert result.returncode == 0, logs

        def report(label: str) -> dict:
            prefix = f"SEARCH_{label}:"
            line = next((row for row in logs.splitlines() if prefix in row), None)
            assert line, (label, logs)
            return json.loads(line.split(prefix, 1)[1])

        alpha = report("ALPHA")
        assert alpha["query"] == "alpha", alpha
        assert alpha["kind"] == "episodes"
        assert alpha["episodes"] == 20, alpha
        assert alpha["total"] == 41, alpha
        assert alpha["next"] == 20, alpha
        assert alpha["stale"] == 0, alpha
        assert alpha["error"] == "", alpha

        paged = report("PAGED")
        assert paged["episodes"] == 40, paged
        assert paged["next"] == 40, paged
        assert paged["stale"] == 0, paged

        scoped = report("SCOPED")
        assert scoped["episodes"] == 3, scoped
        assert scoped["total"] == 3, scoped
        assert scoped["stale"] == 0, scoped

        shows = report("SHOWS")
        assert shows["kind"] == "shows", shows
        assert shows["shows"] == 1, shows
        assert shows["episodes"] == 0, shows
        assert shows["total"] == 1, shows

        assert "SEARCH_IMAGE:true" in logs, logs
        # The slow first query must have been issued and then superseded.
        assert requests[0].startswith("/v1/search/titles?q=stale"), requests
        assert any("q=alpha" in path and "offset=0" in path for path in requests), (
            requests
        )
        assert any("q=alpha" in path and "offset=20" in path for path in requests), (
            requests
        )
        assert any(
            "q=alpha" in path and f"podcast_id={SEARCH_SHOW}" in path
            for path in requests
        ), requests
        assert any("kind=shows" in path for path in requests), requests
        assert not any(
            "q=stale" in path and "offset=20" in path for path in requests
        ), requests
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=5)


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="dhwani-qml-test-") as directory:
        root = Path(directory)
        test_artwork_runtime(root / "artwork")
        test_hydration_runtime(root / "hydration")
        test_search_runtime(root / "search")
    print(
        "QML runtime tests passed: artwork resolution, state hydration, and search state"
    )
