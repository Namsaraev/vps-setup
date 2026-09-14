"""Real function, temporary config paths, and an unconditional systemctl stub."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_part2_error_propagation import PART2, STEPS

SOURCE = (Path(__file__).resolve().parents[1] / "tunevps.sh").read_text(encoding="utf-8")
FUNCTION = "configure_systemd_limits() {" + SOURCE.split(
    "configure_systemd_limits() {", 1)[1].split("\nconfigure_swap()", 1)[0]
CONFIG = "[Manager]\nDefaultLimitNOFILE=1048576\n"
SUCCESS = "DefaultLimitNOFILE=1048576 применён ко всем сервисам"


class ConfigureSystemdLimitsTest(unittest.TestCase):
    def run_setup(self, failure="", part2=False, errexit=False, repeat=False):
        with tempfile.TemporaryDirectory(prefix="systemd limits test ") as tmp:
            root = Path(tmp)
            directory = root / "system.conf.d"
            directory.mkdir()
            target = directory / "99-nofile.conf"
            unrelated = directory / "10-custom.conf"
            unrelated.write_bytes(b"[Manager]\nDefaultTimeoutStopSec=17s\n")
            before = unrelated.stat().st_mtime_ns
            if failure == "redirect":
                target.mkdir()
            prelude = r'''
set -o pipefail
section() { :; }
info() { :; }
ok() { echo "OK: $*"; }
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
  [ "$*" = daemon-reexec ] || return 98
  [ "$FAILURE" != reexec ] || return 23
  # Verify the complete config exists before activation, without a real service call.
  [ "$(command cat "$CONFIG_DIR/99-nofile.conf")" = "[Manager]
DefaultLimitNOFILE=1048576" ] || return 97
}
'''
            prelude += "\n".join(f'{step}() {{ echo STEP:{step}; return 0; }}'
                                 for step in STEPS if step != "configure_systemd_limits")
            function = FUNCTION.replace("/etc/systemd/system.conf.d", '"$CONFIG_DIR"')
            call = "part2_setup" if part2 else "configure_systemd_limits"
            env = dict(os.environ, FAILURE=failure, CONFIG_DIR=directory.as_posix(),
                       CALLS=(root / "calls").as_posix())
            script = prelude + "\n" + function + "\n" + PART2 + "\n"
            script += "set -e\n" if errexit else ""
            script += f"{call} || exit $?\n"
            if repeat:
                script += 'command cp "$CONFIG_DIR/99-nofile.conf" "$CONFIG_DIR/first-run"\n'
                script += f"{call} || exit $?\n"
            result = subprocess.run([os.environ.get("BASH", "bash")], input=script,
                                    env=env, text=True, encoding="utf-8",
                                    capture_output=True, timeout=10)
            calls = (root / "calls").read_text().splitlines() if (root / "calls").exists() else []
            config = target.read_text() if target.is_file() else None
            self.assertEqual(unrelated.read_bytes(), b"[Manager]\nDefaultTimeoutStopSec=17s\n")
            self.assertEqual(unrelated.stat().st_mtime_ns, before)
            if repeat:
                self.assertEqual((directory / "first-run").read_text(), config)
            return result, calls, config

    def check_failure(self, failure, part2=False):
        for errexit in (False, True):
            with self.subTest(failure=failure, part2=part2, errexit=errexit):
                result, calls, config = self.run_setup(failure, part2, errexit)
                self.assertEqual(result.returncode, 1, result.stderr)
                message = {"mkdir": "Не удалось создать", "redirect": "Не удалось записать",
                           "write": "Не удалось записать",
                           "reexec": "Не удалось выполнить systemctl daemon-reexec"}[failure]
                self.assertIn("ERROR: " + message, result.stderr)
                self.assertEqual(calls, ["daemon-reexec"] if failure == "reexec" else [])
                self.assertNotIn(SUCCESS, result.stdout + result.stderr)
                self.assertNotIn("Часть 2 завершена", result.stdout + result.stderr)
                if failure == "write":
                    self.assertEqual(config, "partial write\n")
                if failure == "reexec":
                    self.assertEqual(config, CONFIG)
                if part2:
                    self.assertEqual([s for s in result.stdout.splitlines() if s.startswith("STEP:")],
                                     [f"STEP:{s}" for s in STEPS[:STEPS.index("configure_systemd_limits")]])

    def test_mkdir_failure(self):
        self.check_failure("mkdir")

    def test_config_open_failure(self):
        self.check_failure("redirect")

    def test_partial_write_failure(self):
        self.check_failure("write")

    def test_daemon_reexec_failure(self):
        self.check_failure("reexec")

    def test_failures_propagate_through_part2(self):
        for failure in ("mkdir", "redirect", "write", "reexec"):
            self.check_failure(failure, part2=True)

    def test_success(self):
        for errexit in (False, True):
            result, calls, config = self.run_setup(errexit=errexit)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, ["daemon-reexec"])
            self.assertEqual(config, CONFIG)
            self.assertEqual(result.stdout.count(SUCCESS), 1)
            self.assertNotIn("ERROR:", result.stderr)

    def test_repeated_run_is_idempotent(self):
        result, calls, config = self.run_setup(repeat=True, errexit=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config, CONFIG)
        self.assertEqual(calls, ["daemon-reexec", "daemon-reexec"])
        self.assertEqual(result.stdout.count(SUCCESS), 2)

    def test_part2_success(self):
        result, calls, config = self.run_setup(part2=True, errexit=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(config, CONFIG)
        self.assertEqual(calls, ["daemon-reexec"])
        self.assertEqual(result.stdout.count("Часть 2 завершена"), 1)
        self.assertEqual([s for s in result.stdout.splitlines() if s.startswith("STEP:")],
                         [f"STEP:{s}" for s in STEPS if s != "configure_systemd_limits"])


if __name__ == "__main__":
    unittest.main()
