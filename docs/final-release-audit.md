# Final release audit after PR #34

Audited remote main: `9eab944d345d6fc95d7dc7297be649920eeb5321`.
Verified with git ls-remote and GitHub commit metadata, then a separate clean
detached checkout; main rechecked before branching/publishing. Date: 2026-10-02.
Verdict for that main: **NOT READY**. One new HIGH finding requires a fix.
No merge or release/tag is authorized by this audit.

## New findings

| ID | Severity | Exact-main path / condition | Impact / existing coverage | Minimal direction |
|---|---|---|---|---|
| R01 | HIGH | `tunevps.sh:1816` `configure_ufw`, inactive branch L1829-1838. UFW is disabled but retains an inbound deny/reject/limit for 5829/TCP, a range, or broader source rule; user accepts activation. `configure_ssh` skips inactive firewall preflight; `configure_ufw` appends SSH ALLOW behind saved blocking rules and calls `ufw --force enable`. | New SSH connections can be blocked despite successful setup output; established connection tracking may retain the current session, but reconnection fails. Existing active-rule precedence tests do not cover saved inactive policy. Inactive fixtures have no saved rules and previously never change state on enable. This is a separate unguarded path, not a regression claim about already-fixed active-UFW precedence. | Check read-only saved rules before any default/rule/enable mutation; refuse potentially conflicting/unsupported policy without rewriting it. Confirm active state and effective numbered SSH ALLOW after activation before success or later Part 2 steps. |
| R02 | LOW / LIMITATION | `tunevps.sh:1858`, `configure_ufw` optional iPerf action 2, when an earlier broad 5201 allow already exists. | Adding a source-scoped rule is additive; the message saying access is allowed "only" for that IP does not prove removal of existing broad grants. Existing tests cover commands/errors, not combined effective iPerf policy. No new initial-setup SSH risk. | Document additive semantics; manually inspect existing 5201 rules. Defer wording/effective optional-policy work; no policy expansion in the blocker fix. |

R01 production fix is confined to `access_safety` / `configure_ufw` in
`tunevps.sh`. `LC_ALL=C ufw show added` supplies saved canonical rules even when
inactive. Unknown/empty/failed evidence and potentially relevant blocking rules
fail before mutation. Simple unrelated numeric port/UDP/outbound rules remain
supported. The report deduplicates IPv4/IPv6 rules, so the checker deliberately
does not infer safe per-family precedence from a preceding coalesced ALLOW.
Conservative refusal is manual-review guidance, not automatic rule deletion.
After enable, existing active-numbered-rule verification checks SSH access.
No global rollback framework, endpoint/trust change, or SSH policy change.

## End-to-end review

Reviewed all production code, current tests and historical inventories, with
merged commits #26-#34 and earlier error-contract fixes as context. F18-F27
are not reopened: their fixed current paths and documented boundaries were
checked rather than inferred from old finding titles.

| Area | Current-main assessment / evidence |
|---|---|
| Privilege/bootstrap/identity | EUID escalation, SUDO_USER fallback, checked id/getent and one-record home selection. Separate initiating-user environment and fixed pin identity; access/input bundle covers selection and another-user paths. |
| pin/password/key writes | Existing account/custom home preserved; explicit menu controls password/add/replace; silent confirmed password input; OpenSSH fingerprints, DSA rejection, checked complete reads. Anchored no-follow key writer verifies owner/write permissions, regular single-linked files, metadata, target/parent substitution and staged bytes. Existing-account no-op does not silently grant sudo or change credentials. |
| SSH/auth/includes/socket | Effective OpenSSH key path and supported Match trace before apply/fast path and after persistence. Standalone publickey prerequisite, aggregate syntax, owned listener, bind preservation, service/socket mode selection, pre-restart multi-file rollback. Real temporary OpenSSH fixtures and captured 10.2 trace compatibility. Runtime restart failures remain explicit failures with manual recovery. |
| UFW | Active ordered rules checked before SSH mutation; old SSH rules retained. Inactive activation gap is R01. New saved-policy and post-enable checks close that specific path. |
| APT lifecycle/packages | Three original strict updates, first successful full-upgrade marker, repeat upgrade; checked required installs and best-effort optional installs; no extra update. Native private APT transient-failure fixture. Part 1 and Part 2 errors propagate to menu exit. |
| Unattended/autoremove/needrestart | Checked effective periodic/removal keys; timer persistent enablement separated from active scheduling. Optional autoremove uses preview plus explicit consent. Needrestart default is preserve existing mode; automatic choice checks supported hook/snippet conflicts and accurately limits the persisted-mode claim. |
| Locale/time | Checked timezone, locale generation and update-locale; current policy remains Asia/Irkutsk and ru_RU.UTF-8/en_US.UTF-8. |
| BBR/sysctl/limits | Running-kernel modinfo/config evidence distinguishes absence from ambiguity; module loading and availability rechecked. Managed effective sysctl values checked after aggregate load. PAM and manager soft=1024/hard=1048576; overrides conflict-checking and subsequent-start/new-login semantics retained. Native kmod/APT/systemd/rlimit fixtures. |
| Swap | Exact bytes/page header, staged allocation, old swap retained until prepared, targeted swapoff, checked in-process recovery; other swaps preserved. Matching-runtime fast path repairs fstab. Real temporary allocation/mkswap and fault-injected kernel operations. |
| Shell/user reruns | Clones and managed writes as initiating user, nonempty readable entrypoints/completions and native syntax checked; user zshrc bytes preserved; chsh only after preparation. Independent homes and interrupted-install/chsh retry paths covered. |
| Persistence/final/cleanup | Anchored staged writers, checked failures, unchanged-content/repeat transforms; SSH rollback stronger than general single-file persistence. final_check uses consistent SSH requirements and checked probes, with scoped manager/shell messages. Diagnostic full-download/syntax/runner/cleanup contracts preserved. |

