"""Run the real package function with shell stubs; never invoke apt or ln."""
import os
from pathlib import Path
import subprocess
import unittest

from test_part2_error_propagation import PART2, STEPS


SOURCE = (Path(__file__).resolve().parents[1] / "tunevps.sh").read_text(encoding="utf-8")
INSTALL = "install_packages() {" + SOURCE.split("install_packages() {", 1)[1].split("\nconfigure_locale_time()", 1)[0]


class OptionalPackagesTest(unittest.TestCase):
    def run_install(self, failure="", status=1, repeat=1, outer=False, rng=True):
        # Override the hwrng predicate without touching /dev or production code.
        # All side-effecting commands in INSTALL are functions, including ln.
        prelude = r'''
set -e
section() { :; }
info() { :; }
warn() { echo "WARN:$*"; }
error() { echo "ERROR:$*"; }
ok() { echo "OK:$*"; }
function [() {
  if test "$*" = '-e /dev/hwrng ]'; then
    test "$RNG" = yes
  else
    builtin [ "$@"
  fi
}
apt-get() {
  echo "APT:$*"
  local operation=base
  if test "$1" = update; then operation=update;
  elif test "$#" = 3; then operation="$3"; fi
  if test "$FAILURE" = "$operation"; then return "$STATUS"; fi
  return 0
}
apt-cache() {
  echo "PROBE:$*" >&3
  if test "$FAILURE" = "probe:$2"; then return "$STATUS"; fi
  return 0
}
ln() {
  echo "LINK:$*"
  if test "$FAILURE" = "link:${3##*/}"; then
    echo 'ln: simulated failure' >&2
    return "$STATUS"
  fi
  return 0
}
exec 3>&1
'''
        stubs = "\n".join(f'{name}() {{ echo NEXT:{name}; }}' for name in STEPS[1:])
        call = "part2_setup" if outer else "install_packages"
        script = prelude + INSTALL + stubs + "\n" + PART2 + "\n"
        script += (call + "\n") * repeat
        env = dict(os.environ, FAILURE=failure, STATUS=str(status), RNG="yes" if rng else "no")
        return subprocess.run([os.environ.get("BASH", "bash")], input=script,
                              text=True, encoding="utf-8", capture_output=True,
                              env=env, timeout=10)

    def assert_success(self, result, warnings=0):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.count("WARN:"), warnings, result.stdout)

    def test_rng_failure_warns_and_succeeds(self):
        result = self.run_install("rng-tools5")
        self.assert_success(result, 1)
        self.assertIn("optional-пакет rng-tools5", result.stdout)
        self.assertIn("APT:install -y eza", result.stdout)

    def test_probe_nonzero_skips_apply_with_accurate_warning(self):
        for package in ("eza", "zoxide"):
            for status in (1, 100, 127):
                with self.subTest(package=package, status=status):
                    result = self.run_install("probe:" + package, status)
                    self.assert_success(result, 1)
                    self.assertIn(f"Пакет {package} недоступен или не удалось проверить", result.stdout)
                    self.assertNotIn(f"APT:install -y {package}", result.stdout)
                    self.assertIn("LINK:-sf /usr/bin/fdfind /usr/local/bin/fd", result.stdout)

    def test_optional_install_failure_continues(self):
        for package in ("eza", "zoxide"):
            with self.subTest(package=package):
                result = self.run_install(package)
                self.assert_success(result, 1)
                self.assertIn(f"optional-пакет {package}", result.stdout)
                self.assertIn("APT:install -y zoxide", result.stdout)
                self.assertIn("LINK:-sf /usr/bin/batcat /usr/local/bin/bat", result.stdout)

    def test_bat_symlink_failure(self):
        result = self.run_install("link:bat")
        self.assert_success(result, 1)
        self.assertIn("symlink /usr/local/bin/bat", result.stdout)
        self.assertIn("ln: simulated failure", result.stderr)
        self.assertIn("LINK:-sf /usr/bin/fdfind /usr/local/bin/fd", result.stdout)

    def test_fd_symlink_failure(self):
        result = self.run_install("link:fd")
        self.assert_success(result, 1)
        self.assertIn("symlink /usr/local/bin/fd", result.stdout)
        self.assertIn("ln: simulated failure", result.stderr)

    def test_all_success_order_and_flags(self):
        result = self.run_install()
        self.assert_success(result)
        operations = [line for line in result.stdout.splitlines()
                      if line.startswith(("APT:", "PROBE:", "LINK:"))]
        self.assertEqual(operations[0], "APT:update")
        self.assertTrue(operations[1].startswith("APT:install -y nano git curl "))
        self.assertEqual(operations[2:], [
            "APT:install -y rng-tools5", "PROBE:show eza", "APT:install -y eza",
            "PROBE:show zoxide", "APT:install -y zoxide",
            "LINK:-sf /usr/bin/batcat /usr/local/bin/bat",
            "LINK:-sf /usr/bin/fdfind /usr/local/bin/fd"])

    def test_repeated_invocation_is_safe(self):
        for failure in ("", "rng-tools5", "probe:eza", "eza", "link:bat", "link:fd"):
            with self.subTest(failure=failure):
                result = self.run_install(failure, repeat=2)
                self.assert_success(result, 2 if failure else 0)
                self.assertEqual(result.stdout.count("LINK:-sf /usr/bin/fdfind /usr/local/bin/fd"), 2)

    def test_outer_part2_success_with_optional_failures(self):
        for failure in ("", "rng-tools5", "probe:eza", "eza", "link:bat", "link:fd"):
            with self.subTest(failure=failure):
                result = self.run_install(failure, outer=True)
                self.assert_success(result, 1 if failure else 0)
                self.assertEqual([line[5:] for line in result.stdout.splitlines()
                                  if line.startswith("NEXT:")], STEPS[1:])
                self.assertEqual(result.stdout.count("Часть 2 завершена"), 1)

    def test_required_failures_still_fatal(self):
        for failure in ("update", "base"):
            for outer in (False, True):
                with self.subTest(failure=failure, outer=outer):
                    result = self.run_install(failure, status=42, outer=outer)
                    self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                    self.assertNotIn("APT:install -y rng-tools5", result.stdout)
                    self.assertNotIn("NEXT:", result.stdout)
                    self.assertNotIn("Часть 2 завершена", result.stdout)

    def test_no_hardware_rng_skips_install(self):
        result = self.run_install(rng=False)
        self.assert_success(result)
        self.assertNotIn("APT:install -y rng-tools5", result.stdout)


if __name__ == "__main__":
    unittest.main()
