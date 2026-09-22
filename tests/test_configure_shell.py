"""Isolated configure_shell tests: python3 -m unittest discover -s tests -v.

No sudo, network, shell changes, or writes outside a temporary home.
On POSIX, ownership is checked against the executing user's real UID.
"""
import os
from atomic_support import HELPER, WRAPPER
import shutil
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from test_part2_error_propagation import PART2, STEPS

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tunevps.sh").read_text(encoding="utf-8")
FUNCTION = SOURCE.split("configure_shell() {", 1)[1].split("\nfinal_check()", 1)[0]
FUNCTION = "configure_shell() {" + FUNCTION
BLOCK = (b'# >>> tunevps managed block >>>\n'
         b'source "$HOME/.config/tunevps/zshrc"\n'
         b'# <<< tunevps managed block <<<\n')


FUNCTION = HELPER + "\n" + FUNCTION


class ConfigureShellTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="tunevps test ")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.rc = self.home / ".zshrc"
        self.managed = self.home / ".config/tunevps/zshrc"
        custom = self.home / ".oh-my-zsh/custom"
        for name in ("themes/powerlevel10k", "plugins/zsh-autosuggestions",
                     "plugins/zsh-syntax-highlighting", "plugins/zsh-completions"):
            (custom / name).mkdir(parents=True)

    def run_shell(self, success=True, failure="", part2=False):
        # Only external/system operations are replaced. mkdir, tee and Python
        # execute normally, exercising the actual function and heredocs.
        prelude = '''
section() { :; }
ok() { echo "OK: $*"; }
info() { :; }
error() { echo "ERROR: $*" >&2; }
chsh() {
  echo "CALL:chsh:$*"
  [ "$*" = '-s /usr/bin/zsh test-user' ] || return 98
  [ "$FAILURE" != chsh ]
}
git() {
  local destination="${@: -1}"
  echo "CALL:clone:${destination##*/}"
  [ "$FAILURE" != "${destination##*/}" ] || return 23
  mkdir -p "$destination"
}
as_current_user() {
  echo "CALL:$1" >&2
  [ "$FAILURE" != "$1" ] || return 23
  if [ "$1" = python3 ]; then
    shift
    "$TEST_PYTHON" "$TEST_ATOMIC_WRAPPER" "$@"
  else
    "$@"
  fi
}
'''
        env = dict(os.environ, USER_HOME=self.home.as_posix(), CURRENT_USER="test-user",
                   TEST_PYTHON=Path(sys.executable).as_posix(), FAILURE=failure,
                   TEST_ATOMIC_WRAPPER=WRAPPER.as_posix(),
                   P10K_REPOSITORY="https://example.invalid/p10k.git")
        invocation = "configure_shell || exit $?\n"
        if part2:
            prelude += "\n".join(f'{step}() {{ echo "STEP:{step}"; }}'
                                 for step in STEPS if step != "configure_shell") + "\n"
            invocation = PART2 + "\npart2_setup || exit $?\n"
        result = subprocess.run([os.environ.get("BASH", "bash")],
                                input=prelude + FUNCTION + "\n" + invocation,
                                text=True, encoding="utf-8", capture_output=True, env=env,
                                timeout=15)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        if not success:
            self.assertIn("ERROR:", result.stderr)
            self.assertNotIn("OK:", result.stdout)
            self.assertNotIn("Часть 2 завершена", result.stdout + result.stderr)
        if success and os.name == "posix":
            for path in (self.rc, self.managed, self.managed.parent):
                self.assertEqual(path.stat().st_uid, os.getuid())
        return result

    def test_install_success_and_repeat_without_cloning(self):
        shutil.rmtree(self.home / ".oh-my-zsh")
        result = self.run_shell()
        self.assertEqual(result.stdout.count("CALL:clone:"), 5)
        first = self.rc.read_bytes(), self.managed.read_bytes()
        sentinel = self.home / ".oh-my-zsh/custom/user-file"
        sentinel.write_bytes(b"keep")
        result = self.run_shell()
        self.assertNotIn("CALL:clone:", result.stdout)
        self.assertEqual((self.rc.read_bytes(), self.managed.read_bytes()), first)
        self.assertEqual(sentinel.read_bytes(), b"keep")

    def test_install_failures_stop_before_config_and_propagate(self):
        for failure in ("chsh", ".oh-my-zsh", "powerlevel10k",
                        "zsh-autosuggestions", "zsh-syntax-highlighting", "zsh-completions"):
            for part2 in (False, True):
                with self.subTest(failure=failure, part2=part2):
                    shutil.rmtree(self.home / ".oh-my-zsh", ignore_errors=True)
                    self.rc.write_bytes(b"# user data\n")
                    result = self.run_shell(success=False, failure=failure, part2=part2)
                    self.assertEqual(result.returncode, 1)
                    self.assertNotIn("CALL:mkdir", result.stderr)
                    self.assertNotIn("STEP:final_check", result.stdout)
                    self.assertFalse(self.managed.exists())
                    self.assertEqual(self.rc.read_bytes(), b"# user data\n")
                    clones = [line for line in result.stdout.splitlines()
                              if line.startswith("CALL:clone:")]
                    expected = [".oh-my-zsh", "powerlevel10k", "zsh-autosuggestions",
                                "zsh-syntax-highlighting", "zsh-completions"]
                    count = 0 if failure == "chsh" else expected.index(failure) + 1
                    self.assertEqual(clones, ["CALL:clone:" + x for x in expected[:count]])

    def test_config_failures_stop_and_propagate(self):
        for failure in ("mkdir", "python3"):
            for part2 in (False, True):
                with self.subTest(failure=failure, part2=part2):
                    self.rc.write_bytes(b"# user data\n")
                    result = self.run_shell(success=False, failure=failure, part2=part2)
                    self.assertEqual(result.returncode, 1)
                    self.assertNotIn("STEP:final_check", result.stdout)
                    self.assertEqual(self.rc.read_bytes(), b"# user data\n")
                    if failure == "mkdir":
                        self.assertNotIn("CALL:python3", result.stderr)
                    if failure != "python3":
                        self.assertNotIn("CALL:python3", result.stderr)

    def test_real_directory_failure(self):
        (self.home / ".config").write_bytes(b"keep")
        self.run_shell(success=False)
        self.assertEqual((self.home / ".config").read_bytes(), b"keep")
        self.assertFalse(self.rc.exists())

    def test_real_write_failure(self):
        self.managed.mkdir(parents=True)
        self.run_shell(success=False)
        self.assertTrue(self.managed.is_dir())
        self.assertFalse(self.rc.exists())

    def test_missing_zshrc(self):
        self.run_shell()
        self.assertEqual(self.rc.read_bytes(), BLOCK)
        expected = FUNCTION.split("<<'EOF'\n", 1)[1].split("\nEOF", 1)[0] + "\n"
        self.assertEqual(self.managed.read_bytes(), expected.encode())

    def test_existing_user_zshrc(self):
        user = b'# user config\r\nexport VALUE="a\\b"\r\n# non-UTF8: \xff\nlast line'
        self.rc.write_bytes(user)
        self.run_shell()
        self.assertEqual(self.rc.read_bytes(), BLOCK + user)

    def test_repeated_run(self):
        self.rc.write_bytes(b'alias mine="echo keep"\n')
        self.run_shell()
        first = self.rc.read_bytes(), self.managed.read_bytes()
        self.run_shell()
        self.assertEqual((self.rc.read_bytes(), self.managed.read_bytes()), first)
        self.assertEqual(self.rc.read_bytes().count(BLOCK), 1)

    def test_existing_managed_block(self):
        before, after = b'# before\r\n', b'export AFTER=yes\n# tail'
        old = BLOCK.replace(b'source "$HOME/.config/tunevps/zshrc"', b'echo outdated')
        self.rc.write_bytes(before + old + after)
        self.run_shell()
        self.assertEqual(self.rc.read_bytes(), before + BLOCK + after)
        self.run_shell()
        self.assertEqual(self.rc.read_bytes(), before + BLOCK + after)

    def test_invalid_markers_preserve_user_file(self):
        for user in (BLOCK + BLOCK, b'# >>> tunevps managed block >>>\nuser data\n'):
            with self.subTest(user=user):
                self.rc.write_bytes(user)
                result = self.run_shell(success=False)
                self.assertIn("Invalid or duplicate tunevps managed markers", result.stderr)
                self.assertEqual(self.rc.read_bytes(), user)


if __name__ == "__main__":
    unittest.main()
