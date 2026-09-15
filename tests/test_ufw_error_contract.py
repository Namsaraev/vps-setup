"""UFW error contracts using real functions and harmless shell/read stubs."""
import unittest

import test_configure_ufw as existing

COMMANDS = existing.COMMANDS


class UfwErrorContractTest(unittest.TestCase):
    run_ufw = existing.ConfigureUfwTest.run_ufw
    mutations = existing.ConfigureUfwTest.mutations

    def assert_failed(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('ERROR:', result.stderr)
        self.assertNotIn('Часть 2 завершена', result.stdout)
        self.assertNotIn('STEP:configure_shell', result.stdout)

    def test_direct_status_contract(self):
        for active, expected in ((True, 0), (False, 1)):
            result = self.run_ufw(active=active, call_override='ufw_is_active')
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertNotIn('ERROR:', result.stderr)
            self.assertEqual(self.mutations(result), [])

    def test_status_failure_direct_preflight_and_part2(self):
        for call in ('ufw_is_active', 'ensure_ufw_ssh_port', 'configure_ufw', 'part2_setup'):
            for pipefail in (False, True):
                for errexit in (False, True):
                    with self.subTest(call=call, pipefail=pipefail, errexit=errexit):
                        result = self.run_ufw(call_override=call, failure='status',
                                              pipefail=pipefail, errexit=errexit)
                        self.assertEqual(result.returncode, 2, result.stderr)
                        self.assert_failed(result)
                        self.assertEqual(self.mutations(result), [])
                        self.assertNotIn('OK:', result.stdout)
                        self.assertNotIn('iPerf3:', result.stdout)

    def test_inactive_preflight_noop_and_missing_binary(self):
        result = self.run_ufw(call_override='ensure_ufw_ssh_port')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), [])
        result = self.run_ufw(call_override='ensure_ufw_ssh_port', missing_ufw=True)
        self.assert_failed(result)
        self.assertEqual(self.mutations(result), [])

    def test_later_status_failure_even_with_valid_stdout(self):
        # Status 2 is preflight; status 3 verifies the added SSH rule.
        for at, mutations in ((2, []), (3, [COMMANDS[2]])):
            for pipefail in (False, True):
                result = self.run_ufw(active=True, status_failure_at=at,
                                      part2=True, pipefail=pipefail)
                self.assert_failed(result)
                self.assertEqual(self.mutations(result), mutations)
                self.assertNotIn('OK:', result.stdout)

    def test_each_prompt_read_failure_stops_direct_and_part2(self):
        for prompt, action in (('answer', ''), ('action', ''), ('source_ip', '2')):
            for part2 in (False, True):
                for errexit in (False, True):
                    with self.subTest(prompt=prompt, part2=part2, errexit=errexit):
                        result = self.run_ufw(refuse=True, ask_failure=prompt,
                                              action=action, part2=part2, errexit=errexit)
                        self.assert_failed(result)
                        self.assertEqual(self.mutations(result), [])
                        self.assertNotIn('OK:', result.stdout)
                        self.assertNotIn('Правила iPerf3 не изменены', result.stdout)

    def test_active_optional_prompt_failure(self):
        result = self.run_ufw(active=True, ask_failure='action', part2=True)
        self.assert_failed(result)
        self.assertEqual(self.mutations(result), [COMMANDS[2]])

    def test_closed_input_descriptor_at_each_prompt(self):
        for prompt, action in (('answer', ''), ('action', ''), ('source_ip', '2')):
            result = self.run_ufw(refuse=True, ask_failure=prompt, action=action,
                                  read_error=True, part2=True)
            self.assert_failed(result)
            self.assertEqual(self.mutations(result), [])
            self.assertNotIn('OK:', result.stdout)

    def test_failure_after_enable_has_no_later_success(self):
        result = self.run_ufw(ask_failure='action', part2=True)
        self.assert_failed(result)
        self.assertEqual(self.mutations(result), COMMANDS)
        # Earlier enable success describes a completed operation, not the failed bundle.
        self.assertNotIn('OK:', result.stdout.split('iPerf3:', 1)[1])

    def test_invalid_iperf_input_aborts(self):
        for ip in ('', 'not-an-ip', '192.0.2.1/24', 'host;command'):
            for part2 in (False, True):
                result = self.run_ufw(refuse=True, action='2', source_ip=ip, part2=part2)
                self.assert_failed(result)
                self.assertEqual(self.mutations(result), [])
                self.assertNotIn('OK:', result.stdout)

    def test_empty_answers_preserve_defaults(self):
        result = self.run_ufw(part2=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), COMMANDS)
        self.assertIn('Правила iPerf3 не изменены', result.stdout)
        self.assertIn('Часть 2 завершена', result.stdout)

    def test_optional_refusal_is_repeatable_noop(self):
        result = self.run_ufw(refuse=True, repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), [])
        self.assertEqual(result.stdout.count('Правила iPerf3 не изменены'), 2)

    def test_active_repeat_keeps_only_ssh_allow(self):
        result = self.run_ufw(active=True, repeat=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), [COMMANDS[2]] * 2)

    def test_ipv6_optional_success_unchanged(self):
        result = self.run_ufw(refuse=True, action='2', source_ip='2001:db8::1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), [
            'allow from 2001:db8::1 to any port 5201 proto tcp',
            'allow from 2001:db8::1 to any port 5201 proto udp'])


if __name__ == '__main__':
    unittest.main()
