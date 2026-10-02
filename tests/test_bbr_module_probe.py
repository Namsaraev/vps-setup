"""F20 isolated kernel probes; no host module loading or sysctl writes."""
import unittest
import test_configure_safe_sysctl as support
from test_configure_safe_sysctl import BASE, BBR, SUCCESS


class BbrModuleProbeTest(unittest.TestCase):
    def run_setup(self, **kwargs):
        return support.ConfigureSafeSysctlTest().run_setup(**kwargs)

    def test_failed_probe_and_unknown_kernel_preserve_files_and_stop_part2(self):
        for probe, config in [('fail', ''), ('missing', ''), ('partial', ''),
                              ('empty', ''), ('malformed', ''), ('config-fail', ''),
                              ('config-partial', '# CONFIG_TCP_CONG_BBR is not set'),
                              ('uname-fail', ''), ('fail', 'CONFIG_TCP_CONG_BBR=z'),
                              ('fail', 'CONFIG_TCP_CONG_BBR=m\nCONFIG_TCP_CONG_BBR=y')]:
            for outer in (False, True):
                with self.subTest(probe=probe, config=config, part2=outer):
                    r, files, calls = self.run_setup(mode='unavailable', probe=probe,
                                                    config=config, part2=outer, errexit=True)
                    self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
                    self.assertEqual(files, {'modules': 'tcp_bbr\n', 'sysctl': None, 'limits': None})
                    self.assertEqual(calls, [])
                    self.assertNotIn(SUCCESS, r.stdout)
                    self.assertNotIn('Часть 2 завершена', r.stdout)
                    self.assertNotIn('STEP:configure_systemd_limits', r.stdout)

    def test_unknown_probe_retains_all_existing_configuration(self):
        r, files, calls = self.run_setup(probe='partial', config='', seed=True, part2=True)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(files['modules'], 'old configuration\n')
        self.assertEqual(files['sysctl'], 'old configuration\n')
        self.assertEqual(files['limits'], 'old configuration\n')
        self.assertEqual(calls, [])

    def test_explicit_absence_retains_optional_fallback(self):
        r, files, calls = self.run_setup(mode='unavailable', probe='fail', repeat=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(files['modules'])
        self.assertEqual(files['sysctl'], BASE.format(bbr=''))
        self.assertNotIn('modprobe', calls)

    def test_missing_failed_empty_partial_modinfo_can_use_confirmed_module(self):
        for probe in ('missing', 'fail', 'empty', 'partial'):
            with self.subTest(probe=probe):
                r, files, calls = self.run_setup(probe=probe, repeat=True)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(files['modules'], 'tcp_bbr\n')
                self.assertEqual(files['sysctl'], BASE.format(bbr=BBR))
                self.assertEqual(calls.count('modprobe'), 1)
                self.assertEqual(calls.count('dry-run'), 1)

    def test_builtin_config_needs_no_modprobe_or_module_persistence(self):
        r, files, calls = self.run_setup(mode='builtin', probe='missing',
                                        failure='missing-modprobe', repeat=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(files['modules'])
        self.assertEqual(files['sysctl'], BASE.format(bbr=BBR))
        self.assertNotIn('modprobe', calls)
        self.assertNotIn('dry-run', calls)

    def test_declared_builtin_without_runtime_algorithm_fails_before_writes(self):
        r, files, calls = self.run_setup(mode='unavailable', probe='fail', config='CONFIG_TCP_CONG_BBR=y')
        self.assertEqual(r.returncode, 1)
        self.assertEqual(files['modules'], 'tcp_bbr\n')
        self.assertIsNone(files['sysctl'])
        self.assertEqual(calls, [])

    def test_dry_run_failure_and_successful_load_without_bbr_are_errors(self):
        for failure in ('dry-run', 'no-algorithm'):
            for outer in (False, True):
                r, files, calls = self.run_setup(failure=failure, part2=outer)
                self.assertEqual(r.returncode, 1, r.stderr)
                self.assertTrue(all(value is None for value in files.values()))
                self.assertNotIn('apply', calls)
                self.assertNotIn(SUCCESS, r.stdout)
                self.assertNotIn('Часть 2 завершена', r.stdout)

    def test_builtin_modinfo_without_kernel_config_is_supported(self):
        r, files, calls = self.run_setup(mode='builtin', probe='builtin-info', config='', repeat=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(files['modules'])
        self.assertNotIn('modprobe', calls)

    def test_builtin_modinfo_with_missing_algorithm_does_not_claim_success(self):
        r, files, calls = self.run_setup(mode='unavailable', probe='builtin-info', config='')
        self.assertEqual(r.returncode, 1)
        self.assertEqual(files['modules'], 'tcp_bbr\n')
        self.assertEqual(calls, [])

    def test_real_modprobe_dry_run_does_not_execute_install_fixture(self):
        import shutil
        import subprocess
        import tempfile
        from pathlib import Path
        import sys
        if not sys.platform.startswith('linux'):
            self.skipTest('real kmod fixture requires Linux')
        tool = shutil.which('modprobe')
        self.assertIsNotNone(tool, 'Linux verification requires kmod')
        with tempfile.TemporaryDirectory(prefix='bbr-kmod-') as tmp:
            root = Path(tmp)
            (root / 'lib/modules/fixture').mkdir(parents=True)
            config = root / 'modprobe.conf'
            marker = root / 'executed'
            config.write_text(f'install tcp_bbr /usr/bin/touch {marker}\n')
            r = subprocess.run([tool, '-d', tmp, '-S', 'fixture', '-C', str(config),
                                '--dry-run', 'tcp_bbr'], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertFalse(marker.exists())


if __name__ == '__main__':
    unittest.main()
