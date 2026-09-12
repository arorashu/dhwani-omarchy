#!/usr/bin/env python3
"""Isolated mpv/MPRIS playback proof for the real ``play.py`` and ``Service.qml``.

The run snapshots a throwaway HOME/XDG sandbox and re-executes itself inside a
private ``dbus-run-session``: it generates WAV audio, serves it over loopback
HTTP, and drives the production helper through launch, reuse, Seek/SetPosition,
duplicate-title URL identity, a followed redirect, and an offscreen
``Service.qml`` reading the live MPRIS metadata. The user's mpv, session bus,
audio device, listening queue and state files are never touched.

Prerequisites (mpv, mpv-mpris, dbus, systemd busctl, quickshell) are hard
requirements: missing tools fail the proof instead of yielding a green skip.
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
# Two different HTTP WAVs published with the *same* human label: the exact shape
# of finding 2, used to prove MPRIS xesam:url is the real identity source.
TITLE_DUPE = "Episode Duplicate · Proof Show"
DURATION = 45
SAMPLE_RATE = 22050
MPRIS_SCRIPT_CANDIDATES = [
    Path("/etc/mpv/scripts/mpris.so"),
    Path("/usr/lib/mpv-mpris/mpris.so"),
    Path.home() / ".config/mpv/scripts/mpris.so",
]
STARTUP_TIMEOUT = 25
PROCESS_EXIT_TIMEOUT = 10
REQUIRED_TOOLS = ("mpv", "dbus-run-session", "busctl", "quickshell")


def log(message: str) -> None:
    print(f"[proof] {message}", flush=True)


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)
    log(f"ok: {message}")


def missing_prerequisites() -> list:
    missing = [tool for tool in REQUIRED_TOOLS if shutil.which(tool) is None]
    if not any(path.exists() for path in MPRIS_SCRIPT_CANDIDATES):
        missing.append("mpv-mpris mpris.so")
    return missing


def require_prerequisites() -> None:
    """Fail the proof when any prerequisite is absent; never a green skip."""
    missing = missing_prerequisites()
    if missing:
        raise SystemExit(
            f"playback proof failed: missing prerequisites: {', '.join(missing)}"
        )


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    """Loopback file server with byte-range support so mpv can seek."""

    def send_head(self):
        if self.path == "/redirect-episode-a.wav":
            # mpv (ffmpeg) follows the redirect; MPRIS must still report the URL
            # the helper was given, which is what Service.playerFor compares.
            self.send_response(302)
            self.send_header("Location", "/episode-a.wav")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return None
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


# Offscreen QML that drives the real Service.qml against the private mpv MPRIS
# bus: it reads xesam:url/trackTitle from the live player and reports how the
# product resolves identity. It is not a panel/GUI test.
QUICKSHELL_IDENTITY_QML = r"""
import QtQuick
import QtQuick.Window
import "__PLUGIN_URL__" as Dhwani

