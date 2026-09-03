#!/usr/bin/env python3
import fcntl
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse


def valid_url(value: str) -> bool:
    parsed = urlparse(value)
    return parsed.scheme in {"http", "https"} and bool(parsed.netloc)


def runtime_dir() -> Path:
    value = os.getenv("XDG_RUNTIME_DIR")
    if not value:
        raise OSError("XDG_RUNTIME_DIR is unavailable")
    path = Path(value)
    if not path.is_dir() or path.stat().st_uid != os.getuid():
        raise OSError("XDG_RUNTIME_DIR is not owned by this user")
    return path


def socket_path(runtime: Path | None = None) -> Path:
    return (runtime or runtime_dir()) / "dhwani-mpv.sock"


def connect(socket_file: Path) -> socket.socket | None:
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(1)
    try:
        client.connect(str(socket_file))
        return client
    except (ConnectionError, FileNotFoundError, socket.timeout):
        client.close()
        socket_file.unlink(missing_ok=True)
        return None


def request(client: socket.socket, replies, command: list, request_id: int) -> dict:
    try:
        payload = {"command": command, "request_id": request_id}
        client.sendall((json.dumps(payload) + "\n").encode())
        while line := replies.readline():
            response = json.loads(line)
            if response.get("request_id") == request_id:
                return response
    except (ConnectionError, json.JSONDecodeError, socket.timeout, OSError) as error:
        raise OSError("Dhwani player did not answer") from error
    raise OSError("Dhwani player did not answer")


def accepted(response: dict) -> None:
    if response.get("error") != "success":
        raise OSError(
            f"Dhwani player rejected the command: {response.get('error', 'unknown error')}"
        )


def load(socket_file: Path, url: str, title: str) -> bool:
    client = connect(socket_file)
    if client is None:
        return False
    with client, client.makefile() as replies:
        accepted(
            request(
                client,
                replies,
                ["loadfile", url, "replace", -1, {"force-media-title": title}],
                1,
            )
        )
        accepted(request(client, replies, ["set_property", "pause", False], 2))
    return True


def answers(socket_file: Path) -> bool:
    try:
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(0.2)
            client.connect(str(socket_file))
            with client.makefile() as replies:
                response = request(client, replies, ["get_property", "idle-active"], 1)
            return response.get("error") == "success"
    except OSError:
        return False


def mpv_command(socket_file: Path, url: str, title: str) -> list[str]:
    return [
        "mpv",
        "--no-video",
        "--audio-display=no",
        "--force-window=no",
        "--no-terminal",
        "--pause=no",
        f"--input-ipc-server={socket_file}",
        f"--force-media-title={title}",
        url,
    ]


def wait_until_owned(
    process: subprocess.Popen, socket_file: Path, timeout: float = 2
) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            socket_file.unlink(missing_ok=True)
            raise OSError("mpv could not start")
        if socket_file.exists() and answers(socket_file):
            return
        time.sleep(0.05)
    try:
        process.terminate()
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
    socket_file.unlink(missing_ok=True)
    raise OSError("mpv did not open its control socket")


def locked(runtime: Path):
    flags = os.O_CREAT | os.O_RDWR | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(runtime / "dhwani-mpv.lock", flags, 0o600)
    handle = os.fdopen(descriptor, "w")
    fcntl.flock(handle, fcntl.LOCK_EX)
    return handle


def play(url: str, title: str) -> None:
    if not valid_url(url):
        raise ValueError("Dhwani only opens HTTP audio URLs")
    title = " ".join(title.split())[:240] or "Dhwani"
    runtime = runtime_dir()
    ipc = socket_path(runtime)
    with locked(runtime):
        if ipc.exists() and load(ipc, url, title):
            return
        process = subprocess.Popen(
            mpv_command(ipc, url, title),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        wait_until_owned(process, ipc)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: play.py AUDIO_URL TITLE")
    try:
        play(sys.argv[1], sys.argv[2])
    except (OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
