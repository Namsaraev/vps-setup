# F21/F22/F25/F26: effective configuration bundle

Exact base: `c25c1c486f9e1f030c21f930cad825d0c0a7c319` (PR #32 squash).
Remote main verified through GitHub before branching; branch
`fix/effective-config-bundle`, clean exact-base checkout.

## Original findings (verbatim complete rows)

Source: existing local read-only audit dated 2026-09-21, audited HEAD
`6653a7c9883c5025619defdaffc23b1668427198`:
`C:/Users/PIN/Downloads/Codex/2026-09-21/referenced-chatgpt-conversation-this-is-an/outputs/vps-setup-main-audit.md`, lines 72, 73, 76, 77. SHA256 `5daf71f478d8c4fd048cf51e3a4474fdd2db9034eec8e1db92947d309d9c7f06`.
All four original severities are medium; locations in these rows are historical.
The short labels in prior inventories were not treated as full findings.

| ID | Severity | Original path | Exact issue wording | Exact impact | Original coverage | Recommendation |
|---|---|---|---|---|---|---|
| F21 | medium | sysctl L479–516; auto-upgrades L252–279; autoremove L286–294 | **Written fragment ≠ effective configuration.** Поздние config files могут переопределить managed fragment. `sysctl --system` status 0 не означает, что итоговые значения равны запрошенным. `50auto-remove` может быть переопределён поздним `50unattended-upgrades`/custom file. | Заявления «автоудаление отключено», «автообновления включены», «sysctl применены» могут быть неверными. Для autoremove реальный trigger — позднее явное `true`, а не стандартный commented default. | Tests сравнивают один target file; aggregate APT/sysctl loader не выполняется. | B: read-only effective verification; не переписывать чужие overrides молча |
| F22 | medium | limits.d L507–510; `configure_systemd_limits` L528 | **Global high soft NOFILE risk.** Один `DefaultLimitNOFILE=1048576` задаёт и soft, и hard; PAM soft=524288 также глобален. | Приложения с select/FD_SETSIZE могут ломаться при FD>1023. Наличие Xray/Docker не означает безопасность этого default для всех процессов. Это compatibility risk при высоких FD, не гарантированный сбой каждого сервиса. | Тесты закрепляют текст значения, нагрузочного/процессного теста нет. | B: консервативный global soft либо явно ограниченный scope; изменение чисел должно быть осознанным |
| F25 | medium | `configure_unattended_upgrades` L263–278 | **Enabled timer mistaken for active timer.** Только is-enabled/enable; нет start/active check. | После `disable --now` последующий enable не запускает таймер сейчас; вывод «обновления включены» не подтверждает runtime scheduling до reboot. Best-effort политика допустима, недостоверный OK — нет. | Enabled/enable failure tests есть; active/stopped state отсутствует. | B: best-effort enable/start или честное сообщение и runtime warning |
| F26 | medium | `configure_needrestart` L349–427 | **Textual verification is not effective mode verification.** Проверяется повторное преобразование основного Perl-файла, но не later conf.d overrides/Ubuntu APT hook behavior. | При последующем conf.d assignment `restart='l'` сообщение «автоматический перезапуск включён» неверно. `No` корректно оставляет настройки, но на Ubuntu 24.04 это не означает запрета уже включённых автоматических restarts. | Сильные tests write/metadata/errors, но fixtures — маленькие фрагменты; hook/snippet loading отсутствует. | B: detect supported conflicts/точный scope сообщения; не выполнять произвольный Perl ради валидации |

## Execution paths on exact base (before changes)

Menu Part 2 -> `part2_setup` L2353:

- F21: checked `configure_unattended_upgrades` L2364 -> function L824,
  managed `20auto-upgrades` write L827, no aggregate APT query before OK L850.
  `configure_autoremove` L2367 -> L857, `50auto-remove` write L861,
  OK L869 before checked dry-run L872; later explicit true overrides ignored.
  `configure_safe_sysctl` L2370 -> L1012, managed sysctl L1100, checked
  `sysctl --system` L1120 followed by no per-key runtime comparison, OK L1136.
- F22: same sysctl path writes PAM wildcard/root soft=524288 and hard=1048576
  L1127-1130. `configure_systemd_limits` L2375 -> L1141 writes single
  `DefaultLimitNOFILE=1048576` L1148 (both soft and hard); checked reexec L1154
  without checking manager's effective defaults before OK L1155.
- F25: upgrades path above -> is-enabled/enable loop L840-847. Enabled but
  stopped timer skips enable and gets global OK L850. No active/scheduling probe.
- F26: checked `configure_needrestart` L2368 -> L909, consent/confirmation
  -> Python main-file transform L925-997 and persisted-byte verification
  L986-988 -> scoped main-file OK L1002 and override warning L1003. This base
  already corrected the original false automatic-restart wording, but neither
  conf.d conflicts nor failed aggregate probes stopped the selected setup.

Regression harnesses can select the unchanged exact-base source with
`BUNDLE_AUDIT_SOURCE`; no production provisioning or host mutation is executed.

## Subsystem changes

- F21: checked native `apt-config shell` resolves all four periodic keys and
  both autoremove flags after the atomic writes. Missing, mismatched, malformed
  or failed output stops the step before timer enable/autoremove. Checked
  `sysctl --system` is followed by checked per-key runtime reads, compared with
  the complete checked managed snapshot. Preserve desired APT/sysctl values;
  conflicting administrator files are not rewritten.
- F22: explicit conservative global soft=1024, preserve hard=1048576, for
  wildcard/root PAM and systemd `1024:1048576`. This is the deliberate numeric
  change required by the actual compatibility finding, not an unrelated retune.
  Read-only PAM nofile scan refuses conflicting/unsupported rows across main
  limits.conf and all .conf snippets (including per-user/group entries).
  Verify manager effective soft/hard after checked reexec. State that PAM
  settings concern new pam_limits sessions and service defaults concern future
  service launches; never claim running processes or per-unit overrides changed.
- F25: distinguish checked enabled/disabled from unknown/masked enablement;
  only confirmed disabled authorizes the existing best-effort enable attempt.
  Require loaded, persistently enabled, active/waiting, no stale daemon reload,
  and a nonempty/nonzero next realtime or monotonic expiry before scheduling OK.
  Stopped/unknown/unscheduled states warn and preserve best-effort return 0.
  No timer starts/restarts added; real host timers are never changed in tests.
- F26: checked aggregate APT snapshot detects explicit conflicting restart-mode
  or suspension arguments in visible needrestart hooks. Before writing main,
  scan conf.d without executing Perl; permit comments/blank lines and literal
  restart=a only, refuse conflicting or opaque executable snippets and read
  errors. Conflicting NEEDRESTART_MODE or active NEEDRESTART_SUSPEND refuses the step. Preserve existing
  consent, atomic main-file transform and checks. Output explicitly states
  supported static checks and does not claim runtime effective automatic mode.

Production edits only in tunevps.sh; no SSH/UFW/swap/BBR policy, loaders,
endpoints or supply-chain trust changes. Existing test fixtures now represent
the added read-only probes; atomic fault injection remains confined to the
writer rather than intercepting unrelated Python probes. No workflow change.

## Boundaries and remaining work

Native APT/sysctl/manager probes verify the current snapshot, not future edits
or crash/concurrent transactions. PAM scan is intentionally conservative;
compatible custom entries may require manual review. It does not execute PAM
or prove a real future login loaded pam_limits. Existing running services keep
their rlimits; per-unit overrides are preserved. Manager reexec is existing
production behavior and is stubbed in tests.

Timer verification is a current scheduling observation, not a guarantee that
the future APT service succeeds. Stopped timers are reported honestly and need
manual start/reboot; timer cadence/drop-ins are preserved.

Needrestart arbitrary Perl in the main config or hook scripts is not evaluated
or certified. The checker intentionally refuses opaque conf.d snippets;
visible literal APT conflicts are detected, but arbitrary shell hook internals,
alternate loaders/CLI arguments and future environment may still change mode.
The success text means main-file mode persisted with supported conflict checks,
not effective runtime automatic restarts or every service restart. This is the
original audit's safe conflict-detection/precise-output option, not Perl eval.

F24/F27 remain deferred. No release-ready claim, no merge. No new dependencies,
features, generic locking, pinning, cloud firewall or second-login automation.