Window {
  id: root
  visible: false
  width: 8
  height: 8
  property int ticks: 0
  property var episodeA: ({ kind: "episode", episodeId: "A", podcastId: "abcdefghijklmnopqrst", title: "Episode Duplicate", podcastTitle: "Proof Show", audioUrl: "__URL_A__", duration: 45, position: 10 })
  property var episodeB: ({ kind: "episode", episodeId: "B", podcastId: "abcdefghijklmnopqrst", title: "Episode Duplicate", podcastTitle: "Proof Show", audioUrl: "__URL_B__", duration: 45, position: 20 })

  Dhwani.Service { id: service; apiBase: "" }

  function report() {
    var players = service.mprisPlayers
    var url = ""
    if (players.length && players[0].metadata)
      url = String(players[0].metadata["xesam:url"] || "")
    var current = service.findCurrentPlayback()
    console.log("SERVICE_IDENTITY:" + JSON.stringify({
      players: players.length,
      title: players.length ? String(players[0].trackTitle || "") : "",
      url: url,
      current: current ? current.episode.episodeId : null,
      playerForA: service.playerFor(root.episodeA) !== null,
      playerForB: service.playerFor(root.episodeB) !== null,
    }))
  }

  function setup() {
    service.trending = [root.episodeA]
    service.queue = [root.episodeB]
    identityTimer.start()
  }

  Connections {
    target: service
    function onStateReadyChanged() { if (service.stateReady) root.setup() }
  }

  Component.onCompleted: if (service.stateReady) root.setup()

  Timer {
    id: identityTimer
    interval: 250
    repeat: true
    onTriggered: {
      root.ticks += 1
      if (service.mprisPlayers.length && service.findCurrentPlayback()) {
        root.report()
        Qt.quit()
      } else if (root.ticks > 80) {
        root.report()
        Qt.quit()
      }
    }
  }
}
"""


def run_service_identity(
    root: Path, base: str, env: dict, expected_url: str, expected_id: str
) -> None:
    """Run the real Service offscreen against the live private mpv MPRIS bus."""
    qml = (
        QUICKSHELL_IDENTITY_QML.replace("__PLUGIN_URL__", ROOT.as_uri())
        .replace("__URL_A__", f"{base}/episode-a.wav")
        .replace("__URL_B__", f"{base}/episode-b.wav")
    )
    config = root / "service-identity.qml"
    config.write_text(qml, encoding="utf-8")
    qs_env = env.copy()
    qs_env.update(
        {
            "QT_QPA_PLATFORM": "offscreen",
            "QT_QUICK_BACKEND": "software",
            "QT_QPA_PLATFORMTHEME": "",
        }
    )
    for key in ("DISPLAY", "WAYLAND_DISPLAY"):
        qs_env.pop(key, None)
    result = subprocess.run(
        ["quickshell", "-p", str(config)],
        env=qs_env,
        cwd=str(root),
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=40,
        check=False,
    )
    logs = result.stdout + result.stderr
    line = next((row for row in logs.splitlines() if "SERVICE_IDENTITY:" in row), None)
    check(
        line is not None,
        f"offscreen Service consumed real MPRIS metadata (tail={logs[-300:]!r})",
    )
    report = json.loads(line.split("SERVICE_IDENTITY:", 1)[1])
    check(report["players"] >= 1, "offscreen Service saw the private mpv player")
    check(
        report["url"] == expected_url,
        f"offscreen Service read xesam:url {report['url']!r} == {expected_url!r}",
    )
    check(
        report["title"] == TITLE_DUPE,
        f"offscreen Service read the shared human label {report['title']!r}",
    )
    check(
        report["current"] == expected_id,
        f"offscreen Service resolved current episode {report['current']!r} to {expected_id}",
    )
    check(
        report["playerForA"] == (expected_id == "A"),
        "offscreen Service did not claim episode A by its shared label",
    )
    check(
        report["playerForB"] == (expected_id == "B"),
        "offscreen Service claimed episode B by its real URL",
    )


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


def wait_mpris_metadata(name: str, predicate, timeout: float = 10) -> dict:
    """Poll the live MPRIS Metadata map until it matches (mpv switches async)."""
    deadline = time.monotonic() + timeout
    last = {}
    while time.monotonic() < deadline:
        last = mpris_properties(name).get("Metadata") or {}
        if predicate(last):
            return last
        time.sleep(0.1)
    raise AssertionError(f"MPRIS metadata never matched (last={last!r})")


def mpris_call(name: str, method: str, signature: str, *args) -> None:
    busctl(
        "call",
        name,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        method,
        signature,
        *[str(arg) for arg in args],
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


def process_state(pid: int) -> str | None:
    """Return the Linux ``/proc/<pid>/stat`` state letter, or None if gone.

    ``comm`` is wrapped in parentheses and may itself contain spaces, so the
    state is read after the *last* ``)``.
    """
    try:
        stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    close = stat.rfind(")")
    if close == -1:
        return None
    fields = stat[close + 1 :].split()
    return fields[0] if fields else None


def alive(pid: int) -> bool:
    """True only while ``pid`` is live. Linux-only: ``/proc`` state is authoritative.

    An unreaped, exited child stays a zombie and ``os.kill(pid, 0)`` still
    succeeds for it, which is not evidence of a running player. Only ``Z`` and
    ``X``/``x`` count as not alive; every other state (including stopped) is live.
    """
    state = process_state(pid)
    return state is not None and state not in {"Z", "X", "x"}


def liveness_regression() -> None:
    """An unreaped exited child is a zombie, not a live process.

    Forks a short-lived child and deliberately does not reap it, exactly like a
    detached mpv under a non-reaping container PID 1.
    """
    pid = os.fork()
    if pid == 0:  # pragma: no cover - runs in the forked child
        time.sleep(0.5)
        os._exit(0)
    try:
        check(alive(pid), f"regression: child pid {pid} is live before it exits")
        deadline = time.monotonic() + PROCESS_EXIT_TIMEOUT
        while time.monotonic() < deadline and process_state(pid) != "Z":
            time.sleep(0.02)
        check(
            process_state(pid) == "Z",
            f"regression: child pid {pid} is an unreaped zombie",
        )
        check(not alive(pid), f"regression: zombie pid {pid} is not alive")
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            raise AssertionError(
                f"regression: os.kill({pid}, 0) should still succeed for a zombie"
            ) from None
    finally:
        os.waitpid(pid, 0)
    check(not alive(pid), f"regression: reaped child pid {pid} is not alive")
    log("regression: live/zombie/reaped liveness distinction holds")


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

        name = mpris_name()
        props = mpris_properties(name)
        check(props.get("PlaybackStatus") == "Playing", "MPRIS reports Playing")
        metadata = props.get("Metadata") or {}
        log(f"MPRIS metadata (launch): {json.dumps(metadata, default=str)}")
        check(metadata.get("xesam:title") == TITLE_A, "MPRIS xesam:title matches")
        check(
            metadata.get("xesam:url") == f"{base}/episode-a.wav",
            "MPRIS xesam:url identifies the launched track",
        )
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
        time.sleep(0.3)
        metadata = mpris_properties(name).get("Metadata") or {}
        check(metadata.get("xesam:title") == TITLE_B, "MPRIS title followed the switch")
        check(
            metadata.get("xesam:url") == f"{base}/episode-b.wav",
            "MPRIS xesam:url followed the switch",
        )
        track_id = metadata.get("mpris:trackid")
        check(bool(track_id), "MPRIS exposes mpris:trackid")
        mpris_call(name, "Seek", "x", 5_000_000)
        after_seek = float(
            wait_property(socket_file, "playback-time", lambda value: value >= 5)
        )
        check(
            5 <= after_seek < 9, f"MPRIS Seek moved playback-time to {after_seek:.2f}s"
        )
        mpris_call(name, "SetPosition", "ox", track_id, 12_000_000)
        after_set = float(
            wait_property(socket_file, "playback-time", lambda value: value >= 11.5)
        )
        check(
            11.5 <= after_set < 15,
            f"MPRIS SetPosition moved playback-time to {after_set:.2f}s",
        )

        # Same human label, two HTTP WAVs: the live metadata URL is the only
        # thing that distinguishes them across a real mpv reuse.
        launch(PLAY, f"{base}/episode-a.wav", TITLE_DUPE, env)
        dupe_a = wait_mpris_metadata(
            name, lambda m: m.get("xesam:url") == f"{base}/episode-a.wav"
        )
        check(
            dupe_a.get("xesam:title") == TITLE_DUPE,
            "duplicate A carries the shared human title",
        )
        launch(PLAY, f"{base}/episode-b.wav", TITLE_DUPE, env)
        dupe_b = wait_mpris_metadata(
            name, lambda m: m.get("xesam:url") == f"{base}/episode-b.wav"
        )
        check(
            dupe_b.get("xesam:title") == TITLE_DUPE,
            "duplicate B carries the same shared human title",
        )

        # The real Service.qml reads this live bus offscreen and resolves B by URL.
        run_service_identity(root, base, env, f"{base}/episode-b.wav", "B")

        # A followed redirect still exposes the requested URL (mpv's path), so
        # exact URL matching needs no speculative normalization.
        launch(PLAY, f"{base}/redirect-episode-a.wav", TITLE_DUPE, env)
        redirected = wait_mpris_metadata(
            name,
            lambda m: str(m.get("xesam:url", "")).endswith("redirect-episode-a.wav"),
        )
        check(
            redirected.get("xesam:url") == f"{base}/redirect-episode-a.wav",
            "a followed redirect still reports the requested URL",
        )

        close_process(pid, socket_file)
        check(not alive(pid), f"mpv pid {pid} was cleaned up")
        pid = None
        return 0
    finally:
        if pid is not None:
            close_process(pid, socket_file)


def parent_main() -> int:
    require_prerequisites()
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
    if args:
        raise SystemExit(f"unexpected arguments: {' '.join(args)}")
    liveness_regression()
    return parent_main()


if __name__ == "__main__":
    raise SystemExit(main())
