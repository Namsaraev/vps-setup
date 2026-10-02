# F24/F27 package freshness and shell lifecycle inventory

Exact base: `15ec6030e436baac59e44f5ec99a7d4b920db918`, remote main checked before branching.
Branch: `fix/package-freshness-shell-lifecycle`. Initial checkout clean.

## Original findings, complete verbatim rows

Source: read-only audit dated 2026-09-21 at
`C:/Users/PIN/Downloads/Codex/2026-09-21/referenced-chatgpt-conversation-this-is-an/outputs/vps-setup-main-audit.md`.
Audited historical HEAD: `6653a7c9883c5025619defdaffc23b1668427198`.
SHA256: `5daf71f478d8c4fd048cf51e3a4474fdd2db9034eec8e1db92947d309d9c7f06`.
Rows below have historical line locations; exact-base execution paths follow separately.

| ID | Severity | Historical path | Exact issue wording | Exact impact | Original coverage | Recommendation |
|---|---|---|---|---|---|---|
| F24 | medium | `part1_update` L147,182; `install_packages` L212 | **APT's successful exit can include failed indexes.** Обычный `apt-get update` может завершиться 0 при transient fetch failure с использованием старых lists. | Upgrade/install и first-update marker продолжаются, хотя freshness/security index update не подтверждён. Это не повтор #3/#24: nonzero там уже обрабатывается. | APT stubs различают только return code; не моделируют реальную семантику partial update. | B: `APT::Update::Error-Mode=any` / поддерживаемый equivalent на targets |
| F27 | medium | `configure_shell` L1341–1367,1393,1512; final L1595–1605 | **Directory/file existence treated as usable shell installation.** Существующие пустые/повреждённые OMZ/theme/plugin directories пропускаются; `.zshrc` existence считается успехом. chsh выполняется до успешной подготовки окружения. | Повтор после interrupted clone или вручную созданного каталога печатает success, но новый shell не загружает компоненты. При install failure login shell уже изменён. | Shell fixture намеренно создаёт пустые каталоги, git stub создаёт лишь каталог; generated zshrc никогда не запускается настоящим zsh. | B: проверять нужные entrypoints, подготовить всё до chsh, не удалять пользовательские каталоги автоматически |

Source line numbers: 75, 78.

## Exact-base paths and confirmed behavior

F24: part1_update L547 (pre-unminimize), L582 (before first full-upgrade or repeat upgrade),
install_packages L612 (before required and optional installs). All three use plain
apt-get update and only reject nonzero. Marker selects full-upgrade vs upgrade;
it does not skip update. Native private APT fixture demonstrates zero exit with
failed transient indexes and nonzero when Error-Mode=any is requested.

F27: CURRENT_USER/SUDO_USER and passwd home selection L459-490; as_current_user
L2167-2169; configure_shell L2171-2324; final presence messages L2458-2470.
chsh is first. Existing component directories skip cloning, regardless of their
contents. Atomic writers protect user bytes, but startup/component syntax is not
validated. Existing fixtures deliberately create empty directories and clone stubs
only create directories. No change to initiating-user or pin policy is required.

## Changes

F24: add APT::Update::Error-Mode=any to the same three existing update calls.
No extra update/network operation, marker policy, upgrade/autoremove policy or
retry changes. Partial update stops upgrades/installs/marker creation.

F27: require readable nonempty OMZ/theme/autosuggestion/syntax-highlighting
entrypoints and completion functions, parse them with native zsh -fn as the
initiating user; preserve incomplete directories for manual repair. Register the
completions src in fpath before compinit. Parse generated and preserved user zshrc
without executing arbitrary startup code. Move chsh after successful preparation
and parsing. On chsh failure retain prepared config for repeat. Describe login
shell as applying to the next login; current session unchanged. Final-check file
presence messages explicitly describe presence and the configure_shell check.

## Validation and boundaries

New regressions cover partial apt update on first/repeat/unminimize/Part2 paths;
marker/repeat policy; native private APT transient failure; missing/empty/syntax
broken components, successful but empty clone, broken user rc, chsh failure and
retry, independent homes, native generated zshrc sourcing in a private home.
Existing shell fixtures now contain valid entrypoints and reflect deferred chsh.
No real host shell/user/package changes. Ownership and atomic write checks remain
in existing shell and persistence fixtures. Required full/focused/key suites and
CI evidence are recorded in the final verification report.

Limitations: syntax and entrypoint validation does not certify arbitrary plugin
runtime behavior or all transitive dependencies. Native startup fixture uses
minimal valid components; it does not execute remotely downloaded third-party
code. Existing arbitrary user startup code is parsed, never executed during setup.
A failed parse may leave prepared managed files, but login shell is unchanged;
retry is supported. No automatic deletion/repair of user component directories.
No real login/chsh or host package mutation integration test. APT target support
is verified by native Ubuntu APT fixture; no silent downgrade to default mode.

Scope: production only tunevps.sh. No endpoints/pinning changes, supply-chain
work, generic locks, SSH/UFW/swap/BBR/effective-config rewrites, cloud firewall,
second-login automation or new features. Draft only, no merge, no release-ready claim.
