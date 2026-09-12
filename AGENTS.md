# Testing

Read `CONTRIBUTING.md` before testing. Assert product behavior and owned-process
exit/cleanup directly; use host crash records for diagnosis, not a global gate.
Stop after unexplained failures; a passing retry does not resolve a crash.
Coordinate live-desktop input. State the exact test layer and any open failures.
