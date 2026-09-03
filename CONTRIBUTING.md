# Contributing

Keep Dhwani a small listening doorway: curated episodes enter here, while playback controls stay with Omarchy and MPRIS.

Before opening a pull request, run:

```bash
omarchy plugin validate .
imports=$(mktemp -d)
ln -s /usr/share/omarchy/shell "$imports/qs"
/usr/lib/qt6/bin/qmllint -I "$imports" BarWidget.qml Panel.qml
rm -rf "$imports"
node tests/model.test.js
python3 tests/test_play.py
ruff check play.py tests/test_play.py
ruff format --check play.py tests/test_play.py
```

For live testing, copy only the five runtime files listed in the README. Let Omarchy's plugin watcher settle before restarting the shell; copying files and immediately restarting can trigger [Quickshell #956](https://github.com/quickshell-mirror/quickshell/issues/956) on version 0.3.1.

Report security issues through GitHub's private vulnerability reporting rather than a public issue.
