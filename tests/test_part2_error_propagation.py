"""Exercise only part2 orchestration; every setup step is a harmless stub."""
import os
from pathlib import Path
import subprocess
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "tunevps.sh").read_text(encoding="utf-8")
PART2 = "part2_setup() {" + SOURCE.split("part2_setup() {", 1)[1].split("\npart3_tests()", 1)[0]
STEPS = (
    "install_packages configure_locale_time configure_unattended_upgrades "
    "configure_autoremove configure_needrestart configure_safe_sysctl "
    "configure_systemd_limits configure_swap configure_pin configure_ssh "
    "configure_ufw configure_shell final_check"
).split()
CRITICAL = [name for name in STEPS if name not in (
    "configure_unattended_upgrades", "configure_autoremove")]


class Part2PropagationTest(unittest.TestCase):
    def run_part2(self, failure="", status=1, warning="", errexit=False):
        stubs = []
        for name in STEPS:
            body = f'echo CALL:{name}; '
            if name == warning:
                body += 'warn "optional step skipped"; '
            body += f'return {status if name == failure else 0};'
            stubs.append(f'{name}() {{ {body} }}')
        prelude = '''
set -o pipefail
section() { :; }
ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }
error() { echo "ERROR: $*" >&2; }
'''
        return subprocess.run(
            [os.environ.get("BASH", "bash")],
            input=prelude + "\n".join(stubs) + "\n" + PART2 + "\n"
                  + ("set -e\n" if errexit else "") + "part2_setup || exit $?\n",
            text=True, encoding="utf-8", capture_output=True, timeout=10)

    def assert_calls(self, result, expected):
        self.assertEqual([line.removeprefix("CALL:") for line in result.stdout.splitlines()
                          if line.startswith("CALL:")], expected)

    def test_each_critical_failure_stops_at_failed_step(self):
        for name in CRITICAL:
            for errexit in (False, True):
                with self.subTest(step=name, errexit=errexit):
                    result = self.run_part2(failure=name, errexit=errexit)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assert_calls(result, STEPS[:STEPS.index(name) + 1])
                    self.assertNotIn("Часть 2 завершена", result.stdout + result.stderr)

    def test_new_guards_preserve_failure_status(self):
        for name in ("configure_locale_time", "configure_ufw", "configure_shell"):
            with self.subTest(step=name):
                result = self.run_part2(failure=name, status=23)
                self.assertEqual(result.returncode, 23, result.stderr)
                self.assert_calls(result, STEPS[:STEPS.index(name) + 1])
                self.assertNotIn("Часть 2 завершена", result.stdout + result.stderr)

    def test_success_calls_all_steps_and_completes_once(self):
        result = self.run_part2()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_calls(result, STEPS)
        self.assertEqual(result.stdout.count("Часть 2 завершена"), 1)

    def test_warning_or_successful_skip_does_not_abort(self):
        # Refusals are represented by their existing contract: warning/info + 0.
        for name in STEPS:
            with self.subTest(step=name):
                result = self.run_part2(warning=name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assert_calls(result, STEPS)
                self.assertIn("WARN:", result.stdout)
                self.assertEqual(result.stdout.count("Часть 2 завершена"), 1)


if __name__ == "__main__":
    unittest.main()
