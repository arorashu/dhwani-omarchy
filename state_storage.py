#!/usr/bin/env python3
"""Prepare Dhwani's private state file before Quickshell can access it."""

import os
import stat
import sys
from pathlib import Path

DIRECTORY_MODE = 0o700
FILE_MODE = 0o600


def require_owned(item: os.stat_result, kind: str) -> None:
    if item.st_uid != os.getuid():
        raise PermissionError(f"{kind} is not owned by the current user")


def secure_storage(state_dir: Path) -> None:
    if state_dir.name != "dhwani-omarchy":
        raise ValueError("refusing to change permissions outside Dhwani storage")
    # XDG_STATE_HOME itself is user configuration, not plugin-owned storage.
    # Create it when absent, but never change its permissions.
    state_dir.parent.mkdir(parents=True, exist_ok=True)
    try:
        state_dir.mkdir(mode=DIRECTORY_MODE)
    except FileExistsError:
        pass

    directory_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC | os.O_NOFOLLOW
    directory_fd = os.open(state_dir, directory_flags)
    try:
        directory = os.fstat(directory_fd)
        require_owned(directory, "state directory")
        os.fchmod(directory_fd, DIRECTORY_MODE)

        file_flags = os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW
        state_fd = os.open("state.json", file_flags, FILE_MODE, dir_fd=directory_fd)
        try:
            state_file = os.fstat(state_fd)
            require_owned(state_file, "state file")
            if not stat.S_ISREG(state_file.st_mode):
                raise PermissionError("state file is not a regular file")
            if state_file.st_nlink != 1:
                raise PermissionError("state file has unexpected hard links")
            os.fchmod(state_fd, FILE_MODE)
        finally:
            os.close(state_fd)
    finally:
        os.close(directory_fd)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: state_storage.py STATE_DIRECTORY", file=sys.stderr)
        return 2
    try:
        secure_storage(Path(sys.argv[1]))
    except (OSError, ValueError) as error:
        print(f"could not secure Dhwani state: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
