import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import crash_gate

CORE = {"time": 123, "pid": 456, "exe": "/usr/bin/test-helper"}


class CrashGateTests(unittest.TestCase):
    def check_run(self, snapshots, exit_code=0):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "report.json"
            with (
                patch.object(crash_gate, "snapshot", side_effect=snapshots),
                patch.object(crash_gate.subprocess, "run") as command,
                patch.object(crash_gate.time, "sleep"),
            ):
                command.return_value.returncode = exit_code
                status = crash_gate.run(["test-command"], output, 0)
            return status, json.loads(output.read_text()), command.call_count

    def test_clean_command_and_existing_core_pass(self):
        status, report, calls = self.check_run([[CORE], [CORE]])
        self.assertEqual(status, 0)
        self.assertEqual(report["new_crashes"], [])
        self.assertEqual(calls, 1)

    def test_new_helper_core_fails_even_when_command_passes(self):
        status, report, _ = self.check_run([[], [CORE]])
        self.assertEqual(status, 1)
        self.assertEqual(report["command_exit"], 0)
        self.assertEqual(report["new_crashes"], [CORE])

    def test_command_failure_is_not_masked(self):
        status, report, _ = self.check_run([[], []], exit_code=7)
        self.assertEqual(status, 1)
        self.assertEqual(report["command_exit"], 7)

    def test_missing_baseline_prevents_command(self):
        status, report, calls = self.check_run([RuntimeError("journal unavailable")])
        self.assertEqual(status, 1)
        self.assertEqual(calls, 0)
        self.assertIn("inspection_error", report)

    def test_type_invalid_baseline_prevents_command(self):
        status, report, calls = self.check_run(
            [TypeError("Expected coredumpctl JSON list")]
        )
        self.assertEqual(status, 1)
        self.assertEqual(calls, 0, "a bad baseline must not let the command run")
        self.assertIn("inspection_error", report)
        self.assertTrue(report["passed"] is False)

    def test_type_invalid_final_inspection_fails_after_command(self):
        status, report, calls = self.check_run(
            [[], TypeError("Expected coredumpctl JSON list")]
        )
        self.assertEqual(status, 1)
        self.assertEqual(calls, 1, "the command runs before the final inspection fails")
        self.assertEqual(report["command_exit"], 0)
        self.assertIn("inspection_error", report)
        self.assertTrue(report["passed"] is False)

    def test_failed_final_inspection_fails_gate(self):
        status, report, calls = self.check_run(
            [[], RuntimeError("journal unavailable")]
        )
        self.assertEqual(status, 1)
        self.assertEqual(calls, 1)
        self.assertIn("inspection_error", report)

    def test_snapshot_empty_vs_error(self):
        with patch.object(crash_gate.subprocess, "run") as command:
            command.return_value = subprocess.CompletedProcess(
                [], 1, "", "No coredumps found.\n"
            )
            self.assertEqual(crash_gate.snapshot("now"), [])
            command.return_value = subprocess.CompletedProcess(
                [], 1, "", "Permission denied"
            )
            with self.assertRaises(RuntimeError):
                crash_gate.snapshot("now")

    def test_snapshot_rejects_malformed_and_type_invalid_json(self):
        with patch.object(crash_gate.subprocess, "run") as command:
            command.return_value = subprocess.CompletedProcess([], 0, "{", "")
            with self.assertRaises(json.JSONDecodeError):
                crash_gate.snapshot("now")
            command.return_value = subprocess.CompletedProcess([], 0, "{}", "")
            with self.assertRaises(TypeError):
                crash_gate.snapshot("now")


if __name__ == "__main__":
    unittest.main()
