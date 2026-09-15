# configure_pin error-contract audit

## Baseline inventory (before edits)

Read current `main` at `ef3431e3a89b3a931e6d196b2b5d475ba5af5241`,
including the exact changes in #18 (`0fecc7e`) and #19 (`b04d501`).

| Path | Already protected on main | Remaining gap / change in this bundle |
| --- | --- | --- |
| Password | #19 checks both password reads and propagates existing-user password failure; new-user caller already checked it | Preserve without edits |
| Permissions | #18 guards temporary-file chmod and directory/key chmod, resets PIN_HAS_KEY before installation | Preserve without edits |
| Account creation | adduser/usermod failures already fatal | Preserve; execution errors from id other than ordinary status 1 now fatal |
| Home lookup (both branches) | Empty/nonexistent home already fatal | Check getent status even with partial stdout; parse exactly one complete passwd record, verify username, preserve custom home |
| Four ask calls | Successful empty responses have deliberate defaults/no-op behavior | Check EOF/read failure for action, creation, method, file path; leave prompt text and defaults intact |
| Direct key read | Empty input deliberately leaves keys unchanged | Check read and device-open status separately from empty success |
| Keyfile | Missing/non-regular input file already rejected | Check cat status, including partial output plus nonzero |
| Fingerprint | OpenSSH parses options; DSA and malformed keys rejected | 0 valid / 1 invalid / 2 operational; guard mktemp, write, readback, execution, result shape, cleanup and output |
| authorized_keys probe | Absent/unreadable file and no matching valid key returned 1 | Snapshot with checked cat before matching; propagate helper/read failures as 2, reject non-regular existing paths |
| Duplicate/initial probes | Any failure could look like no key | Handle 0/1/2 explicitly in configure_pin |
| Atomic installation | mkdir, temporary write, cat, mv, chown and final validation already checked | Guard intermediate separator printf; final printf already determines subshell status |
| Caller | part2_setup already checks configure_pin and stops | No caller changes; regression tests use its real body and check absence of completion and later steps |

## Contract and policy

Malformed, blank, comment-only, multiline and DSA inputs retain expected invalid
semantics. Empty key input remains a successful no-op. Options and comments do
not change fingerprint matching; append keeps existing bytes and separates a
last line without LF. Replacement and new-user installation keep their existing
behavior. All password, account, ownership and SSH hardening policy is retained.

The file snapshot checks the entire disk read before accepting an early match.
Missing files and unreadable regular files retain ordinary no-match behavior;
directories and dangling links are operational failures. Readability/access
predicates still have the shell's usual limits (no errno detail). `id` status 1
retains its existing missing-user interpretation; other nonzero statuses fail.

OpenSSH itself reuses exit status 1 for malformed keys and operational errors.
The wrapper fixes the locale to C, recognizes only exact expected invalid-file
diagnostics, and treats other failures or unexpected successful output as fatal.
It verifies the temporary input's contents before invoking OpenSSH. This cannot
distinguish an internal OpenSSH failure that emits exactly the same invalid-key
diagnostic; OpenSSH's fingerprint reader does not expose every internal read
error separately. See [OpenSSH do_fingerprint source](https://github.com/openssh/openssh-portable/blob/master/ssh-keygen.c).
This is an explicit upstream boundary, not a claim of complete errno detection.

## Isolated verification

`tests/test_configure_pin_error_contract.py` uses temporary homes, real generated
keys, real helper/configure_pin/part2 bodies, and stubs for accounts, passwords,
ownership and unrelated part2 steps. Only the terminal pathname is redirected
to a disposable fixture. It covers all four prompts with EOF, partial EOF and
read error; direct key read/open failure; keyfile partial read failure; both home
branches; expected invalid/no-op behavior; helper execution, write, read and
cleanup errors; duplicate/options/no-match behavior; append separator failure;
final validation failure; add/replace/new-user success and repeat invocation.
No provisioning script is sourced or executed at top level.

Exact-head verification results are recorded in the PR, with separate local and
Linux logs. Existing permission, password, propagation, SSH, UFW and part1 suites
are retained and rerun.

## Outside scope

No edits to configure_ssh, UFW, swap, part1, package installation, shell, sysctl,
part3, final_check, or other part2 helpers. configure_ssh's existing caller of
authorized_keys_has_key already refuses hardening for either nonzero result;
it remains unchanged. Its separate home pipeline, other diagnostic cleanup,
and the overall final audit remain outside this PR. No real vpstest users,
passwords, homes, .ssh files, firewall or service configuration are changed.
