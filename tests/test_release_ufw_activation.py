"""Saved inactive UFW policy must be checked before enabling; no host firewall."""
import os
import shlex
import sys
from pathlib import Path
import unittest

import test_configure_ufw as fixture
from test_access_release_blockers import run


# Reproduce the same callers on the audited main, without changing its bytes.
if os.environ.get('RELEASE_AUDIT_SOURCE'):
    source = Path(os.environ['RELEASE_AUDIT_SOURCE']).read_text(encoding='utf-8')
    helper = 'access_safety() {' + source.split('access_safety() {', 1)[1].split('\ncheck_ssh_port()', 1)[0]
    if os.name == 'nt':
        helper += '\npython3() { ' + shlex.quote(Path(sys.executable).as_posix()) + ' "$@"; }\n'
    fixture.FUNCTIONS = helper + '\nufw_is_active() {' + source.split('ufw_is_active() {', 1)[1].split('\nset_sshd_line()', 1)[0]


HEADER = "Added user rules (see 'ufw status' for running firewall):\n"


class SavedUfwActivationTest(unittest.TestCase):
    run_ufw = fixture.ConfigureUfwTest.run_ufw
    mutations = fixture.ConfigureUfwTest.mutations

    def failed_before_mutation(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.mutations(result), [])
        self.assertNotIn(fixture.SUCCESS, result.stdout)
        self.assertNotIn('STEP:configure_shell', result.stdout)
        self.assertNotIn('STEP:final_check', result.stdout)

    def test_saved_deny_reject_limit_stop_direct_and_part2_before_enable(self):
        for policy in ('ufw deny 5829/tcp', 'ufw reject 5829', 'ufw limit 5829/tcp',
                       'ufw deny in log 5829/tcp comment "saved rule"',
                       'ufw deny from 2001:db8::/32 to any port 5829 proto tcp',
                       'ufw deny from 192.0.2.0/24 to any',
                       'ufw deny 5800:5900/tcp', 'ufw deny OpenSSH',
                       'ufw deny 05829/tcp'):
            for part2 in (False, True):
                for errexit in (False, True):
                    with self.subTest(policy=policy, part2=part2, errexit=errexit):
                        self.failed_before_mutation(self.run_ufw(
                            pending=policy, part2=part2, errexit=errexit))

    def test_no_inference_from_coalesced_allow_order(self):
        # show added deduplicates the two families and cannot prove both orders.
        for policy in ('ufw deny 5829/tcp\nufw allow 5829/tcp',
                       'ufw allow 5829/tcp\nufw deny 5829/tcp'):
            self.failed_before_mutation(self.run_ufw(pending=policy, part2=True))

    def test_saved_probe_failure_stops_before_defaults_or_enable(self):
        for part2 in (False, True):
            self.failed_before_mutation(self.run_ufw(failure='show added', part2=part2))

    def test_unknown_saved_evidence_fails_closed(self):
        for pending in ('', '(None)\nufw deny 5829/tcp', 'garbage',
                        'ufw reset', 'ufw deny "unterminated'):
            self.failed_before_mutation(self.run_ufw(pending=pending, part2=True))
        for data in ('', 'wrong header\n(None)\n', HEADER):
            self.assertNotEqual(run('ufw-pending', 5829, data=data).returncode, 0)

    def test_empty_and_simple_unrelated_policies_keep_existing_operations(self):
        for pending in ('(None)', 'ufw allow 443/tcp', 'ufw deny 80/tcp',
                        'ufw reject in log 53/udp comment "DNS"',
                        'ufw deny 5829/udp', 'ufw deny out 5829/tcp'):
            with self.subTest(pending=pending):
                result = self.run_ufw(pending=pending, part2=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.mutations(result), fixture.COMMANDS)
                self.assertIn(fixture.SUCCESS, result.stdout)

    def test_refusal_preserves_saved_rules_without_probe(self):
        result = self.run_ufw(refuse=True, pending='ufw deny 5829/tcp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), [])
        self.assertNotIn('CMD:show added', result.stderr)

    def test_enable_without_active_state_or_effective_allow_stops_part2(self):
        for settings in ({'enable_state': 'inactive'}, {'missing_rule': True},
                         {'status_failure_at': 2}, {'status_failure_at': 4}):
            with self.subTest(settings=settings):
                result = self.run_ufw(part2=True, **settings)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn(fixture.SUCCESS, result.stdout)
                self.assertNotIn('STEP:configure_shell', result.stdout)
                self.assertNotIn('STEP:final_check', result.stdout)

    def test_successful_enable_is_verified_and_repeat_preserves_rules(self):
        result = self.run_ufw(repeat=True, pending='ufw deny 80/tcp')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.mutations(result), fixture.COMMANDS)
        self.assertEqual(result.stderr.count('CMD:show added'), 1)
        self.assertIn('CMD:status numbered', result.stderr)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'native UFW requires Linux')
    def test_native_ufw_saved_rule_serialization_without_firewall_backend(self):
        import gettext
        import ufw.frontend
        gettext.install('ufw')
        for command, blocked in ((['deny', '5829/tcp'], True),
                                 (['reject', 'from', '2001:db8::/32', 'to', 'any', 'port', '5829', 'proto', 'tcp'], True),
                                 (['deny', '80/tcp'], False),
                                 (['allow', '5829/tcp'], False)):
            with self.subTest(command=command):
                parsed = ufw.frontend.parse_command(['ufw'] + command)
                # Real serializer, supplied in-memory rules; no backend constructor,
                # file reads/writes, enable, iptables/nftables or privilege required.
                frontend = object.__new__(ufw.frontend.UFWFrontend)
                class Backend:
                    def get_rules(self):
                        return [parsed.data['rule']]
                frontend.backend = Backend()
                saved = frontend.get_show_added()
                result = run('ufw-pending', 5829, data=saved)
                self.assertEqual(result.returncode != 0, blocked, result.stderr)


if __name__ == '__main__':
    unittest.main()
