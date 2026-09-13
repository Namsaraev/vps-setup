"""Exercise real locale/time orchestration with harmless command stubs."""
import os
from pathlib import Path
import subprocess
import unittest

from test_part2_error_propagation import PART2, STEPS


SOURCE = (Path(__file__).resolve().parents[1] / "tunevps.sh").read_text(encoding="utf-8")
FUNCTION = "configure_locale_time() {" + SOURCE.split(
    "configure_locale_time() {", 1)[1].split("\nconfigure_unattended_upgrades()", 1)[0]
COMMANDS = [
    "timedatectl set-timezone Asia/Irkutsk",
    "locale-gen ru_RU.UTF-8 en_US.UTF-8",
    "update-locale LANG=ru_RU.UTF-8",
]
SUCCESS = "Часовой пояс и локаль настроены"
ERRORS = [
    "Не удалось настроить часовой пояс Asia/Irkutsk",
    "Не удалось сгенерировать локали ru_RU.UTF-8 en_US.UTF-8",
    "Не удалось установить локаль LANG=ru_RU.UTF-8",
]


class ConfigureLocaleTimeTest(unittest.TestCase):
    def run_locale(self, failure="", part2=False, errexit=False):
        prelude = '''
set -o pipefail
section() { :; }
ok() { echo "OK: $*"; }
error() { echo "ERROR: $*" >&2; }
'''
        stubs = []
        for command in COMMANDS:
            name = command.split()[0]
            stubs.append(f'{name}() {{ echo "CMD:{name} $*"; '
                         f'return {23 if name == failure else 0}; }}')
        for name in STEPS:
            if name != "configure_locale_time":
                stubs.append(f'{name}() {{ echo STEP:{name}; return 0; }}')
        call = "part2_setup" if part2 else "configure_locale_time"
        return subprocess.run(
            [os.environ.get("BASH", "bash")],
            input=prelude + "\n".join(stubs) + "\n" + FUNCTION + "\n" + PART2
                  + ("\nset -e\n" if errexit else "\n") + f"{call} || exit $?\n",
            text=True, encoding="utf-8", capture_output=True, timeout=10)

    def assert_commands(self, result, expected):
        self.assertEqual([line.removeprefix("CMD:") for line in result.stdout.splitlines()
                          if line.startswith("CMD:")], expected)

    def assert_failure(self, index):
        for errexit in (False, True):
            with self.subTest(errexit=errexit):
                result = self.run_locale(COMMANDS[index].split()[0], errexit=errexit)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(result.stderr.strip(), "ERROR: " + ERRORS[index])
                self.assert_commands(result, COMMANDS[:index + 1])
                self.assertNotIn(SUCCESS, result.stdout + result.stderr)

    def test_timezone_failure(self):
        self.assert_failure(0)

    def test_locale_gen_failure(self):
        self.assert_failure(1)

    def test_update_locale_failure(self):
        self.assert_failure(2)

    def test_success(self):
        for errexit in (False, True):
            with self.subTest(errexit=errexit):
                result = self.run_locale(errexit=errexit)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr, "")
                self.assertEqual(result.stdout.splitlines(),
                                 ["CMD:" + command for command in COMMANDS] + ["OK: " + SUCCESS])

    def test_real_locale_failures_propagate_through_part2(self):
        for index, command in enumerate(COMMANDS):
            for errexit in (False, True):
                with self.subTest(command=command, errexit=errexit):
                    result = self.run_locale(command.split()[0], part2=True, errexit=errexit)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertEqual(result.stderr.strip(), "ERROR: " + ERRORS[index])
                    self.assert_commands(result, COMMANDS[:index + 1])
                    self.assertEqual([line for line in result.stdout.splitlines()
                                      if line.startswith("STEP:")], ["STEP:install_packages"])
                    self.assertNotIn(SUCCESS, result.stdout + result.stderr)
                    self.assertNotIn("Часть 2 завершена", result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
