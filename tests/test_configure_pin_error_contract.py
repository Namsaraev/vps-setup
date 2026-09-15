"""Isolated configure_pin input/probe contracts; never change system accounts.

Only /dev/tty is redirected to a disposable fixture. Real key parsing, atomic
writes and part2 orchestration run with temporary homes and account stubs.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_pin_key_permissions import FUNCTIONS, PRELUDE
from test_part2_error_propagation import PART2, STEPS


HARNESS = r'''
NEW_KEY=$(cat "$ROOT/new.pub")
printf '%s\n' "$NEW_KEY" > "$ROOT/tty"
id() { [ "$USER_EXISTS" = yes ]; }
adduser() { echo ADDUSER; }
usermod() { echo USERMOD; }
set_pin_password() { echo PASSWORD; }
yes_by_default() { [[ "$1" != [nN]* ]]; }
getent() {
  case "$PROBE" in
    getent-fail) return 23 ;;
    getent-partial) printf 'isolated_pin:x:1000:1000::%s/home:/bin/bash\n' "$ROOT"; return 23 ;;
    getent-malformed) printf 'isolated_pin:x:1000\n' ;;
    getent-multiple) printf 'isolated_pin:x:1000:1000::%s/home:/bin/bash\n' "$ROOT" "$ROOT" ;;
    getent-wrong-user) printf 'another:x:1000:1000::%s/home:/bin/bash\n' "$ROOT" ;;
    *) printf 'isolated_pin:x:1000:1000::%s/home:/bin/bash\n' "$ROOT" ;;
  esac
}
ask() {
  if [ "$2" = "$PROMPT" ]; then
    case "$INPUT_FAILURE" in
      eof) builtin read -r "$2" < /dev/null; return $? ;;
      partial) builtin read -r "$2" < <(printf partial); return $? ;;
      error) return 23 ;;
    esac
  fi
  case "$2" in
    action) printf -v "$2" '%s' "$ACTION" ;;
    answer) printf -v "$2" '%s' "$ANSWER" ;;
    method) printf -v "$2" '%s' "$METHOD" ;;
    keyfile) printf -v "$2" '%s' "$ROOT/new.pub" ;;
    *) return 91 ;;
  esac
}
read() {
  if [ "${*: -1}" = public_key ]; then
    case "$TTY_FAILURE" in
      eof) builtin read "$@" < /dev/null; return $? ;;
      partial) builtin read "$@" < <(printf partial); return $? ;;
      error) return 23 ;;
    esac
  fi
  builtin read "$@"
}
cat() {
  if [ "$PROBE" = cat-keyfile ] && [ "${*: -1}" = "$ROOT/new.pub" ]; then
    printf '%s' "$NEW_KEY"
    return 23
  fi
  if [ "$PROBE" = cat-keys ] && [ "${*: -1}" = "$keys_path" ]; then
    printf '%s' "$NEW_KEY"
    return 23
  fi
  command cat "$@"
}
if [ "$KEY_INPUT" = malformed ]; then
  printf 'ssh-ed25519 broken\n' > "$ROOT/new.pub"
  printf 'ssh-ed25519 broken\n' > "$ROOT/tty"
elif [ "$KEY_INPUT" = empty ]; then
  printf '\n' > "$ROOT/new.pub"
  printf '\n' > "$ROOT/tty"
fi
'''


class ConfigurePinContractTest(unittest.TestCase):
    def run_case(self, *, extra='', invocation='configure_pin', repeat=False, **env):
        settings = dict(FAILURE='', EXISTING='yes', ACTION='2', USER_EXISTS='yes',
                        PROBE='', PROMPT='', INPUT_FAILURE='', ANSWER='', METHOD='2',
                        TTY_FAILURE='', KEY_INPUT='valid')
        settings.update(env)
        stubs = '\n'.join(f'{name}() {{ echo STEP:{name}; }}'
                          for name in STEPS if name != 'configure_pin')
        tail = f'\nset -e\nstatus=0\n{invocation} || status=$?\necho FLAG:$PIN_HAS_KEY\n'
        if repeat:
            tail += 'configure_pin || status=$?\n'
        tail += 'exit "$status"\n'
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                [os.environ.get('BASH', 'bash')], cwd=directory,
                input=PRELUDE + FUNCTIONS.replace('/dev/tty', './tty') + '\n'
                      + HARNESS + stubs + '\n' + PART2 + '\n' + extra + tail,
                env=dict(os.environ, **settings), text=True, encoding='utf-8',
                capture_output=True, timeout=30)
            root = Path(directory)
            keys = root / 'home/.ssh/authorized_keys'
            return result, keys.read_bytes() if keys.is_file() else None, (
                root / 'old.pub').read_bytes().rstrip(b'\n'), (
                    (root / 'new.pub').read_bytes() if (root / 'new.pub').exists() else None)

    def assert_fatal(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ERROR:', result.stderr)
        self.assertNotIn('[OK] Ключ', result.stdout)
        self.assertNotIn('Часть 2 завершена', result.stdout + result.stderr)
        self.assertNotIn('STEP:configure_ssh', result.stdout)

    def test_each_distinct_prompt_eof_partial_and_read_error(self):
        for prompt in ('action', 'answer', 'method', 'keyfile'):
            for failure in ('eof', 'partial', 'error'):
                for part2 in (False, True):
                    with self.subTest(prompt=prompt, failure=failure, part2=part2):
                        result, content, old, _ = self.run_case(
                            PROMPT=prompt, INPUT_FAILURE=failure,
                            USER_EXISTS='no' if prompt == 'answer' else 'yes',
                            invocation='part2_setup' if part2 else 'configure_pin')
                        self.assert_fatal(result)
                        self.assertEqual(content, old)
                        self.assertNotIn('ADDUSER', result.stdout)

    def test_direct_tty_failures_existing_and_new_user(self):
        for existing in ('yes', 'no'):
            for failure in ('eof', 'partial', 'error'):
                with self.subTest(existing=existing, failure=failure):
                    result, content, old, _ = self.run_case(
                        USER_EXISTS=existing, METHOD='1', TTY_FAILURE=failure,
                        invocation='part2_setup')
                    self.assert_fatal(result)
                    self.assertEqual(content, old)

    def test_tty_open_failure(self):
        result, *_ = self.run_case(METHOD='1', extra='rm "$ROOT/tty"\n')
        self.assert_fatal(result)

    def test_keyfile_partial_read_failure(self):
        result, content, old, _ = self.run_case(PROBE='cat-keyfile', invocation='part2_setup')
        self.assert_fatal(result)
        self.assertEqual(content, old)

    def test_missing_keyfile(self):
        result, *_ = self.run_case(extra='rm "$ROOT/new.pub"\n')
        self.assert_fatal(result)
        self.assertIn('Файл не найден', result.stderr)

    def test_getent_failures_for_existing_and_new_user(self):
        for existing in ('yes', 'no'):
            for probe in ('getent-fail', 'getent-partial', 'getent-malformed',
                          'getent-multiple', 'getent-wrong-user'):
                with self.subTest(existing=existing, probe=probe):
                    result, content, old, _ = self.run_case(
                        USER_EXISTS=existing, PROBE=probe, invocation='part2_setup')
                    self.assert_fatal(result)
                    self.assertEqual(content, old)
                    self.assertNotIn('PASSWORD', result.stdout)

    def test_malformed_and_empty_input_keep_noop_policy(self):
        for key in ('malformed', 'empty'):
            for existing, action in (('yes', '2'), ('yes', '3'), ('no', '2')):
                with self.subTest(key=key, existing=existing, action=action):
                    result, content, old, _ = self.run_case(
                        KEY_INPUT=key, USER_EXISTS=existing, ACTION=action)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(content, old)
                    self.assertNotIn('[OK] Ключ', result.stdout)

    def test_successful_empty_prompt_defaults(self):
        for settings in ({'ACTION': ''}, {'METHOD': ''},
                         {'USER_EXISTS': 'no', 'ANSWER': '', 'KEY_INPUT': 'empty'}):
            with self.subTest(settings=settings):
                result, content, old, _ = self.run_case(**settings)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(content, old)
                if settings.get('USER_EXISTS') == 'no':
                    self.assertIn('ADDUSER', result.stdout)

    def test_fingerprint_operational_failure_input_initial_and_duplicate(self):
        for stage in ('input', 'initial', 'duplicate'):
            extra = {
                'input': 'mktemp() { return 23; }\n',
                'initial': 'mktemp() { return 23; }\n',
                'duplicate': '''
eval "$(declare -f authorized_keys_has_key | sed '1s/authorized_keys_has_key/original_has_key/')"
authorized_keys_has_key() {
  [ -z "${2:-}" ] || { error 'probe failure'; return 2; }
  original_has_key "$@"
}
''',
            }[stage]
            with self.subTest(stage=stage):
                result, content, old, _ = self.run_case(
                    extra=extra, EXISTING='no' if stage == 'input' else 'yes',
                    invocation='part2_setup')
                self.assert_fatal(result)
                self.assertEqual(content, None if stage == 'input' else old)

    def test_authorized_keys_partial_read_is_fatal_before_match(self):
        result, content, old, _ = self.run_case(PROBE='cat-keys', invocation='part2_setup')
        self.assert_fatal(result)
        self.assertEqual(content, old)

    def test_separator_printf_failure_preserves_keys(self):
        result, content, old, _ = self.run_case(extra=r'''
printf() {
  [ "$#" != 1 ] || [ "$1" != '\n' ] || return 23
  builtin printf "$@"
}
''', invocation='part2_setup')
        self.assert_fatal(result)
        self.assertEqual(content, old)

    def test_existing_add_replace_new_user_and_repeat(self):
        for existing, action in (('yes', '2'), ('yes', '3'), ('no', '2')):
            with self.subTest(existing=existing, action=action):
                # Repeat the new account as an existing account, just as real id would.
                extra = '''
id() { [ "$USER_EXISTS" = yes ] || [ -e "$ROOT/created" ]; }
adduser() { echo ADDUSER; touch "$ROOT/created"; }
'''
                result, content, old, new = self.run_case(
                    USER_EXISTS=existing, EXISTING=existing, ACTION=action,
                    extra=extra, repeat=True, invocation='part2_setup')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(content, old + b'\n' + new
                                 if existing == 'yes' and action == '2' else new)
                self.assertIn('FLAG:true', result.stdout)
                self.assertEqual(result.stdout.count('Часть 2 завершена'), 1)
                if action == '2':
                    self.assertEqual(result.stdout.count('\nMV\n'), 1)
                    self.assertIn('Этот публичный ключ уже установлен', result.stdout)

    def test_helper_invalid_dsa_options_and_no_match(self):
        extra = r'''
helper_checks() {
  local fp status
  for value in '' '# comment' 'ssh-ed25519 broken' $'one\ntwo'; do
    status=0; ssh_key_fingerprint "$value" || status=$?
    [ "$status" = 1 ] || return 91
  done
  ssh-keygen -q -t dsa -N '' -f "$ROOT/dsa" || return 92
  status=0; ssh_key_fingerprint "$(cat "$ROOT/dsa.pub")" || status=$?
  [ "$status" = 1 ] || return 93
  fp=$(ssh_key_fingerprint "$NEW_KEY") || return 94
  printf 'restrict,command="echo hello" %s changed-comment' "$NEW_KEY" > "$keys_path"
  authorized_keys_has_key "$keys_path" "$fp" || return 95
  status=0; authorized_keys_has_key "$keys_path" SHA256:nomatch || status=$?
  [ "$status" = 1 ] || return 96
  status=0; authorized_keys_has_key "$ROOT/missing" || status=$?
  [ "$status" = 1 ] || return 97
  printf '# only comments\nmalformed' > "$keys_path"
  status=0; authorized_keys_has_key "$keys_path" || status=$?
  [ "$status" = 1 ] || return 98
}
'''
        result, *_ = self.run_case(extra=extra, invocation='helper_checks')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_helper_operational_failures(self):
        failures = {
            'mktemp': 'mktemp() { return 23; }',
            'temp-write': r'''printf() { [ "$1" != '%s\n' ] || return 23; builtin printf "$@"; }''',
            'execution': 'ssh-keygen() { return 127; }',
            'read': "ssh-keygen() { echo 'read failed' >&2; return 1; }",
            'temp-read': 'cat() { return 23; }',
            'temp-partial-read': 'cat() { printf partial; return 23; }',
            'empty-output': 'ssh-keygen() { return 0; }',
            'cleanup': 'rm() { return 23; }',
            'output-write': r'''printf() { [[ "${2:-}" != SHA256:* ]] || return 23; builtin printf "$@"; }''',
        }
        for label, stub in failures.items():
            with self.subTest(label=label):
                result, *_ = self.run_case(extra=stub + '\n',
                                           invocation='ssh_key_fingerprint "$NEW_KEY"')
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('ERROR:', result.stderr)

    def test_id_execution_failure(self):
        result, *_ = self.run_case(extra='id() { return 127; }\n', invocation='part2_setup')
        self.assert_fatal(result)
        self.assertNotIn('ADDUSER', result.stdout)

    def test_final_validation_operational_failure(self):
        result, *_ = self.run_case(extra=r'''
eval "$(declare -f authorized_keys_has_key | sed '1s/authorized_keys_has_key/original_has_key/')"
probe_count=0
authorized_keys_has_key() {
  probe_count=$((probe_count + 1))
  if [ "$probe_count" = 3 ]; then error 'final probe failed'; return 2; fi
  original_has_key "$@"
}
''', invocation='part2_setup')
        self.assert_fatal(result)
        self.assertIn('FLAG:false', result.stdout)

    def test_unreadable_regular_file_is_ordinary_no_match(self):
        # Stub only the readability predicate: deterministic even when run as root.
        result, *_ = self.run_case(extra=r'''
function [ {
  if builtin [ "$#" = 2 ] && builtin [ "$1" = -r ] && builtin [ "$2" = "$keys_path" ]; then
    return 1
  fi
  builtin [ "$@"
}
''', invocation='authorized_keys_has_key "$keys_path"')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn('ERROR:', result.stderr)

    def test_helper_directory_and_loop_read_error(self):
        for extra, invocation in (
            ('', 'authorized_keys_has_key "$ROOT/home"'),
            ('read() { return 23; }\n', 'authorized_keys_has_key "$keys_path"'),
        ):
            with self.subTest(invocation=invocation):
                result, *_ = self.run_case(extra=extra, invocation=invocation)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn('ERROR:', result.stderr)


if __name__ == '__main__':
    unittest.main()
