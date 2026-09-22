"""Access/input bundle: only extracted functions, temporary files and stubs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_configure_swap as swap
import test_ssh_error_contract as ssh

SOURCE = ssh.SOURCE
ASK = 'ask() {' + SOURCE.split('ask() {', 1)[1].split('\nask_password()', 1)[0]
BOOT = 'CURRENT_USER=' + SOURCE.split('CURRENT_USER=', 1)[1].split('\n. /etc/os-release', 1)[0]
POLICY = ('port 5829', 'passwordauthentication no', 'pubkeyauthentication yes',
          'permitrootlogin no', 'kbdinteractiveauthentication no', 'maxauthtries 3')
INPUT_FAILURES = (
    'return 23',
    'builtin read -r "$2" < /dev/null',
    'builtin read -r "$2" < <(printf y)',
)


def run(script, cwd=None):
    return subprocess.run([os.environ.get('BASH', 'bash')], input=script,
                          cwd=cwd, text=True, encoding='utf-8', capture_output=True,
                          timeout=15)


class AskContractTest(unittest.TestCase):
    def invoke(self, body='', data='y\n', write_path='./prompt', read_path='./input'):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'input').write_text(data, encoding='utf-8')
            Path(directory, 'blocked').mkdir()
            function = ASK.replace('> /dev/tty', '> ' + write_path).replace(
                '< /dev/tty', '< ' + read_path)
            return run(function + '\n' + body + '\nanswer=old\n'
                       'ask "Confirm?" answer; status=$?\n'
                       'echo "VALUE:$answer"\nexit "$status"\n', directory)

    def test_prompt_open_failure_does_not_read(self):
        result = self.invoke('read() { echo READ >&2; return 0; }', write_path='./blocked')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('READ', result.stderr)

    def test_prompt_write_failure_does_not_read(self):
        result = self.invoke('printf() { return 23; }; read() { echo READ >&2; }')
        self.assertEqual(result.returncode, 23)
        self.assertNotIn('READ', result.stderr)

    def test_eof_and_partial_y_fail(self):
        for data in ('', 'y'):
            with self.subTest(data=data):
                self.assertNotEqual(self.invoke(data=data).returncode, 0)

    def test_read_error_and_open_failure(self):
        self.assertEqual(self.invoke('read() { return 23; }').returncode, 23)
        self.assertNotEqual(self.invoke(read_path='./missing').returncode, 0)

    def test_empty_enter_and_yes_succeed(self):
        for data in ('\n', 'y\n'):
            result = self.invoke(data=data)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('VALUE:' + data, result.stdout)


class BundleIntegrationTest(unittest.TestCase):
    def run_ssh(self, setup='', **kwargs):
        return ssh.SshErrorContractTest().run_ssh(extra_setup=setup, **kwargs)

    def assert_stopped(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        for step in ('configure_ufw', 'configure_shell', 'final_check'):
            self.assertNotIn('STEP:' + step, result.stdout)
        self.assertNotIn('Часть 2 завершена', result.stdout)

    def test_both_swap_prompts_fail_before_mutation(self):
        for active in ('/swapfile 1073741824 file\n', '/dev/sda2 1073741824 partition\n'):
            for failure in INPUT_FAILURES:
                with self.subTest(active=active, failure=failure):
                    result, calls, fstab = swap.SwapTest().run_swap(
                        active=active, extra_setup='ask() { ' + failure + '; }')
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(calls, '')
                    self.assertEqual(fstab, swap.FSTAB)

    def test_ssh_prompt_failure_has_no_mutations(self):
        for failure in INPUT_FAILURES:
            for errexit in (False, True):
                with self.subTest(failure=failure, errexit=errexit):
                    result, calls, config = self.run_ssh(
                        'ask() { ' + failure + '; }', outer=True, errexit=errexit)
                    self.assert_stopped(result)
                    self.assertEqual(calls, 'sshd -T\n')
                    self.assertEqual(config, '#Port 22\n')

    def test_explicit_skip_stops_part2_without_generic_error(self):
        for answer in ('n', 'N', ''):
            for errexit in (False, True):
                with self.subTest(answer=answer, errexit=errexit):
                    result, calls, config = self.run_ssh(
                        'ask() { printf -v "$2" "%s" "' + answer + '"; }',
                        outer=True, errexit=errexit)
                    self.assertEqual(result.returncode, 3, result.stderr)
                    self.assert_stopped(result)
                    self.assertNotIn('ERROR:', result.stderr)
                    self.assertIn('SSH пропущен', result.stdout)
                    self.assertEqual(calls, 'sshd -T\n')
                    self.assertEqual(config, '#Port 22\n')

    def test_compliant_fast_path_proceeds_without_prompt_or_mutation(self):
        result, calls, config = self.run_ssh(
            'command touch "$ROOT/applied"\nask() { return 99; }', outer=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, 'sshd -T\nlistener\n')
        self.assertEqual(config, '#Port 22\n')
        self.assertIn('Часть 2 завершена', result.stdout)

    def test_ssh_getent_invalid_results_stop_before_probes(self):
        records = ('return 23',
                   'echo "fixture:x:1000:1000::$ROOT/home:/bin/bash"; return 23',
                   'echo fixture:x:1000',
                   'printf "fixture:x:1000:1000::%s/home:/bin/bash\\n" "$ROOT" "$ROOT"',
                   'echo "other:x:1000:1000::$ROOT/home:/bin/bash"')
        for body in records:
            with self.subTest(body=body):
                result, calls, _ = self.run_ssh('getent() { ' + body + '; }', outer=True)
                self.assert_stopped(result)
                self.assertEqual(calls, '')

    def test_custom_home_is_used_for_key_probe(self):
        result, _, _ = self.run_ssh(
            'authorized_keys_has_key() { [[ "$1" == "$ROOT/home/.ssh/authorized_keys" ]]; }')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_key_no_match_and_operational_failure_are_distinct(self):
        for status, message, absent in ((1, 'НЕТ SSH-ключа', 'Не удалось проверить ключи'),
                                        (2, 'Не удалось проверить ключи', 'НЕТ SSH-ключа')):
            with self.subTest(status=status):
                result, calls, _ = self.run_ssh(
                    f'authorized_keys_has_key() {{ return {status}; }}', outer=True)
                self.assert_stopped(result)
                self.assertIn(message, result.stderr)
                self.assertNotIn(absent, result.stderr)
                self.assertEqual(calls, '')

    def post_apply(self, policy=POLICY, status=0):
        output = ' '.join("'" + line + "'" for line in policy)
        return self.run_ssh('''
eval "$(declare -f sshd | sed '1s/sshd/original_sshd/')"
sshd() {
  if [[ "$1" == -T && -e "$ROOT/applied" ]]; then
    op post-apply
    printf '%s\\n' ''' + output + '\n    return ' + str(status) + '''
  fi
  original_sshd "$@"
}
''', outer=True)

    def test_each_post_apply_required_field_mismatch_is_fatal(self):
        for index, field in enumerate(POLICY):
            for replacement in ('invalid', ''):
                with self.subTest(field=field, replacement=replacement):
                    policy = list(POLICY)
                    policy[index] = field.split()[0] + ' ' + replacement
                    result, calls, _ = self.post_apply(policy)
                    self.assert_stopped(result)
                    self.assertIn(field.split()[0], result.stderr)
                    self.assertEqual(calls.count('post-apply\n'), 1)

    def test_post_apply_failed_capture_rejects_valid_partial_output(self):
        result, calls, _ = self.post_apply(status=23)
        self.assert_stopped(result)
        self.assertIn('Не удалось получить итоговую', result.stderr)
        self.assertEqual(calls.count('post-apply\n'), 1)

    def test_post_apply_happy_path_uses_one_snapshot(self):
        result, calls, _ = self.post_apply()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count('post-apply\n'), 1)
        self.assertIn('Часть 2 завершена', result.stdout)


class BootstrapContractTest(unittest.TestCase):
    def bootstrap(self, body, user='fixture'):
        with tempfile.TemporaryDirectory() as directory:
            return run('error() { echo "$*" >&2; }; id() { return 0; }\n'
                       'SUDO_USER=' + user + '\ngetent() { ' + body + '; }\n' +
                       BOOT + '\nprintf "HOME:%s USER:%s\\n" "$USER_HOME" "$CURRENT_USER"',
                       directory)

    def test_getent_failure_malformed_multiple_wrong_user_are_fatal(self):
        for body in ('return 23', 'echo "fixture:x:1000:1000::$PWD:/bin/bash"; return 23',
                     'echo fixture:x:1000',
                     'printf "fixture:x:1000:1000::%s:/bin/bash\\n" "$PWD" "$PWD"',
                     'echo "other:x:1000:1000::$PWD:/bin/bash"'):
            with self.subTest(body=body):
                result = self.bootstrap(body)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn('HOME:', result.stdout)

    def test_custom_home_and_sudo_user_are_preserved(self):
        result = self.bootstrap('echo "fixture:x:1000:1000::$PWD:/bin/bash"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('USER:fixture', result.stdout)
        self.assertNotIn('/home/fixture', result.stdout)

    def test_empty_sudo_user_still_defaults_to_root(self):
        result = self.bootstrap('echo "root:x:0:0::$PWD:/bin/bash"', user='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('USER:root', result.stdout)
