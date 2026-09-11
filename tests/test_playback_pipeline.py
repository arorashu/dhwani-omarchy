#!/usr/bin/env python3
"""Isolated end-to-end mpv/MPRIS playback proof for ``play.py``.

Direct run (``python3 tests/test_playback_pipeline.py``) snapshots a throwaway
HOME/XDG sandbox and re-executes itself inside a private ``dbus-run-session``.
Inside that sandbox it generates WAV audio, serves it over loopback HTTP, and
drives the real production helper ``play.py``:

* launch: mpv starts, IPC reports playing audio with the requested title;
* reuse: a second ``play.py`` call keeps the same mpv pid and switches tracks;
* MPRIS: the private bus exposes the title/position and honours Seek/SetPosition
  (the path ``Service.qml`` uses for ``seekBy``/``seekTo``).

The user's mpv, session bus, audio device, listening queue and state files are
never touched. Every child is bounded and the task-owned mpv is always asked to
quit over its own IPC socket.

Missing tools must never yield a green "proof passed". A standalone developer
run prints a clear SKIP and exits 0; CI passes ``--strict`` (or sets
``DHWANI_PROOF_STRICT=1``) so the mpv/MPRIS prerequisites are hard requirements.
"""

import functools
import http.server
import io
import json
import math
import os
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLAY = ROOT / "play.py"
TITLE_A = "Episode Alpha · Proof Show"
# Exactly 240 Unicode code points with an emoji near the cap: this is the shape
# of label Model.js now produces for a long title, and the label mpv/MPRIS must
# report verbatim (play.py's cap must be a no-op on it).
TITLE_B = "Episode Beta " + "x" * 212 + " 🙂 · Proof Show"
assert len(TITLE_B) == 240, len(TITLE_B)
DURATION = 45
SAMPLE_RATE = 22050
MPRIS_SCRIPT_CANDIDATES = [
    Path("/etc/mpv/scripts/mpris.so"),
    Path("/usr/lib/mpv-mpris/mpris.so"),
    Path.home() / ".config/mpv/scripts/mpris.so",
]
STARTUP_TIMEOUT = 25
PROCESS_EXIT_TIMEOUT = 10
STRICT_ENV = "DHWANI_PROOF_STRICT"
REQUIRED_TOOLS = ("mpv", "dbus-run-session", "busctl")


