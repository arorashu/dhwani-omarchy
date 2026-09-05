#!/usr/bin/env python3
import json
import os
import sys
import tempfile
from pathlib import Path

LIMIT = 262144


def config_from(config: dict | None = None) -> dict:
    merged = {"state_home": None, "state_dir": None, "state_path": None, "limit": LIMIT}
    if config:
        merged.update(config)
    home = Path(
        merged["state_home"]
        or os.environ.get("XDG_STATE_HOME")
        or Path.home() / ".local/state"
    )
    directory = Path(merged["state_dir"] or home / "dhwani-omarchy")
    path = Path(merged["state_path"] or directory / "state.json")
    return {**merged, "state_home": home, "state_dir": directory, "state_path": path}


def empty() -> dict:
    return {
        "schemaVersion": 1,
        "queue": [],
        "nav": {
            "tab": 0,
            "trendingIndex": 0,
            "queueIndex": 0,
            "showsIndex": 0,
            "showIndex": 0,
            "openShowId": "",
            "openShowTitle": "",
        },
        "cache": {"trending": None, "shows": None, "showsById": {}},
    }


def load(config: dict | None = None) -> dict:
    path = config_from(config)["state_path"]
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError, UnicodeError):
        return empty()
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        return empty()
    return payload


def save(payload: dict, config: dict | None = None) -> Path:
    resolved = config_from(config)
    encoded = json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    if len(encoded.encode()) > resolved["limit"]:
        raise OSError("Dhwani state is too large")
    directory = resolved["state_dir"]
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=directory, delete=False
    ) as handle:
        handle.write(encoded)
        handle.flush()
        os.fsync(handle.fileno())
        temp_name = handle.name
    os.replace(temp_name, resolved["state_path"])
    return resolved["state_path"]


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in {"get", "put"}:
        raise SystemExit("usage: state.py get|put")
    try:
        if sys.argv[1] == "get":
            sys.stdout.write(json.dumps(load(), separators=(",", ":")))
        else:
            save(json.loads(sys.stdin.read(LIMIT)))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        raise SystemExit(str(error)) from error
