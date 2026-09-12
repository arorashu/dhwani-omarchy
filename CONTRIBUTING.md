# Contributing

Keep Dhwani a small listening doorway: curated episodes enter here, while playback controls stay with Omarchy and MPRIS.

Before opening a pull request, run:

```bash
omarchy plugin validate .
imports=$(mktemp -d)
ln -s /usr/share/omarchy/shell "$imports/qs"
/usr/lib/qt6/bin/qmllint -I "$imports" BarWidget.qml Panel.qml Service.qml
rm -rf "$imports"
node --test tests/*.test.js
python3 tests/test_qml_runtime.py
python3 tests/test_play.py
python3 tests/test_qml_contract.py
python3 tests/test_playback_pipeline.py
ruff check --extend-select I,PLW1510 play.py tests
ruff format --check play.py tests
```

The playback pipeline proof is always strict: it requires `mpv`, `mpv-mpris`,
`dbus-run-session`, systemd `busctl`, and `quickshell`, and fails instead of
skipping when a tool is missing. It uses private state and a private D-Bus session.

## Testing discipline

- Product tests assert behavior, subprocess exit status, timeouts and cleanup of
  owned processes. Host-wide crash counts are diagnostic evidence, not a product
  pass/fail gate: unrelated applications can crash, and some failures leave no core.
- For native workstation tests, inspect new crash records and correlate PID,
  command line and time with the run. Stop and investigate unexplained failures;
  a passing retry does not resolve an earlier crash. Do not suppress notifications.
- Private HOME/XDG/D-Bus do not isolate the compositor or activated helpers.
  Coordinate synthetic input on the user's desktop; human review is not a
  substitute for automated assertions.
- Report the exact commit, commands and layer tested: mocks, offscreen QML,
  helper playback or full panel E2E. A pass in one does not prove the others.
  Keep unresolved failures visible alongside green results.

For live testing, copy only the six installation files listed in the README. Let Omarchy's plugin watcher settle before restarting the shell; copying files and immediately restarting can trigger [Quickshell #956](https://github.com/quickshell-mirror/quickshell/issues/956) on version 0.3.1.

Report security issues through GitHub's private vulnerability reporting rather than a public issue.