## Verification

Exact-main GitHub Actions **push** run:
https://github.com/Namsaraev/vps-setup/actions/runs/36986464214
Job: `110772516035`, Ubuntu 24.04.5 runner, completed/success.
Actual decoded job log confirms exact SHA before/after discovery, clean tree
checks before/after, syntax PASS, whitespace PASS (push base
`15ec6030e436baac59e44f5ec99a7d4b920db918`), **354 tests in 129.751s, OK,
no skips**. Local exact-main syntax/diff/clean-tree checks also passed.
The workflow uses `github.event.pull_request.head.sha || github.sha`, so push
tests the exact pushed SHA; PR tests the exact head rather than a synthetic merge.

Actual main full-discovery log includes SSH/OpenSSH/access (61 methods), UFW
(26), swap (43), BBR/sysctl (14), effective configuration (19), persistence/
repeat (32), package/shell bundle and subsystem (30), Part 1/Part 2 propagation
(29), plus all remaining subsystem/diagnostic/key suites. These are verified
subsets of the full run, not independent additional runs.

R01 reproduction uses the exact main script blob (`7af8145a3ad6483c026821a67ae1123db6dcc3e0`)
with isolated shell/firewall evidence: 44 failing subtest assertions, including
direct and real Part 2 orchestration, demonstrate main enables conflicting
saved policy and accepts unverified activation. No host firewall changed.
New regressions cover saved deny/reject/limit, IPv6/source/range/profile rules,
unknown/probe failures, harmless numeric rules, refusal, activation verification,
repeat, and native UFW canonical serialization with an in-memory backend.
CI-only ufw dependency accompanies the existing zsh dependency.
Final blocker-head CI/count/clean-tree evidence belongs in the delivered report
and PR, avoiding a self-referential commit SHA in this document.

## Supported assumptions and non-blocking boundaries

- Primary target: interactive Ubuntu 24.04/26.04 VPS with systemd, standard
  Ubuntu packages/repositories and normal privileged administrative access.
  24.04 has live exact-SHA CI coverage; 26.04/OpenSSH 10.2 has historical native
  trace evidence, not a full current end-to-end 26.04 acceptance run. Do not
  advertise every Ubuntu release/container as certified. The script's ID check
  is broader than the tested target matrix.
- SSH automatic Match trace scope is 8.9, 9.x, 10.2 with User/Group/All only;
  connection-dependent Match/unknown trace formats fail closed. A key file does
  not certify key-option/revocation/account/PAM policy, cloud firewall or real
  second login. Keep current session and verify a new connection manually.
- No host users, firewall, packages, login shell, services or kernel swap were
  mutated by testing. Full privileged initial setup/reboot and runtime systemd/
  firewall/kernel activation are not acceptance-tested by these fixtures.
- Config checks are snapshots; arbitrary custom overrides may require manual
  review. Timers may need manual start/reboot; arbitrary needrestart Perl/hook
  behavior and actual future upgrades/restarts are not certified.
- General persistence is single-file, not a crash/concurrent-admin transaction.
  Swap replacement needs space for both files and enough RAM for swapoff;
  power-loss recovery/unsupported filesystems can require manual repair.
- Shell syntax/entrypoint checks do not certify third-party plugin runtime;
  arbitrary existing startup code is not executed during setup. Live upstream
  downloads/trust/pinning remain a separately documented supply-chain concern.
- Saved UFW report coalescing requires conservative manual review of relevant
  blocking policies; raw before/after rules and cloud firewalls are outside the
  supported checker. iPerf source rules remain additive (R02).

Next step: review the single DRAFT R01 blocker PR and its exact-head CI. Re-audit
the merge SHA after a separately authorized merge before tagging a release.
