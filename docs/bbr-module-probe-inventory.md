# F20: kernel-module probe contract

Exact base: `b6c9a9390b412fcc70ff5f7fc64c175865f30be2`; remote main
confirmed by GitHub and git ls-remote before branching. Clean clone; branch
`fix/bbr-module-probe`. This is the remaining module portion of F20 only.

## Recovered original finding

**F20 — Operational failure converted into availability/data.**

Original wording: «Ошибки modinfo/sysctl/grep превращаются в “BBR недоступен”,
включая удаление persistence file. `free | awk` status игнорируется, если
partial stdout содержит число.» Impact: «В первом случае теряется BBR
persistence и получается ложный fallback success; во втором решение о swap
принимается по неуспешному измерению. Отсутствие BBR после успешного probe —
допустимое состояние.» Severity medium; original locations
`configure_safe_sysctl` L445–476, swap RAM L621–624.

Source: existing local audit, not repository wording:
`C:/Users/PIN/Downloads/Codex/2026-09-21/referenced-chatgpt-conversation-this-is-an/outputs/vps-setup-main-audit.md`,
line 71; SHA256 `5daf71f478d8c4fd048cf51e3a4474fdd2db9034eec8e1db92947d309d9c7f06`.
The same row exists in the 2026-09-22 release-audit `old-findings-source.md`.
Its release audit explicitly deferred the remaining modinfo ambiguity.
Repository `docs/diagnostics-external-inventory.md` F20 records the prior
sysctl/free status fixes; they are retained, not rewritten here.

## Execution on exact base before edits

Menu Part 2 -> `part2_setup` L2318 -> checked `configure_safe_sysctl` L2335.
(The base line numbers are recovered from the base source, not the final file.)
`configure_safe_sysctl` L1012: L1022 combines missing modinfo and every failed
modinfo invocation into `bbr_module=false`. Checked sysctl reads at L1026 and
L1045 do not repair that ambiguity. No reported module means no modprobe at
L1035. If runtime algorithms omit bbr, L1060 deletes
`/etc/modules-load.d/tcp_bbr.conf`; the generated sysctl fragment omits BBR/fq
and L1085 applies the fallback. The step can report success at L1101.
Successful modprobe without runtime BBR also reaches this fallback.

The new isolated tests can select the unchanged base via `F20_AUDIT_SOURCE`.
They reproduce lost module persistence/false fallback and missing propagation;
all filesystem mutations are in temporary directories and all runtime loads,
algorithm reads and sysctl applies are stubs.

## Narrow implementation

- Checked `modinfo -F filename` distinguishes `(builtin)` from module filenames.
  Failed/empty/malformed output is never interpreted as absence or consumed.
- On an indeterminate probe, read `/boot/config-$(uname -r)` with checked status.
  Require exactly one explicit BBR setting: `m` identifies a loadable module,
  `y` built-in support, and `# CONFIG_TCP_CONG_BBR is not set` permits the
  existing optional fallback. Missing/unreadable/partial/ambiguous data fails
  before configuration writes or removals. No stderr wording/exit-code guess.
- For an unloaded loadable module, require successful `modprobe --dry-run`
  before the existing checked real load. Require BBR in the subsequent checked
  runtime list whenever module/built-in support was identified. A successful
  loader without runtime BBR is an error, not fallback success.
- Preserve BBR/fq values, sysctl/limits policy, atomic writers and checked Part 2
  propagation. Built-in support does not need modprobe or a new module-load row;
  loadable support retains module persistence, including repeat repair.

Production diff is confined to `configure_safe_sysctl` in `tunevps.sh`.
Existing sysctl fixtures now explicitly model kernel config and dry-run status;
existing diagnostics fixtures report a successful built-in probe so their failed
sysctl reads remain exercised. No workflow change or host sysctl mutation.
A real kmod dry-run fixture uses a private module root and install directive;
its marker must never be created. Real Linux modinfo and read-only dry-run of
host tcp_bbr were also checked without loading/unloading it.

## Limits and deferred scope

The fallback trusts the running kernel's installed `/boot/config-*`; it cannot
verify that an administrator supplied matching build metadata. Images without
that file can use a successful modinfo probe, but otherwise fail conservatively
until trustworthy metadata/tools are restored. No `/proc/config.gz` discovery
or install-command/alias policy redesign. Module load is not reversible here;
if runtime verification fails, existing configuration is retained but any load
that already succeeded remains. No concurrent-edit/crash transaction guarantee.

F21/F22/F24/F25/F26/F27, supply-chain pinning, generic locking, cloud firewall
and second-login automation remain deferred. This PR is DRAFT, must not be
merged by this task, and does not declare the whole release ready.
