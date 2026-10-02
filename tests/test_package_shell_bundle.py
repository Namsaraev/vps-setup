"""Exact F24/F27 regressions; native commands only touch private fixtures."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
import test_configure_shell as shell
ENTRYPOINTS = shell.ENTRYPOINTS
import test_part1_error_contract as part1
import test_optional_packages as packages

class FreshnessTest(unittest.TestCase):
    def test_partial_update_stops_first_repeat_and_unminimize(self):
        fixture = part1.Part1ErrorContractTest()
        for settings in ("", "marker=true", "IS_MINIMIZED=true; reply=y"):
            with self.subTest(settings=settings):
                r = fixture.run_case(settings + r"""
apt-get() {
  echo "APT:$*"
  if [ "$1" = update ]; then
    # Model native apt: a transient fetch failure is zero without strict mode.
    [[ " $* " != *" APT::Update::Error-Mode=any "* ]] && return 0
    return 100
  fi
}
""")
                fixture.failed(r)
                self.assertNotIn("MARKER", r.stdout)
                for action in ("full-upgrade", "upgrade", "install", "UNMINIMIZE"):
                    self.assertNotIn(action, r.stdout)

    def test_package_partial_update_stops_part2(self):
        f = packages.OptionalPackagesTest()
        r = f.run_install(failure="update", status=100, outer=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("APT::Update::Error-Mode=any", r.stdout)
        self.assertNotIn("NEXT:", r.stdout)

    def test_marker_retains_upgrade_policy_and_update_count(self):
        r = part1.Part1ErrorContractTest().run_case("", "part1_update && part1_update")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count("APT:update -o APT::Update::Error-Mode=any"), 2)
        self.assertEqual(r.stdout.count("APT:full-upgrade -y"), 1)
        self.assertEqual(r.stdout.count("APT:upgrade -y"), 1)

class NativeAptTest(unittest.TestCase):
    def test_native_transient_fetch_default_zero_strict_failure(self):
        # A loopback HTTP repo and private lists/cache; never touch host apt state.
        import hashlib
        import http.server
        import threading
        import email.utils
        payload = b""
        release = ("Date: " + email.utils.formatdate(usegmt=True) + "\n"
                   "SHA256:\n " + hashlib.sha256(payload).hexdigest() + " 0 main/binary-amd64/Packages\n").encode()
        class Handler(http.server.BaseHTTPRequestHandler):
            failing = False
            def log_message(self, *args):
                pass
            def do_GET(self):
                if self.failing:
                    self.connection.close()
                    return
                if self.path.endswith("/Release"):
                    data = release
                elif self.path.endswith("/Packages"):
                    data = payload
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                (root / "lists/partial").mkdir(parents=True)
                (root / "cache/archives/partial").mkdir(parents=True)
                (root / "status").touch()
                (root / "sources.list").write_text(f"deb [trusted=yes arch=amd64] http://127.0.0.1:{server.server_port} stable main\n")
                args = ["apt-get", "update"]
                for key, value in {
                    "Dir::Etc::sourcelist": str(root / "sources.list"),
                    "Dir::Etc::sourceparts": "-", "Dir::Etc::main": "-", "Dir::Etc::parts": "-",
                    "Dir::State::lists": str(root / "lists"), "Dir::State::status": str(root / "status"),
                    "Dir::Cache": str(root / "cache"), "Debug::NoLocking": "true",
                    "Acquire::Retries": "0", "Acquire::http::Timeout": "2",
                    "Acquire::http::Proxy": "DIRECT", "APT::Sandbox::User": str(os.getuid()),
                }.items():
                    args += ["-o", key + "=" + value]
                def run(strict=False):
                    return subprocess.run(args + (["-o", "APT::Update::Error-Mode=any"] if strict else []),
                                          text=True, capture_output=True, timeout=20)
                initial = run(True)
                self.assertEqual(initial.returncode, 0, initial.stderr)
                Handler.failing = True
                stale = run()
                self.assertEqual(stale.returncode, 0, stale.stderr)
                self.assertIn("Failed to fetch", stale.stderr)
                strict = run(True)
                self.assertNotEqual(strict.returncode, 0)
                self.assertIn("Failed to fetch", strict.stderr)
        finally:
            server.shutdown()
            server.server_close()
            thread.join()

class ShellLifecycleTest(unittest.TestCase):
    def fixture(self):
        f = shell.ConfigureShellTest()
        f.setUp()
        self.addCleanup(f.doCleanups)
        return f

    def test_missing_empty_and_syntax_broken_components_preserved_before_chsh(self):
        for name in ENTRYPOINTS:
            for content in (None, b"", b"if then\n"):
                with self.subTest(name=name, content=content):
                    f = self.fixture()
                    path = f.home / name
                    if content is None:
                        path.unlink()
                    else:
                        path.write_bytes(content)
                    r = f.run_shell(success=False, part2=True)
                    self.assertNotIn("CALL:chsh:", r.stdout)
                    self.assertNotIn("STEP:final_check", r.stdout)
                    self.assertEqual(path.read_bytes() if path.exists() else None, content)

    def test_successful_clone_with_empty_entrypoint_is_rejected(self):
        import shutil
        f = self.fixture()
        shutil.rmtree(f.home / ".oh-my-zsh")
        r = f.run_shell(success=False, failure="empty-clone")
        self.assertNotIn("CALL:chsh:", r.stdout)
        self.assertTrue((f.home / ".oh-my-zsh").is_dir())

    def test_broken_user_rc_stops_before_chsh(self):
        f = self.fixture()
        user = b"if then\n"
        f.rc.write_bytes(user)
        r = f.run_shell(success=False)
        self.assertNotIn("CALL:chsh:", r.stdout)
        self.assertTrue(f.rc.read_bytes().endswith(user))

    def test_chsh_failure_retains_prepared_config_for_retry(self):
        f = self.fixture()
        r = f.run_shell(success=False, failure="chsh")
        self.assertTrue(f.managed.exists())
        self.assertTrue(f.rc.exists())
        f.run_shell()

    def test_second_home_is_prepared_independently(self):
        first, second = self.fixture(), self.fixture()
        first.run_shell()
        (second.home / ENTRYPOINTS[0]).write_bytes(b"")
        r = second.run_shell(success=False)
        self.assertNotIn("CALL:chsh:", r.stdout)
        self.assertTrue(first.managed.exists())
        self.assertFalse(second.managed.exists())

    def test_real_zsh_loads_generated_managed_config_in_private_home(self):
        f = self.fixture()
        f.run_shell()
        env = dict(os.environ, HOME=str(f.home), PATH="/usr/bin:/bin")
        r = subprocess.run(["/usr/bin/zsh", "-dfc", 'source "$HOME/.config/tunevps/zshrc"; print -r -- "$ZSH_THEME"'],
                           env=env, text=True, capture_output=True, timeout=15)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        self.assertIn('fpath=("$ZSH/custom/plugins/zsh-completions/src" $fpath)', f.managed.read_text())
        self.assertIn("powerlevel10k/powerlevel10k", r.stdout)

if __name__ == "__main__":
    unittest.main()
