"""Exercise the real QML artwork service, HTTP queue, images, and FileView."""

import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import zlib

ROOT = Path(__file__).resolve().parents[1]
IDS = ("BgvRZTg8v9GYMpbxcvFk", "XgosndFz4gzOM4oHrfYI")


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
        qml = (ROOT / "tests/fixtures/artwork-runtime.qml").read_text()
        qml = qml.replace("PLUGIN_URL", ROOT.as_uri())
        qml = qml.replace("API_BASE", base).replace("EPISODE_ROWS", json.dumps(rows))
        config = folder / "shell.qml"
        config.write_text(qml)
        runtime = folder / "runtime"
        runtime.mkdir(mode=0o700)
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
        result = subprocess.run(
            ["dbus-run-session", "--", "quickshell", "-p", str(config)],
            env=env,
            cwd=folder,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=25,
        )
        logs = result.stdout + result.stderr
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


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="dhwani-qml-test-") as directory:
        test_artwork_runtime(Path(directory))
    print("QML runtime test passed: three images, two lookups, persisted artwork")
