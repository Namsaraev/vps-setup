"""F21/F22/F25/F26: real functions, temporary files and inert host commands."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import test_configure_autoremove as autoremove
import test_configure_unattended_upgrades as upgrades
import test_configure_safe_sysctl as sysctl
import test_configure_systemd_limits as limits
import test_configure_needrestart as needrestart


class EffectiveBundleTest(unittest.TestCase):
    def test_every_apt_key_is_checked(self):
        for key in ['Update-Package-Lists', 'Unattended-Upgrade',
                    'Download-Upgradeable-Packages', 'AutocleanInterval',
                    'Remove-Unused-Dependencies', 'Remove-New-Unused-Dependencies']:
            extra = '''apt-config() {
case "$3" in
*''' + key + ''') echo "value='unexpected'" ;;
*AutocleanInterval) echo "value='7'" ;;
*Remove-*) echo "value='false'" ;;
*) echo "value='1'" ;;
esac
}
'''
            fixture = autoremove.ConfigureAutoremoveTest() if key.startswith('Remove-') else upgrades.ConfigureUnattendedUpgradesTest()
            r, calls, _ = fixture.run_setup(part2=True, extra=extra)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertEqual(calls, [])

    def test_apt_override_and_partial_failed_probe_stop_part2(self):
        for output, status in [("value='true'", 0), ('', 0), ("value='false'", 23)]:
            extra = f"apt-config() {{ echo \"{output}\"; return {status}; }}\n"
            r, calls, _ = autoremove.ConfigureAutoremoveTest().run_setup(part2=True, extra=extra)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertEqual(calls, [])
            self.assertNotIn('Часть 2 завершена', r.stdout)

    def test_periodic_override_missing_and_partial_failure(self):
        for output, status in [("value='0'", 0), ('', 0), ("value='1'", 23)]:
            r, calls, _ = upgrades.ConfigureUnattendedUpgradesTest().run_setup(
                part2=True, extra=f"apt-config() {{ echo \"{output}\"; return {status}; }}\n")
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertEqual(calls, [])
            self.assertNotIn(upgrades.SUCCESS, r.stdout)

    def test_sysctl_loader_success_with_runtime_override(self):
        for value, status in [('99', 0), ('1', 23), ('', 0), ('1\n1', 0)]:
            extra = '''eval "$(declare -f sysctl | sed '1s/sysctl/original_sysctl/')"
sysctl() {
  if [ "$*" = '-n net.ipv4.tcp_syncookies' ]; then
    printf '%s\\n' ''' + repr(value) + '; return ' + str(status) + '''
  fi
  original_sysctl "$@"
}
'''
            r, _, calls = sysctl.ConfigureSafeSysctlTest().run_setup(part2=True, extra=extra)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn('apply', calls)
            self.assertNotIn(sysctl.SUCCESS, r.stdout)
            self.assertNotIn('STEP:configure_systemd_limits', r.stdout)

    def test_pam_conflicts_are_preserved_and_stop_part2(self):
        for entry in ['* soft nofile 524288', 'alice soft nofile 65536',
                      '@admins - nofile unlimited', 'root hard nofile 65536',
                      '* bad nofile 1024']:
            extra = 'mkdir -p "$ROOT/security/limits.d"\nprintf "%s\\n" ' + repr(entry) + ' > "$ROOT/security/limits.conf"\n'
            r, _, _ = sysctl.ConfigureSafeSysctlTest().run_setup(part2=True, extra=extra)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertIn('aggregate PAM limits', r.stderr)
            self.assertNotIn(sysctl.SUCCESS, r.stdout)

    def test_sysctl_snapshot_read_empty_partial_and_failed_are_errors(self):
        for output, status in [('', 0), ('net.ipv4.tcp_syncookies = 1', 0),
                               ('net.ipv4.tcp_syncookies = 1', 23)]:
            extra = '''cat() {
if [ "$*" = "$ROOT/sysctl.d/99-vps-tuning.conf" ]; then
printf '%s\\n' ''' + repr(output) + '; return ' + str(status) + '''
fi
builtin command cat "$@"
}
'''
            r, _, _ = sysctl.ConfigureSafeSysctlTest().run_setup(part2=True, extra=extra)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertNotIn(sysctl.SUCCESS, r.stdout)

    def test_systemd_effective_soft_hard_and_probe_failures(self):
        for output, status in [('DefaultLimitNOFILE=1048576\nDefaultLimitNOFILESoft=1048576', 0),
                               ('', 0), ('DefaultLimitNOFILE=1048576\nDefaultLimitNOFILESoft=1024', 23)]:
            extra = 'systemctl() { [ "$1" != show ] || { printf "%s\\n" ' + repr(output) + f'; return {status}; }}; }}\n'
            r, _, _ = limits.ConfigureSystemdLimitsTest().run_setup(part2=True, extra=extra)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertNotIn(limits.SUCCESS, r.stdout)
            self.assertNotIn('STEP:configure_swap', r.stdout)

    def test_enabled_stopped_stale_masked_and_unscheduled_timers_warn(self):
        good = dict(LoadState='loaded', UnitFileState='enabled', ActiveState='active',
                    SubState='waiting', NextElapseUSecRealtime='Sat 2026-10-03 01:51:55 UTC',
                    NextElapseUSecMonotonic='0', NeedDaemonReload='no')
        for change in [dict(ActiveState='inactive', SubState='dead'), dict(UnitFileState='masked'),
                       dict(UnitFileState='disabled'), dict(LoadState='not-found'),
                       dict(NeedDaemonReload='yes'), dict(SubState='failed'),
                       dict(NextElapseUSecRealtime='n/a'), dict(NextElapseUSecRealtime='0'),
                       dict(NextElapseUSecRealtime='garbage'), dict(NextElapseUSecRealtime='Sat 2026-99-03 01:51:55 UTC')]:
            rows = ' '.join(repr(k + '=' + v) for k, v in (good | change).items())
            extra = f'systemctl() {{ [ "$1" != show ] || printf "%s\\n" {rows}; }}\n'
            r, _, _ = upgrades.ConfigureUnattendedUpgradesTest().run_setup(enabled=upgrades.TIMERS, part2=True, extra=extra)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn(upgrades.SUCCESS, r.stdout)
            self.assertIn('WARN:', r.stdout)

    def test_timer_partial_failed_and_duplicate_probes_warn(self):
        for extra in ['systemctl() { [ "$1" != show ] || return 23; }\n',
                      'systemctl() { [ "$1" != show ] || echo ActiveState=active; }\n',
                      'systemctl() { [ "$1" != show ] || printf "%s\\n" ActiveState=active ActiveState=active; }\n']:
            r, _, _ = upgrades.ConfigureUnattendedUpgradesTest().run_setup(extra=extra)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertNotIn(upgrades.SUCCESS, r.stdout)

    def test_unknown_enablement_does_not_authorize_enable(self):
        for value, status in [('enabled', 23), ('masked', 1), ('disabled', 23), ('', 0)]:
            extra = f'''systemctl() {{
echo "$*" >> "$CALLS"
case "$1" in
is-enabled) echo '{value}'; return {status} ;;
show) return 23 ;;
*) return 98 ;;
esac
}}
'''
            r, calls, _ = upgrades.ConfigureUnattendedUpgradesTest().run_setup(extra=extra)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse(any(call.startswith('enable ') for call in calls))
            self.assertNotIn(upgrades.SUCCESS, r.stdout)

    def nr_fixture(self):
        fixture = needrestart.NeedrestartTest()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        fixture.config.write_bytes(b"$nrconf{restart} = 'i';\n")
        (fixture.root / 'conf.d').mkdir()
        return fixture

    def test_needrestart_late_conflict_and_opaque_perl_preserve_main(self):
        for text in ["$nrconf{restart} = 'l';", "$nrconf{'restart'} = 'i';",
                     '$nrconf{restart} = mode();', '%nrconf = ();', 'die "must not execute";']:
            fixture = self.nr_fixture()
            original = fixture.config.read_bytes()
            snippet = fixture.root / 'conf.d/zz-local.conf'
            snippet.write_text(text)
            r = fixture.run_configure(through_part2=True)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertEqual(fixture.config.read_bytes(), original)
            self.assertEqual(snippet.read_text(), text)
            self.assertNotIn('Часть 2 завершена', r.stdout)

    def test_needrestart_supported_snippets_comments_and_repeat(self):
        fixture = self.nr_fixture()
        (fixture.root / 'conf.d/10-auto.conf').write_text("# restart='l'\n$nrconf{restart} = 'a';\n")
        for _ in range(2):
            r = fixture.run_configure()
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('conf.d проверен', r.stdout)
            self.assertNotIn('автоматический перезапуск включён', r.stdout)

    def test_needrestart_probe_failure_hook_conflict_and_environment(self):
        for extra in ['apt-config() { echo partial; return 23; }\n',
                      'apt-config() { echo "DPkg::Post-Invoke { needrestart -rl; };"; }\n',
                      'apt-config() { echo "DPkg::Post-Invoke { needrestart -r \'l\'; };"; }\n',
                      'NEEDRESTART_MODE=l\n', 'NEEDRESTART_SUSPEND=1\n']:
            fixture = self.nr_fixture()
            original = fixture.config.read_bytes()
            r = fixture.run_configure(through_part2=True, extra=extra)
            self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
            self.assertEqual(fixture.config.read_bytes(), original)

    def test_needrestart_snippet_read_failure_is_not_absence(self):
        fixture = self.nr_fixture()
        (fixture.root / 'conf.d/zz-broken.conf').symlink_to(fixture.root / 'missing')
        r = fixture.run_configure()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)

    def test_needrestart_never_executes_snippet(self):
        fixture = self.nr_fixture()
        marker = fixture.root / 'executed'
        (fixture.root / 'conf.d/zz-code.conf').write_text(f'system("touch {marker}");\n')
        r = fixture.run_configure()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertFalse(marker.exists())

    def test_real_apt_parser_uses_later_override_without_host_mutation(self):
        if not os.sys.platform.startswith('linux'):
            self.skipTest('Linux apt parser required')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parts = root / 'parts'
            parts.mkdir()
            (parts / '50auto-remove').write_text(autoremove.POLICY)
            (parts / '99-local').write_text('Unattended-Upgrade::Remove-Unused-Dependencies "true";\n')
            config = root / 'apt.conf'
            config.write_text(f'Dir::Etc::Parts "{parts}";\nDir::Etc::main "{root}/missing";\n')
            r = subprocess.run(['apt-config', 'shell', 'value', 'Unattended-Upgrade::Remove-Unused-Dependencies'],
                               env=dict(os.environ, APT_CONFIG=str(config)), capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.strip(), "value='true'")

    def test_real_systemd_config_loader_shows_later_dropin(self):
        if not os.sys.platform.startswith('linux'):
            self.skipTest('Linux systemd parser required')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            directory = root / 'etc/systemd/system.conf.d'
            directory.mkdir(parents=True)
            (root / 'etc/systemd/system.conf').write_text('[Manager]\n')
            (directory / '99-nofile.conf').write_text(limits.CONFIG)
            (directory / 'zz-local.conf').write_text('[Manager]\nDefaultLimitNOFILE=65536\n')
            r = subprocess.run(['systemd-analyze', '--root=' + tmp, 'cat-config', 'systemd/system.conf'],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertLess(r.stdout.index('DefaultLimitNOFILE=1024:1048576'),
                            r.stdout.index('DefaultLimitNOFILE=65536'))

    def test_real_perl_literal_later_assignment_changes_mode(self):
        if not os.sys.platform.startswith('linux'):
            self.skipTest('Linux Perl fixture required')
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            main = root / 'main.conf'
            late = root / 'zz-local.conf'
            main.write_text("$nrconf{restart} = 'a';\n")
            late.write_text("$nrconf{restart} = 'l';\n")
            # Only these two test-authored literal assignments are executed.
            r = subprocess.run(['perl', '-e', 'our %nrconf; for (@ARGV) { do $_; die $@ if $@; } print $nrconf{restart};',
                                str(main), str(late)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout, 'l')

    def test_real_child_process_has_conservative_soft_limit(self):
        if not os.sys.platform.startswith('linux'):
            self.skipTest('Linux rlimit required')
        r = subprocess.run(['python3', '-c', '''import resource
_, inherited_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
resource.setrlimit(resource.RLIMIT_NOFILE, (1024, inherited_hard))
assert resource.getrlimit(resource.RLIMIT_NOFILE) == (1024, inherited_hard)
'''], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
