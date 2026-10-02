# Swap F18/F19: exact-base inventory and recovery contract

Base: `f4560b904531e15ad18409a0feb2fda5dfc47085`, checked through GitHub
and `git ls-remote refs/heads/main` before branching. Clean clone before edits;
branch `fix/swap-recovery-size`. This is a two-finding subsystem bundle, not a
new release audit.

## Recovered original findings

The repository history contains only abbreviated labels in
`docs/persistence-repeat-inventory.md`. Full original texts were recovered from
the existing local report `vps-setup-main-audit.md` dated 2026-09-21, lines 69–70,
also copied as `old-findings-source.md` in the 2026-09-22 release-audit outputs.
Original audit locations refer to that older revision, not today's base:

- **F18 — Destructive replacement before allocation succeeds.**
  «Старый swap отключается и удаляется до создания нового; при
  allocation/mkswap/swapon failure остаётся без рабочего собственного swap.»
  Original location: `configure_swap` L638–668. Impact: «Под нагрузкой возможна
  нехватка памяти/OOM; повторный запуск уже не может восстановить старый файл.
  Код возвращает ошибку — это failure-state risk, а не false success.»
- **F19 — Size parser and fallback disagree.** «Разрешены `2GB` и другие
  суффиксы, но внутренний parser трактует GB как GiB; fallocate различает
  десятичные/двоичные суффиксы. dd округляет вниз до MiB, минимум 1 MiB;
  arithmetic overflow не проверяется.» Original locations: `swap_size_to_bytes`
  L550–575, fallback L649–656, final L682–687. Impact: «При допустимом custom
  SWAP_SIZE фактический размер не соответствует desired_bytes; повтор снова
  предлагает replacement. Финальная проверка требует только size>0 и может
  объявить неверный размер успешным. Default `2G` этого расхождения не имеет.»

The release audit categorized both as deferred future hardening, medium
severity; it did not call them separate SSH access blockers. This bundle closes
these two confirmed swap defects without changing the other deferred findings.

## Execution at the exact base, before edits

`part2_setup` L2282 calls `configure_swap` L1127 under `if !`; failures already
stop Part 2. Thus explicit status handling is necessary even with `set -e`.

- Size validation/parser: L1134–1161, unchecked signed multiplication; `GB`
  uses 1024 cubed. Matching check L1183–1192 assumes at most one header page
  difference, rather than accounting for a partial final page.
- Creation conditions: active matching `/swapfile` repairs persistence;
  mismatching owned swap requires replacement consent; foreign-only swap
  requires consent to add; no active swap creates only at RAM <= 2048 MB.
  Foreign sources are listed and left alone. These decisions are preserved.
- Replacement: L1227 disables old owned swap, L1231 removes its file; allocation
  L1239, chmod L1250, formatting L1251 and activation L1254 follow. No old-file
  recovery remains on subsequent failure. Inactive existing files are removed
  too. Runtime failure returns nonzero; it does not falsely return success.
- Fallback L1240–1247 floors bytes to MiB, with a minimum 1 MiB. Final L1262
  accepts any positive owned size and masks a failed listing if it printed a
  usable row. Persistence L1260 precedes this runtime verification.
- `persist_swap` L816 delegates to the existing atomic writer. Successful
  runtime activation followed by failed persistence stays active and returns
  failure; repeat repairs fstab. This useful repair contract is preserved.

Linux before-fix reproduction uses the new test module with the unchanged base
source (or `SWAP_AUDIT_SOURCE` pointing to it), isolated files and mocked
swapon/swapoff. Preparation/activation failures demonstrate lost old bytes;
non-MiB dd fallback demonstrates actual 1048576 instead of 65537 or 1573888.
The decimal/binary parser mismatch is independently checked against the
[util-linux fallocate specification](https://kernel.googlesource.com/pub/scm/utils/util-linux/util-linux/+/refs/tags/v2.41.1/sys-utils/fallocate.1.adoc).

## Implemented scope

- Parse the existing accepted uppercase units into checked signed-64-bit bytes.
  `KB/MB/GB/TB/PB` are decimal; bare units and `i/iB` are binary. Reject overflow
  and sizes too small for a data page before mutation. Keep default `2G` and
  RAM threshold `2048`. Use one byte value for fallocate and GNU dd's
  `iflag=count_bytes`; no MiB rounding. Check staged file length, then format.
- Calculate runtime capacity as `floor(file_bytes / PAGESIZE) * PAGESIZE -
  PAGESIZE`. Require the actual page probe and that exact runtime size, including
  repetition and final verification. Reject malformed/duplicate/nonfile owned
  runtime rows. Failed listings remain failures even with partial stdout.
- Create an unpredictable mode-0600 same-directory candidate while old swap is
  active. Allocation/permission/format failure leaves the old file and runtime
  alone. Reserve a backup path before disabling the owned swap. Check that it
  is actually inactive, retain the old file by rename, install and activate the
  candidate, then verify runtime before changing fstab or discarding the backup.
- Install/activation/wrong-size failure checks whether the candidate is active,
  disables it if necessary, checks inactivity, restores old bytes by rename,
  reactivates previously active old swap and checks its prior runtime size.
  An inactive old file is restored without activation. A failed swapoff that
  nevertheless disabled the old swap also attempts checked reactivation.
- Failed recovery reports FATAL and keeps recoverable bytes. An unreadable
  runtime state never authorizes deleting or renaming a possibly active file;
  diagnostics identify retained candidate/backup paths for manual repair.
  Cleanup failures are nonzero. Persistence failure retains the verified new
  runtime swap, reports the existing persistence error, and stops real Part 2.
  Its next matching run repairs fstab without replacement or prompts.
- Existing atomic/idempotent fstab writer and foreign-row preservation are
  unchanged. Production changes are confined to `configure_swap` in
  `tunevps.sh`. Fixtures now model a file's actual staged size; the former
  full-file-size active mock is replaced by the real header-page capacity.

## Verification and limits

`test_swap_release_blockers.py` uses real temporary files, fault-injected runtime
commands, real small fallocate/dd/mkswap checks, and real Part 2 orchestration.
It never calls real swapon/swapoff or changes host fstab/services. Existing swap,
persistence/repeat, propagation and OpenSSH regressions remain in full discovery.
Exact final SHA, counts and actual CI logs are recorded in the PR and delivered
verification report, avoiding a self-referential commit SHA here.

This is checked in-process recovery, not crash/power-loss recovery, generic
locking, a concurrent-administrator transaction, or a guarantee of sufficient
RAM for swapoff. Preparation needs space for old and replacement simultaneously.
Recovery commands can fail; such failures preserve available bytes and require
manual repair. After an unreadable runtime probe the old file may be inactive;
the script fails without guessing or deleting resources. Filesystems whose
fallocated files cannot be activated fail safely and restore old swap; automatic
retry after such an activation failure is not introduced. Real kernel swap
activation is modeled, not exercised on the test host.

F20/F21/F22/F24/F25/F26/F27, supply-chain pinning, generic locking, cloud firewall
and second-login automation remain deferred. This draft does not declare the
whole release ready and must not be merged by this task.
