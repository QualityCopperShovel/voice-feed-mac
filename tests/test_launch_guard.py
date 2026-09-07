"""The release smoke check must reject the failure mode from Mac 1.4.0."""
import subprocess
import sys
import unittest
from pathlib import Path

class LaunchGuardTest(unittest.TestCase):
    def test_successful_early_exit_is_a_release_failure(self):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('check_launch.py')), '/usr/bin/true'], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exited during startup (0)', result.stderr)
