# Diagnostics / external tests targeted inventory

Base: `fe731125da1fe823a8a6566f1bb680bdb6a331a5` (remote main and local
checkout verified 2026-09-22). This is a targeted inventory, not a new full audit.

| Finding | Current-main evidence and disposition |
| --- | --- |
| F02 | `ask` already checks prompt writes; `ask_password` ignores prompt/newline errors. Fix remaining password writes; preserve failed/partial-read status. |
| F06 | configure_ssh checks port/password/pubkey/root/kbd/maxauth; final checks only three fields using three unchecked snapshots. Use one checked snapshot and the same six required fields. Match/Include context analysis deferred. |
| F20 | configure_safe_sysctl availability reads and swap RAM assignment can consume failed probes. Check command status before consuming output. modinfo cannot reliably distinguish absent module from all operational errors; module discovery redesign deferred. |
| F21 | Aggregate APT/sysctl overrides need per-setting effective verification beyond this final-check contract. Deferred; no claim that this bundle closes F21. No desired values changed. |
| F23 | systemd success wording overstates manager defaults as applied to every service. Correct wording; final manager read failure is fatal, value mismatch remains warning. Per-process/per-unit validation deferred. |
| F26 | Needrestart verifies persisted main-file text only. State that scope and warn that conf.d/APT hooks may override it. Effective Perl evaluation deferred: do not execute arbitrary config to validate it. |
| F28 | final masks runtime-dir, ss, sshd, sysctl, swapon, UFW and manager read errors. Separate failures from successful absent/disabled probes. Optional theme/tool absence remains warning. SSH preflight unit-selection architecture remains deferred. |
| F29/F30 | Eight remote choices stream code to bash or use process substitution; three start without HTTPS. Replace with checked private temporary regular file, HTTPS-only redirects, nonempty and bash syntax checks, checked runner and cleanup. |
| F31 | part3 ignores ask failure; outer menu ignores diagnostic status. Propagate submenu failure; menu reports it, pauses and continues. Exit/back and invalid-choice policy unchanged. |
| F32 | Existing `.github/workflows/bash-syntax.yml` runs syntax only on filtered PRs. Extend existing workflow to Ubuntu syntax, full isolated discovery and event-aware whitespace checks, PR and main push. |
| F33 | Current test still requires DSA key generation, unsupported by OpenSSH 10. Replace generation with a fixed public-only DSA fixture; preserve rejection assertion. No key policy change. |

## Contracts and endpoint evidence

Required final failures: runtime directory creation, listener probe/absence, SSH
activity/syntax/effective required fields, failed kernel/swap/UFW/manager reads,
missing .zshrc. Successful non-BBR, empty swap, inactive/missing UFW, differing
manager default, optional zoxide/P10K absence remain informational/warnings.
Unknown activity/syntax is described as a failed check, not a proven cause.

All remote choices use curl (already installed by install_packages), with fail on
HTTP error, HTTPS-only initial and redirected protocols, connection/total timeout.
The private mktemp file is checked before/after download; failed or partial or
empty downloads never reach syntax check or execution. Syntax failure also blocks
execution. Runner arguments are unchanged; YABS receives `-4` as a file argument
instead of stdin `-s -- -4`. Runner status is preserved; cleanup failure returns
nonzero (after execution it cannot undo completed work). EXIT/signal cleanup is
local to the helper subshell. No content integrity or immutable pinning claim.

Read-only HTTPS GET checks from the workstation, 2026-09-22 (no downloaded code
executed):

| Previous bare host | HTTPS final URL | Status |
| --- | --- | --- |
| yabs.sh | https://raw.githubusercontent.com/masonr/yet-another-bench-script/master/yabs.sh | 200 |
| IP.Check.Place | https://raw.githubusercontent.com/xykt/IPQuality/main/ip.sh | 200 |
| bench.sh | https://raw.githubusercontent.com/teddysun/across/master/bench.sh | 200 |

Other existing HTTPS URLs were also checked (200, HTTPS-only): ipregion.vrnt.xyz
redirects to vernette/ipregion/master/ipregion.sh; the two GitHub raw paths redirect
to their matching raw.githubusercontent.com paths; Check.Place redirects to
xykt/ScriptMenu/main/menu.sh. Existing URLs are retained. No endpoint substitutions or HTTP fallback.
Third-party script internals and their own downloads remain upstream trust policy.

Password prompt open/write failure stops before read. Newline failure after read
returns nonzero before the caller can accept input; no secret is logged. Failed
read keeps its original status even if the newline also fails.

CI uses existing Ubuntu 24.04 runner tools without package installation. PRs compare
base...head; pushes compare the event's before commit to HEAD when available.
For an absent/all-zero/unavailable push base, the fallback compares the empty tree
to HEAD (repository-wide whitespace), without assuming HEAD has a parent.

Out of scope: limits values, package freshness/set, timers, plugin lifecycle,
rollback transactions, key-path races, cloud firewall, second login, locking,
SSH bind/Match/Include architecture, third-party pinning. F18/F19/F22/F24/F25/F27
remain deferred from earlier bundles. A final read-only release audit follows
this bundle; these deferrals are not a proposal for another large refactor.