def log(message: str) -> None:
    print(f"[proof] {message}", flush=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    log(f"ok: {message}")


def strict_mode() -> bool:
    """CI proof mode: missing prerequisites fail instead of skipping."""
    return os.environ.get(STRICT_ENV) == "1"


def missing_prerequisites() -> list:
    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if not any(path.exists() for path in MPRIS_SCRIPT_CANDIDATES):
        missing.append("mpv-mpris mpris.so")
    return missing


def require_prerequisites() -> bool:
    """Return True when the proof can run; False only for a labelled dev skip."""
    missing = missing_prerequisites()
    if not missing:
        return True
    reason = f"missing playback proof prerequisites: {', '.join(missing)}"
    if strict_mode():
        raise SystemExit(f"playback proof failed: {reason}")
    print(f"SKIP: {reason}")
    print(
        "Developer note: install mpv, mpv-mpris, dbus and systemd (busctl) for "
        f"the full proof, or set {STRICT_ENV}=1 to make missing tools a failure."
    )
    return False


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    """Loopback file server with byte-range support so mpv can seek."""

    def send_head(self):
        path = self.translate_path(self.path)
        if not os.path.isfile(path):
            return super().send_head()
        size = os.path.getsize(path)
        start, end = 0, size - 1
        header = self.headers.get("Range", "")
        if header.startswith("bytes="):
            first, _, last = header[len("bytes=") :].partition("-")
            try:
                start = int(first) if first else 0
                end = int(last) if last else size - 1
            except ValueError:
                start, end = 0, size - 1
            start = max(0, min(start, size - 1))
            end = max(start, min(end, size - 1))
        payload = io.BytesIO()
        with open(path, "rb") as source:
            source.seek(start)
            payload.write(source.read(end - start + 1))
        payload.seek(0)
        partial = start != 0 or end != size - 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", "audio/wav")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        return payload

    def log_message(self, *args):  # keep the proof output clean
        pass


def make_wav(path: Path, frequency: int) -> None:
    with wave.open(str(path), "wb") as audio:
        audio.setnchannels(1)
        audio.setsampwidth(2)
        audio.setframerate(SAMPLE_RATE)
        frames = bytearray()
        for index in range(DURATION * SAMPLE_RATE):
            value = int(6000 * math.sin(2 * math.pi * frequency * index / SAMPLE_RATE))
            frames += struct.pack("<h", value)
        audio.writeframes(bytes(frames))


def serve_audio(root: Path) -> str:
    handler = functools.partial(RangeHandler, directory=str(root))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


def ipc(socket_file: Path, command: list, timeout: float = 5):
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(timeout)
    client.connect(str(socket_file))
    with client, client.makefile() as replies:
        request_id = 1
        client.sendall(
            (json.dumps({"command": command, "request_id": request_id}) + "\n").encode()
        )
        while line := replies.readline():
            response = json.loads(line)
            if response.get("request_id") != request_id:
                continue
            if response.get("error") != "success":
                raise AssertionError(f"mpv rejected {command}: {response}")
            return response.get("data")
    raise AssertionError(f"mpv gave no reply to {command}")


def ipc_value(socket_file: Path, name: str, timeout: float = 5):
    return ipc(socket_file, ["get_property", name], timeout=timeout)


def wait_property(
    socket_file: Path, name: str, predicate=None, timeout: float = STARTUP_TIMEOUT
):
    """Poll a property until the demuxer exposes it (mpv loads the file async)."""
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        try:
            last = ipc_value(socket_file, name)
        except (AssertionError, OSError):
            time.sleep(0.1)
            continue
        if predicate is None or predicate(last):
            return last
        time.sleep(0.1)
    raise AssertionError(f"{name} never became usable (last={last!r})")


def launch(helper: Path, url: str, title: str, env: dict) -> None:
    result = subprocess.run(
        [sys.executable, str(helper), url, title],
        env=env,
        capture_output=True,
        check=False,
        text=True,
        timeout=30,
    )
    output = (result.stdout + result.stderr).strip()
    check(result.returncode == 0, f"play.py started {title!r} (output={output!r})")


def busctl(*args: str, timeout: float = 5):
    out = subprocess.check_output(
        ["busctl", "--user", "--json=short", *args], text=True, timeout=timeout
    ).strip()
    return json.loads(out) if out else None


def busctl_value(payload):
    """Recursively unwrap busctl's {"type", "data"} variant envelopes."""
    if isinstance(payload, dict) and set(payload) == {"type", "data"}:
        return busctl_value(payload["data"])
    if isinstance(payload, list):
        return [busctl_value(item) for item in payload]
    if isinstance(payload, dict):
        return {key: busctl_value(value) for key, value in payload.items()}
    return payload


def mpris_name() -> str:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        names = busctl_value(busctl("list"))
        for entry in names:
            name = entry.get("name", "") if isinstance(entry, dict) else ""
            if name.startswith("org.mpris.MediaPlayer2.mpv"):
                return name
        time.sleep(0.2)
    raise AssertionError("no mpv MPRIS name appeared on the private bus")


def mpris_properties(name: str) -> dict:
    payload = busctl(
        "call",
        name,
        "/org/mpris/MediaPlayer2",
        "org.freedesktop.DBus.Properties",
        "GetAll",
        "s",
        "org.mpris.MediaPlayer2.Player",
    )
    raw = busctl_value(payload)
    if isinstance(raw, list):
        raw = raw[0] if raw else {}
    return raw


def mpris_seek(name: str, offset_us: int) -> None:
    busctl(
        "call",
        name,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        "Seek",
        "x",
        str(offset_us),
    )


def mpris_set_position(name: str, track_id: str, position_us: int) -> None:
    busctl(
        "call",
        name,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        "SetPosition",
        "ox",
        track_id,
        str(position_us),
    )


def close_process(pid: int, socket_file: Path) -> None:
    if socket_file.exists():
        try:
            ipc(socket_file, ["quit"], timeout=2)
        except (AssertionError, OSError, ValueError):
            pass
    deadline = time.monotonic() + PROCESS_EXIT_TIMEOUT
    while time.monotonic() < deadline:
        if not alive(pid):
            log(f"cleanup: mpv pid {pid} exited after IPC quit")
            return
        time.sleep(0.1)
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    log(f"cleanup: sent SIGTERM to exact pid {pid}")
    time.sleep(1)
    if alive(pid):
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        log(f"cleanup: sent SIGKILL to exact pid {pid}")


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def child_main(root: Path) -> int:
    runtime = Path(os.environ["XDG_RUNTIME_DIR"])
    audio_dir = root / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    make_wav(audio_dir / "episode-a.wav", 440)
    make_wav(audio_dir / "episode-b.wav", 660)
    base = serve_audio(audio_dir)
    socket_file = runtime / "dhwani-mpv.sock"
    env = os.environ.copy()
    pid = None
    log(f"sandbox root={root} runtime={runtime} audio={base}")
    try:
        launch(PLAY, f"{base}/episode-a.wav", TITLE_A, env)
        deadline = time.monotonic() + STARTUP_TIMEOUT
        while time.monotonic() < deadline and not socket_file.exists():
            time.sleep(0.1)
        check(
            socket_file.exists(),
            "play.py opened its IPC socket under the sandbox runtime",
        )
        pid = int(wait_property(socket_file, "pid"))
        check(alive(pid), f"mpv pid {pid} is running")

        check(ipc_value(socket_file, "idle-active") is False, "mpv is not idle")
        check(ipc_value(socket_file, "pause") is False, "mpv is unpaused")
        check(
            ipc_value(socket_file, "force-media-title") == TITLE_A,
            "force-media-title carries the requested episode title",
        )
        duration = float(wait_property(socket_file, "duration"))
        check(
            abs(duration - DURATION) < 1.5,
            f"mpv duration {duration:.2f}s matches the WAV",
        )
        check(
            wait_property(socket_file, "seekable") is True,
            "mpv reports the stream seekable",
        )

        missing = missing_prerequisites()
        if missing:
            reason = f"missing playback proof prerequisites: {', '.join(missing)}"
            if strict_mode():
                raise AssertionError(reason)
            log(f"skip: {reason}; MPRIS assertions skipped")
        mpris_available = not missing
        name = ""
        if mpris_available:
            name = mpris_name()
            props = mpris_properties(name)
            check(props.get("PlaybackStatus") == "Playing", "MPRIS reports Playing")
            metadata = props.get("Metadata") or {}
            log(f"MPRIS metadata (launch): {json.dumps(metadata, default=str)}")
            check(metadata.get("xesam:title") == TITLE_A, "MPRIS xesam:title matches")
            length_us = int(metadata.get("mpris:length", 0))
            check(
                abs(length_us / 1_000_000 - DURATION) < 1.5,
                f"MPRIS mpris:length {length_us}us matches the WAV",
            )
            check(props.get("CanSeek") is True, "MPRIS CanSeek is true")

        position = float(wait_property(socket_file, "playback-time"))
        check(position >= 0, f"playback-time reported ({position:.2f}s)")

        launch(PLAY, f"{base}/episode-b.wav", TITLE_B, env)
        check(int(ipc_value(socket_file, "pid")) == pid, "reuse kept the same mpv pid")
        check(
            ipc_value(socket_file, "force-media-title") == TITLE_B,
            "reuse switched the media title",
        )
        switched = float(
            wait_property(socket_file, "playback-time", lambda value: value < 5)
        )
        check(switched < 5, f"reuse restarted near the beginning ({switched:.2f}s)")
        if mpris_available:
            time.sleep(0.3)
            metadata = mpris_properties(name).get("Metadata") or {}
            check(
                metadata.get("xesam:title") == TITLE_B,
                "MPRIS title followed the switch",
            )
            track_id = metadata.get("mpris:trackid")
            check(bool(track_id), "MPRIS exposes mpris:trackid")
            mpris_seek(name, 5_000_000)
            after_seek = float(
                wait_property(socket_file, "playback-time", lambda value: value >= 5)
            )
            check(
                5 <= after_seek < 9,
                f"MPRIS Seek moved playback-time to {after_seek:.2f}s",
            )
            mpris_set_position(name, track_id, 12_000_000)
            after_set = float(
                wait_property(socket_file, "playback-time", lambda value: value >= 11.5)
            )
            check(
                11.5 <= after_set < 15,
                f"MPRIS SetPosition moved playback-time to {after_set:.2f}s",
            )

        close_process(pid, socket_file)
        check(not alive(pid), f"mpv pid {pid} was cleaned up")
        pid = None
        return 0
    finally:
        if pid is not None:
            close_process(pid, socket_file)


def parent_main() -> int:
    if not require_prerequisites():
        return 0
    root = Path(tempfile.mkdtemp(prefix="dhwani-playback-"))
    (root / "home").mkdir()
    runtime = root / "run"
    runtime.mkdir(mode=0o700)
    env = {
        key: value
        for key, value in os.environ.items()
        if key not in {"DBUS_SESSION_BUS_ADDRESS", "DISPLAY", "WAYLAND_DISPLAY"}
    }
    env.update(
        {
            "HOME": str(root / "home"),
            "XDG_CONFIG_HOME": str(root / "home/.config"),
            "XDG_CACHE_HOME": str(root / "home/.cache"),
            "XDG_DATA_HOME": str(root / "home/.local/share"),
            "XDG_STATE_HOME": str(root / "home/.local/state"),
            "XDG_RUNTIME_DIR": str(runtime),
        }
    )
    mpv_config = root / "home/.config/mpv"
    mpv_config.mkdir(parents=True)
    (mpv_config / "mpv.conf").write_text(
        "ao=null\nvo=null\nno-video\naudio-display=no\nforce-window=no\n",
        encoding="utf-8",
    )
    command = [
        "dbus-run-session",
        "--",
        sys.executable,
        str(Path(__file__).resolve()),
        "--child",
        str(root),
    ]
    try:
        result = subprocess.run(
            command, env=env, capture_output=True, check=False, text=True, timeout=120
        )
    finally:
        shutil.rmtree(root, ignore_errors=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode != 0:
        raise SystemExit(f"playback proof failed (exit {result.returncode})")
    print("Playback pipeline proof passed")
    return 0


def main() -> int:
    args = sys.argv[1:]
    if args and args[0] == "--child":
        if len(args) != 2:
            raise SystemExit("--child requires a sandbox root")
        return child_main(Path(args[1]))
    if "--strict" in args:
        os.environ[STRICT_ENV] = "1"
    return parent_main()


if __name__ == "__main__":
    raise SystemExit(main())
