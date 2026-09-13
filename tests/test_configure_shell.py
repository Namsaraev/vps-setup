"""Isolated configure_shell tests: python3 -m unittest discover -s tests -v.

No sudo, network, shell changes, or writes outside a temporary home.
On POSIX, ownership is checked against the executing user's real UID.
"""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "tunevps.sh").read_text(encoding="utf-8")
FUNCTION = SOURCE.split("configure_shell() {", 1)[1].split("\nfinal_check()", 1)[0]
FUNCTION = "configure_shell() {" + FUNCTION
BLOCK = (b'# >>> tunevps managed block >>>\n'
         b'source "$HOME/.config/tunevps/zshrc"\n'
         b'# <<< tunevps managed block <<<\n')


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

    def run_shell(self, success=True):
        # Only external/system operations are replaced. mkdir, tee and Python
        # execute normally, exercising the actual function and heredocs.
        prelude = '''
section() { :; }
ok() { :; }
info() { :; }
chsh() { :; }
git() { echo "unexpected network call" >&2; return 99; }
as_current_user() {
  if [ "$1" = python3 ]; then
    shift
    "$TEST_PYTHON" "$@"
  else
    "$@"
  fi
}
'''
        env = dict(os.environ, USER_HOME=self.home.as_posix(), CURRENT_USER="test-user",
                   TEST_PYTHON=Path(sys.executable).as_posix())
        result = subprocess.run([os.environ.get("BASH", "bash")],
                                input=prelude + FUNCTION + "\nconfigure_shell\n",
                                text=True, encoding="utf-8", capture_output=True, env=env)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        if not success:
            self.assertIn("Invalid or duplicate tunevps managed markers", result.stderr)
        if success and os.name == "posix":
            for path in (self.rc, self.managed, self.managed.parent):
                self.assertEqual(path.stat().st_uid, os.getuid())

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
                self.run_shell(success=False)
                self.assertEqual(self.rc.read_bytes(), user)


if __name__ == "__main__":
    unittest.main()
