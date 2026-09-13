"""Only execute configure_needrestart against a temporary configuration file."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SOURCE = (Path(__file__).resolve().parents[1] / 'tunevps.sh').read_text(encoding='utf-8')
FUNCTION = 'configure_needrestart() {' + SOURCE.split('configure_needrestart() {', 1)[1].split('\nconfigure_safe_sysctl()', 1)[0]
SUCCESS = 'Автоматический перезапуск включён'
AUTO = b'$nrconf{restart} = "a";\n'
PRELUDE = r'''
set -euo pipefail
section() { :; }
info() { echo "INFO: $*"; }
warn() { echo "WARN: $*"; }
ok() { echo "OK: $*"; }
error() { echo "ERROR: $*" >&2; }
ask() { echo PROMPT; read -r "$2"; }
python3() { "$PYTHON" "$WRAPPER" "$@"; }
'''
WRAPPER = r'''
import os
from pathlib import Path
import sys
from unittest.mock import patch

sys.argv = sys.argv[1:]
source = sys.stdin.read()
mode = os.environ.get('FAILURE', '')
replace = os.replace
def injected_replace(src, dst):
    if mode == 'write':
        raise OSError('injected write failure')
    replace(src, dst)
    if mode == 'validation':
        Path(dst).write_bytes(b'$nrconf{restart} = "q";\n')

# Native Windows lacks chown. Linux runs the real ownership operation.
if os.name == 'nt':
    os.chown = lambda *args: None
with patch('os.replace', injected_replace):
    exec(compile(source, '<needrestart helper>', 'exec'))
'''


class NeedrestartTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='needrestart test ')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'needrestart.conf'
        self.wrapper = self.root / 'runner.py'
        self.wrapper.write_text(WRAPPER, encoding='utf-8')

    def run_configure(self, answers='y\ny\n', failure=''):
        function = FUNCTION.replace('/etc/needrestart/needrestart.conf', '"$CONFIG"')
        script = self.root / 'run.sh'
        script.write_text(PRELUDE + function + '\nconfigure_needrestart\n', encoding='utf-8', newline='\n')
        result = subprocess.run(
            [os.environ.get('BASH', 'bash'), script.as_posix()], input=answers.encode('utf-8'),
            capture_output=True, timeout=15,
            env=dict(os.environ, CONFIG=self.config.as_posix(),
                     PYTHON=Path(sys.executable).as_posix(),
                     WRAPPER=self.wrapper.as_posix(), FAILURE=failure, PYTHONIOENCODING='utf-8'))
        result.stdout = result.stdout.decode('utf-8')
        result.stderr = result.stderr.decode('utf-8')
        return result

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(SUCCESS, result.stdout)
        self.assertEqual(result.stdout.count('PROMPT'), 2)

    def assert_failure(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ERROR:', result.stderr)
        self.assertNotIn(SUCCESS, result.stdout + result.stderr)
        self.assertEqual(list(self.root.glob('.needrestart-*')), [])

    def test_active_q(self):
        self.config.write_bytes(b"$nrconf{restart} = 'q';\n")
        self.assert_success(self.run_configure())
        self.assertEqual(self.config.read_bytes(), AUTO)

    def test_commented(self):
        self.config.write_bytes(b"#$nrconf{restart} = 'i';\n")
        self.assert_success(self.run_configure())
        self.assertEqual(self.config.read_bytes(), AUTO)

    def test_missing_setting(self):
        for original in (b'', b'# other\n$nrconf{verbosity} = 2;'):
            with self.subTest(original=original):
                self.config.write_bytes(original)
                self.assert_success(self.run_configure())
                self.assertEqual(self.config.read_bytes(), original + (b'\n' if original else b'') + AUTO)

    def test_spacing_comments_and_duplicates(self):
        self.config.write_bytes(b"# unrelated\r\n  # $nrconf { restart }= 'q' ; # keep\r\n$nrconf{'restart'}='i';\n")
        self.assert_success(self.run_configure())
        self.assertEqual(self.config.read_bytes(), b'# unrelated\r\n  $nrconf{restart} = "a"; # keep\r\n' + AUTO)

    def test_already_a_is_noop(self):
        original = b"  $nrconf { restart } = 'a'; # keep\n"
        self.config.write_bytes(original)
        before = self.config.stat()
        for _ in range(2):
            self.assert_success(self.run_configure())
            self.assertEqual(self.config.read_bytes(), original)
            self.assertEqual(self.config.stat().st_mtime_ns, before.st_mtime_ns)
            self.assertEqual(self.config.stat().st_ino, before.st_ino)

    def test_comment_cannot_supply_active_value(self):
        self.config.write_bytes(b"$nrconf{restart}='q'; # example = 'a'\n")
        self.assert_success(self.run_configure())
        self.assertEqual(self.config.read_bytes(), b'$nrconf{restart} = "a"; # example = \'a\'\n')

    def test_repeat_and_metadata(self):
        self.config.write_bytes(b"$nrconf{restart}='q';\n")
        self.config.chmod(0o640)
        before = self.config.stat()
        self.assert_success(self.run_configure())
        after = self.config.stat()
        self.assert_success(self.run_configure())
        self.assertEqual(self.config.read_bytes(), AUTO)
        self.assertEqual(self.config.stat().st_mtime_ns, after.st_mtime_ns)
        self.assertEqual(after.st_mode, before.st_mode)
        self.assertEqual((after.st_uid, after.st_gid), (before.st_uid, before.st_gid))

    def test_first_refusal(self):
        self.check_refusal('n\n', 1)

    def test_second_refusal(self):
        self.check_refusal('y\nn\n', 2)

    def check_refusal(self, answers, prompts):
        self.config.write_bytes(AUTO)
        before = self.config.stat()
        result = self.run_configure(answers)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn(SUCCESS, result.stdout)
        self.assertEqual(result.stdout.count('PROMPT'), prompts)
        self.assertEqual(self.config.read_bytes(), AUTO)
        self.assertEqual(self.config.stat().st_mtime_ns, before.st_mtime_ns)

    def test_write_failure(self):
        original = b"$nrconf{restart}='q';\n"
        self.config.write_bytes(original)
        self.assert_failure(self.run_configure(failure='write'))
        self.assertEqual(self.config.read_bytes(), original)

    def test_validation_failure(self):
        self.config.write_bytes(b"$nrconf{restart}='q';\n")
        self.assert_failure(self.run_configure(failure='validation'))

    def test_missing_file(self):
        self.assert_failure(self.run_configure())
        self.assertFalse(self.config.exists())

    def test_unsupported_expression(self):
        original = b'$nrconf{restart} = get_mode();\n'
        self.config.write_bytes(original)
        self.assert_failure(self.run_configure())
        self.assertEqual(self.config.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
