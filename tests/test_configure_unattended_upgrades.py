"""Real function in a temporary filesystem; systemctl is always a shell stub."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_part2_error_propagation import PART2, STEPS

SOURCE = (Path(__file__).resolve().parents[1] / "tunevps.sh").read_text(encoding="utf-8")
FUNCTION = "configure_unattended_upgrades() {" + SOURCE.split(
    "configure_unattended_upgrades() {", 1)[1].split("\nconfigure_autoremove()", 1)[0]
TIMERS = ["apt-daily.timer", "apt-daily-upgrade.timer"]
SUCCESS = "Авто-обновления безопасности включены"
CONFIG = ('APT::Periodic::Update-Package-Lists "1";\n'
          'APT::Periodic::Unattended-Upgrade "1";\n'
          'APT::Periodic::Download-Upgradeable-Packages "1";\n'
          'APT::Periodic::AutocleanInterval "7";\n')


class ConfigureUnattendedUpgradesTest(unittest.TestCase):
    def run_setup(self, failure="", failed_timers=(), enabled=(), part2=False, errexit=False):
        with tempfile.TemporaryDirectory(prefix="unattended test ") as tmp:
            root = Path(tmp)
            target = root / "apt.conf.d/20auto-upgrades"
            if failure == "redirect":
                target.mkdir(parents=True)  # Opening a directory for writing must fail.
            prelude = r'''
set -o pipefail
section() { :; }
ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }
error() { echo "ERROR: $*" >&2; }
mkdir() {
  [ "$FAILURE" != mkdir ] || return 23
  command mkdir "$@"
}
cat() {
  if [ "$FAILURE" = write ]; then
    printf 'partial write\n'
    return 23
  fi
  command cat "$@"
}
systemctl() {
  printf '%s\n' "$*" >> "$CALLS"
  case "$1" in
    is-enabled) [[ " $ENABLED " = *" $2 "* ]] ;;
    enable) [[ " $FAILED_TIMERS " != *" $2 "* ]] ;;
    *) return 98 ;;
  esac
}
'''
            prelude += "\n".join(f'{step}() {{ echo STEP:{step}; return 0; }}'
                                 for step in STEPS if step != "configure_unattended_upgrades")
            # Redirect only the audited config directory into this temporary tree.
            function = FUNCTION.replace("/etc/apt/apt.conf.d", '"$CONFIG_DIR"')
            call = "part2_setup" if part2 else "configure_unattended_upgrades"
            env = dict(os.environ, FAILURE=failure, FAILED_TIMERS=" ".join(failed_timers),
                       ENABLED=" ".join(enabled), CONFIG_DIR=(root / "apt.conf.d").as_posix(),
                       CALLS=(root / "calls").as_posix())
            result = subprocess.run([os.environ.get("BASH", "bash")],
                input=prelude + "\n" + function + "\n" + PART2 + "\n"
                      + ("set -e\n" if errexit else "") + f"{call} || exit $?\n",
                env=env, text=True, encoding="utf-8", capture_output=True, timeout=10)
            calls = (root / "calls").read_text().splitlines() if (root / "calls").exists() else []
            config = target.read_text() if target.is_file() else None
            return result, calls, config

    def check_critical_failure(self, failure, part2=False):
        for errexit in (False, True):
            with self.subTest(failure=failure, part2=part2, errexit=errexit):
                result, calls, config = self.run_setup(failure, part2=part2, errexit=errexit)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("ERROR: Не удалось", result.stderr)
                self.assertEqual(calls, [])
                self.assertNotEqual(config, CONFIG)
                self.assertNotIn(SUCCESS, result.stdout + result.stderr)
                self.assertNotIn("Часть 2 завершена", result.stdout + result.stderr)
                if part2:
                    self.assertEqual([s for s in result.stdout.splitlines() if s.startswith("STEP:")],
                                     ["STEP:install_packages", "STEP:configure_locale_time"])

    def test_mkdir_failure(self):
        self.check_critical_failure("mkdir")

    def test_redirection_failure(self):
        self.check_critical_failure("redirect")

    def test_partial_write_failure(self):
        self.check_critical_failure("write")

    def test_critical_failures_propagate_through_part2(self):
        for failure in ("mkdir", "redirect", "write"):
            self.check_critical_failure(failure, part2=True)

    def test_both_timers_enable_success(self):
        result, calls, config = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config, CONFIG)
        self.assertEqual(calls, [f"{action} {timer}" for timer in TIMERS
                                 for action in ("is-enabled", "enable")])
        self.assertIn(SUCCESS, result.stdout)
        self.assertNotIn("WARN:", result.stdout)

    def test_already_enabled_timers_are_not_enabled_again(self):
        result, calls, config = self.run_setup(enabled=TIMERS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config, CONFIG)
        self.assertEqual(calls, [f"is-enabled {timer}" for timer in TIMERS])
        self.assertIn(SUCCESS, result.stdout)

    def check_timer_failures(self, failed):
        for part2 in (False, True):
            for errexit in (False, True):
                with self.subTest(failed=failed, part2=part2, errexit=errexit):
                    result, calls, config = self.run_setup(
                        failed_timers=failed, part2=part2, errexit=errexit)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(config, CONFIG)
                    self.assertEqual(calls, [f"{action} {timer}" for timer in TIMERS
                                             for action in ("is-enabled", "enable")])
                    for timer in TIMERS:
                        self.assertEqual(f"WARN: Не удалось включить {timer}" in result.stdout,
                                         timer in failed)
                    self.assertIn("systemctl list-timers", result.stdout)
                    self.assertNotIn(SUCCESS, result.stdout)
                    self.assertEqual("Часть 2 завершена" in result.stdout, part2)

    def test_one_timer_failure_is_best_effort(self):
        for timer in TIMERS:
            self.check_timer_failures([timer])

    def test_both_timer_failures_are_best_effort(self):
        self.check_timer_failures(TIMERS)

    def test_part2_success(self):
        result, calls, config = self.run_setup(part2=True, errexit=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config, CONFIG)
        self.assertIn(SUCCESS, result.stdout)
        self.assertEqual(result.stdout.count("Часть 2 завершена"), 1)
        self.assertEqual([s for s in result.stdout.splitlines() if s.startswith("STEP:")],
                         [f"STEP:{s}" for s in STEPS if s != "configure_unattended_upgrades"])


if __name__ == "__main__":
    unittest.main()
