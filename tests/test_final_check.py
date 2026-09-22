"""Isolated final-check and menu tests; no host configuration is executed."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / "tunevps.sh").read_text(encoding="utf-8")
FINAL = "final_check() {" + SOURCE.split("final_check() {", 1)[1].split("\npart2_setup()", 1)[0]
PART2 = "part2_setup() {" + SOURCE.split("part2_setup() {", 1)[1].split("\npart3_tests()", 1)[0]
MENU = "while true; do" + SOURCE.rsplit("while true; do", 1)[1]
PRELUDE = r'''
set -o pipefail
section() { :; }
ok() { echo "OK: $*"; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
error() { echo "ERROR: $*" >&2; }
install() { :; }
check_ssh_port() { [ "$FAIL_PORT" != 1 ]; }
systemctl() {
  if [ "$1" = is-active ]; then
    [ "$FAIL_ACTIVE" != 1 ]
  else
    echo 1048576
  fi
}
sshd() {
  if [ "$1" = -t ]; then
    [ "$FAIL_SYNTAX" != 1 ]
  elif [ "$FAIL_EFFECTIVE" = 1 ]; then
    return 1
  else
    echo "port 5829"
    echo "kbdinteractiveauthentication no"
    echo "maxauthtries 3"
    echo "passwordauthentication ${PASSWORD_AUTH:-no}"
    echo "pubkeyauthentication yes"
    echo "permitrootlogin no"
  fi
}
sysctl() { echo bbr; }
swapon() { echo '/fake-swap'; }
ufw() { echo 'Status: active'; }
ufw_is_active() { return 0; }
zoxide() { :; }
ask() { choice=0; if [ "${ASKED:-0}" = 0 ]; then choice=2; ASKED=1; fi; }
pause() { echo PAUSED; }
'''
SETUP_STEPS = (
    "install_packages configure_locale_time configure_unattended_upgrades "
    "configure_autoremove configure_needrestart configure_safe_sysctl "
    "configure_systemd_limits configure_swap configure_pin configure_ssh "
    "configure_ufw configure_shell"
).split()


class FinalCheckTest(unittest.TestCase):
    def run_check(self, mode="final", missing_rc=False, **failures):
        with tempfile.TemporaryDirectory(prefix="final check ") as tmp:
            home = Path(tmp)
            (home / ".oh-my-zsh/custom/themes/powerlevel10k").mkdir(parents=True)
            if not missing_rc:
                (home / ".zshrc").touch()
            env = dict(os.environ, USER_HOME=home.as_posix(), CURRENT_USER="test",
                       SSH_PORT="5829", IS_MINIMIZED="false", SWAP_RAM_THRESHOLD_MB="2048")
            for key in ("FAIL_PORT", "FAIL_ACTIVE", "FAIL_SYNTAX", "FAIL_EFFECTIVE",
                        "PASSWORD_AUTH", "ASKED"):
                env.pop(key, None)
            env.update(failures)
            stubs = "\n".join(f"{name}() {{ :; }}" for name in SETUP_STEPS)
            ending = {"final": "final_check", "part2": "part2_setup", "main": MENU}[mode]
            return subprocess.run(
                [os.environ.get("BASH", "bash")],
                input=PRELUDE + stubs + "\n" + FINAL + PART2 + "\n" + ending + "\n",
                text=True, encoding="utf-8", capture_output=True, env=env, timeout=10)

    def test_all_critical_checks_pass(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

    def test_each_critical_failure(self):
        for failure in ({"FAIL_PORT": "1"}, {"FAIL_ACTIVE": "1"},
                        {"FAIL_SYNTAX": "1"}, {"PASSWORD_AUTH": "yes"},
                        {"missing_rc": True}, {"FAIL_EFFECTIVE": "1"}):
            with self.subTest(failure=failure):
                result = self.run_check(**failure)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stderr.count("ERROR:"), 1)
                self.assertIn("systemd DefaultLimitNOFILE=1048576", result.stdout)

    def test_multiple_errors_are_all_reported(self):
        result = self.run_check(FAIL_PORT="1", FAIL_ACTIVE="1", FAIL_SYNTAX="1",
                                PASSWORD_AUTH="yes", missing_rc=True)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(result.stderr.count("ERROR:"), 5)

    def test_warning_does_not_fail(self):
        result = self.run_check(IS_MINIMIZED="true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("WARN:", result.stdout)

    def test_failure_propagates_without_completion_message(self):
        for mode in ("part2", "main"):
            with self.subTest(mode=mode):
                result = self.run_check(mode, FAIL_PORT="1")
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertNotIn("Часть 2 завершена", result.stdout + result.stderr)
                self.assertNotIn("PAUSED", result.stdout)

    def test_needrestart_failure_propagates_without_completion_message(self):
        stubs = "\n".join(f"{name}() {{ :; }}" for name in SETUP_STEPS)
        result = subprocess.run(
            [os.environ.get("BASH", "bash")],
            input=PRELUDE + stubs + "\n" + PART2 + "\n"
                  "configure_needrestart() { return 1; }\n"
                  "final_check() { :; }\n"
                  "set -e\npart2_setup || exit $?\n",
            text=True, encoding="utf-8", capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("Часть 2 завершена", result.stdout + result.stderr)

    def test_success_flow_retains_completion_message(self):
        for mode in ("part2", "main"):
            with self.subTest(mode=mode):
                result = self.run_check(mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.count("Часть 2 завершена"), 1)


if __name__ == "__main__":
    unittest.main()
