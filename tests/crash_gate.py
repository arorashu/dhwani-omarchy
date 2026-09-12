"""Run a command with a before/after host coredump check (not containment)."""

import argparse
import datetime
import json
import os
import subprocess
import time
from pathlib import Path


def snapshot(since):
    result = subprocess.run(
        ["coredumpctl", "--no-pager", "--json=short", "list", "--since", since],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
        env={**os.environ, "LC_ALL": "C"},
    )
    if result.returncode == 1 and result.stderr.strip() == "No coredumps found.":
        return []
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "coredumpctl failed")
    rows = json.loads(result.stdout)
    if not isinstance(rows, list):
        # A non-list JSON value is a type error; json.loads already raises
        # ValueError (JSONDecodeError) for malformed text. Both stay caught in
        # run() so a bad coredumpctl reply is reported, never a crash.
        raise TypeError("Expected coredumpctl JSON list")
    return rows


def new_crashes(before, after):
    keys = {(row["time"], row["pid"], row["exe"]) for row in before}
    return [row for row in after if (row["time"], row["pid"], row["exe"]) not in keys]


def run(command, output, settle_seconds):
    since = (
        datetime.datetime.now(datetime.UTC) - datetime.timedelta(seconds=1)
    ).isoformat()
    report = {"command": command, "since": since, "settle_seconds": settle_seconds}
    status = 1
    try:
        report["before"] = snapshot(since)
        # Fail closed before starting tests if the baseline cannot be collected.
        try:
            result = subprocess.run(command, check=False)
            report["command_exit"] = result.returncode
        except OSError as error:
            report["command_exit"] = 127
            report["command_error"] = str(error)
        # Give systemd-coredump time to publish records; this is a finite window,
        # not a guarantee that every delayed report has arrived.
        time.sleep(settle_seconds)
        report["after"] = snapshot(since)
        report["new_crashes"] = new_crashes(report["before"], report["after"])
        status = 0 if report["command_exit"] == 0 and not report["new_crashes"] else 1
    except (
        OSError,
        RuntimeError,
        ValueError,
        TypeError,
        subprocess.TimeoutExpired,
    ) as error:
        report["inspection_error"] = str(error)
    report["passed"] = status == 0
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Crash gate {'passed' if status == 0 else 'FAILED'}: {output}", flush=True)
    for row in report.get("new_crashes", []):
        print(f"New host core: pid={row['pid']} exe={row['exe']} time={row['time']}")
    return status


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--settle-seconds", type=float, default=10)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 0 <= args.settle_seconds <= 60:
        parser.error("Supply a command and a settle window between 0 and 60 seconds")
    return run(command, args.output, args.settle_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
