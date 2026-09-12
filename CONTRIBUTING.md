# Contributing

Keep Dhwani a small listening doorway: curated episodes enter here, while playback controls stay with Omarchy and MPRIS.

Before opening a pull request, run:

```bash
omarchy plugin validate .
imports=$(mktemp -d)
ln -s /usr/share/omarchy/shell "$imports/qs"
/usr/lib/qt6/bin/qmllint -I "$imports" BarWidget.qml Panel.qml Service.qml
rm -rf "$imports"
node tests/model.test.js
node tests/service.test.js
node tests/artwork.test.js
node tests/search.test.js
node tests/fixture-flow.test.js
node tests/panel.test.js
python3 tests/test_qml_runtime.py
python3 tests/test_play.py
python3 tests/test_qml_contract.py
python3 tests/test_playback_pipeline.py
ruff check play.py tests
ruff format --check play.py tests
```

The playback pipeline proof is always strict: it requires `mpv`, `mpv-mpris`,
`dbus-run-session`, systemd `busctl`, and `quickshell`, and fails instead of
skipping when a tool is missing. It runs in a private sandbox and never touches
the user's own player or session.

## Crash accounting on a systemd workstation

Wrap local test commands with the host crash gate:

```bash
python3 tests/crash_gate.py --output /tmp/dhwani-run-crashes.json -- \
  bash -e -c 'node tests/model.test.js; python3 tests/test_qml_runtime.py'
```

The wrapper records a coredump baseline, runs the command, waits 10 seconds for
reporting, and saves the delta plus the command exit status. A failed command,
new visible host core, or failed inspection fails the gate. Use a fresh output
path per run. It requires `coredumpctl` and journal access; it is a workstation
check, not a replacement for container CI. CI tests its logic with fixtures.

This is crash accounting, **not isolation or automatic attribution**. Concurrent
user applications can also add cores. Investigate new records by PID, command
line, timestamp and run logs before assigning blame. A finite reporting window
can miss delayed cores, and failures that produce no core need other evidence.

- Stop after an unexplained crash; retain the report and investigate before
  repeating host probes. A passing retry does not resolve the earlier crash.
- Private HOME/XDG/D-Bus do not isolate the compositor, activated helpers or host
  crash notifications. Do not normalize helper crashes as expected passes or
  suppress notifications to make a run look clean.
- Coordinate synthetic input on the user's live desktop. Offscreen tests do not
  require human review; do not substitute human checks for automated assertions.
- State the exact commit, commands and test layer: mocks, real offscreen QML,
  direct mpv/MPRIS helper, panel navigation, or full panel-driven playback/resume.
  A pass in one layer does not prove the others. Report unresolved crashes
  alongside green results; local success is not exact-head CI evidence.

For live testing, copy only the five runtime files listed in the README. Let Omarchy's plugin watcher settle before restarting the shell; copying files and immediately restarting can trigger [Quickshell #956](https://github.com/quickshell-mirror/quickshell/issues/956) on version 0.3.1.

Report security issues through GitHub's private vulnerability reporting rather than a public issue.
