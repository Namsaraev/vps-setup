# Part 1 error-contract audit

## Audited base and boundary

Exact current `main` read before edits: `aa1425ff90a7ebf122fc8e5ee7b46ffa18f4827e`
(PR #23 squash merge). Branch: `fix/part1-update-error-contract-bundle`.

Scope: `detect_minimized`, its startup initialization and post-unminimize caller,
`part1_update`, and directly related top-level menu input/dispatch/continuation.

## Inventory on that base

| Path | Existing contract | Finding / resolution |
| --- | --- | --- |
| Both apt update calls | Explicit error + return 1 | Preserved |
| First full-upgrade / repeat upgrade | Explicit error + return 1 | Preserved, including order and arguments |
| Marker directory / marker creation | Explicit error + return 1 | Preserved; marker still written after first successful full-upgrade, before reboot input |
| unminimize availability / installation | Install actually runs when minimized, user accepts and command is absent; status unchecked | Distinguish missing command from probe error; guard installation |
| dpkg-query in minimized detection | Filtered missing package and database/query failure enter same fallback | Query all package states; absence is ordinary data, failed query returns 2 even with valid stdout |
| excludes grep | No match and failed read enter same fallback | Only status 1 means no match; other failures log error and return 2 |
| man / less presence | Negation obscures abnormal command-probe status | Preserve presence heuristic, distinguish status 1 from operational failure |
| Startup detection | Any nonzero leaves IS_MINIMIZED=false | Accept only 1 as not minimized; propagate 2 out of script |
| unminimize process | PIPESTATUS[1] captured; nonzero accepted if negated detection succeeds | Preserve process-status policy, but accept only explicit not-minimized status 1; probe failure cannot authorize success |
| unminimize prompt | ask/read unchecked | EOF/read error stops with error; empty successful input remains Yes |
| reboot prompt | ask/read unchecked | EOF/read error stops with error; empty successful input remains Yes |
| Reboot delay / reboot command | Unchecked; menu can hide nonzero | Guard both, preserve five-second delay and command |
| Part1 success output | Printed before reboot input/failure | Emit existing success text only after successful completion or reboot refusal |
| Menu part1 dispatch | Status ignored, pause and another menu iteration follow | Propagate exact nonzero using exit $? |
| Menu selection / continuation read | Status ignored | Stop with input error on failed selection or pause |

## Preserved behavior

- No new update, install, autoremove or reboot policy. Package lists unchanged.
- Minimized + accepted unminimize: update, install only when missing, unminimize,
  update, full-upgrade/upgrade. Non-minimized/refused: update, full-upgrade/upgrade.
- Original prompt texts and default answers unchanged, including reboot default Yes.
- Refusing unminimize successfully skips only unminimize; normal updates still run.
- Refusing reboot succeeds. Successful unminimize clears IS_MINIMIZED for repeat calls.
- A nonzero unminimize process remains acceptable when a successful probe verifies
  the system is no longer minimized, matching the original policy.
- A reboot/input failure after first upgrade does not roll back the marker;
  a subsequent attempt uses upgrade, as before.
- Shared ask/pause implementations and other callers inside functions are unchanged.

## Isolated regression coverage

`tests/test_part1_error_contract.py` extracts actual functions and menu code without
executing the script's privileged startup. System commands are shell stubs. The
marker is `/stub/marker` with in-memory test/write stubs: no real marker is touched.
Read failures use actual Bash read against EOF or a closed descriptor.

Coverage includes minimized/not-minimized, database failure with/without output,
excludes no-match/read failure, command-probe failure, startup propagation,
unminimize availability/install/process failures, failed/successful post-probe,
both prompts and reboot-only input, refusals/defaults, delay/reboot failure,
existing apt/marker guards, exact menu status propagation, menu input/continuation,
happy path ordering, repeated calls and marker retention after failed reboot input.

Verification results and the exact tested head are recorded in the PR and the
accompanying output report, so this audit does not require a post-verification commit.

## Outside scope

UFW, SSH, swap, configure_pin/password/key handling, part2 package installation,
sysctl, all other part2 helpers, part3 implementation/tests, cloud checks, general
startup validation and logging failures. Their implementations and existing tests
are unchanged. Existing UFW/SSH/propagation tests are run as regressions only.

No live apt, unminimize, reboot, firewall or SSH configuration is executed by this
verification. Linux checks use an isolated checkout and existing stub/temp fixtures.
