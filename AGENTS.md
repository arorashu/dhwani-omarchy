# Testing

Read the testing instructions in `CONTRIBUTING.md` before running local tests.
On a systemd workstation, wrap test commands with `tests/crash_gate.py` and retain
its report. Stop after an unexplained crash; a passing retry is not a resolution.
Do not drive the user's live desktop without coordination. Report exactly which
layer passed (mock, QML, helper playback, or full panel E2E), plus any open failures.
