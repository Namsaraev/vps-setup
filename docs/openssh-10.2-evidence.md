# OpenSSH 10.2 diagnostic compatibility

Captured 2026-09-28 on pin-o, Ubuntu 26.04.1 LTS (aarch64):
`OpenSSH_10.2p1 Ubuntu-2ubuntu3.6, OpenSSL 3.5.5 27 Jan 2026`.
The binary was `/usr/sbin/sshd`; no replacement or installation was performed.
Only a temporary config, Include and freshly generated temporary Ed25519 host
key were used. No daemon was started. No real SSH configuration, services,
firewall or users were changed. Temporary probe files were cleaned up.

Invocation (temporary directory name varies):

```sh
/usr/sbin/sshd -T -f /tmp/pr30-trace-1ds05t1u/sshd_config \
  -C user=pin,host=127.0.0.1,addr=127.0.0.1,laddr=127.0.0.1,lport=5829 -ddd
```

Exit status: 0. Complete original stdout/stderr and input configs are committed
under `tests/fixtures/openssh-10.2/`. They contain no private host key material.
Relevant original lines:

```text
debug1: sshd version OpenSSH_10.2, OpenSSL 3.5.5 27 Jan 2026
debug2: parse_server_config_depth: config /tmp/pr30-trace-1ds05t1u/sshd_config len 189
debug3: checking syntax for 'Match User pin' on line 1
debug3: checking syntax for 'Match all' on line 3
authorizedkeysfile %h/.ssh/authorized_keys
pubkeyauthentication yes
authenticationmethods publickey
```

Unlike the 9.6 diagnostic grammar, 10.2 appends ` on line N` to the Match syntax
trace. Merely allowing its version still rejects valid Match configurations.
The production change explicitly permits 10.2 and requires its positive decimal
line-number suffix. The existing 8.9/9.x grammar and all Match/key/authentication
restrictions remain unchanged. Other 10.x and future major versions remain
unsupported; missing or unrecognized diagnostic formats fail closed.

`test_openssh_trace_compat.py` replays the captured trace, rejects unknown
versions and malformed markers, and checks that Match/key/authentication
restrictions still apply. Its Linux-only live test invokes the actual installed
`/usr/sbin/sshd` with temporary keys/configs, including unmatched Address and
LocalPort conditions in an Include. Existing real-parser and duplicate-Port
tests are unchanged. GitHub Actions remains Ubuntu 24.04 (9.x), not 10.2
integration coverage. Exact-head Linux results and CI run are recorded in PR #30
and the delivered verification report.
