# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`full-upgrade` is a modular Bash orchestrator for upgrading, maintaining, and auditing Arch Linux machines. Pure Bash 4+, no compiled artifacts. Output and inline comments are PT-BR.

## Commands

```bash
# Validation (run before any commit — mirrors CI)
bash -n full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh
shellcheck -S warning -x full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh
shfmt -i 4 -d full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh scripts/*.sh   # advisory (consultivo)

# Unit tests (bats — pure functions only; safe anywhere, no mutation)
bats tests/
bats tests/core.bats          # single file

# Smoke tests (no mutation; safe to run anywhere, even non-Arch CI)
./full-upgrade.sh --help
./full-upgrade.sh --list-steps
./full-upgrade.sh --explain-step "Doctor: saúde de rede"
./full-upgrade.sh --config
./full-upgrade.sh --config-example
./full-upgrade.sh --tray --status
XDG_CONFIG_HOME=/tmp/nocfg ./full-upgrade.sh --dry-run --mode full

# Build single-file distributable -> dist/full-upgrade-standalone.sh
./build.sh

# Install to ~/.local/share/full-upgrade + symlink in ~/.local/bin
./install.sh
```

Verification = `bash -n` + `shellcheck` + `bats tests/` + smoke flags + `--dry-run`. The `bats` suite covers pure functions and regression helpers (catalog parser, RC/skip helpers, catalog integrity, Docker timeout parsing, pip/Poetry ignore logic, mirrorlist validation, systemd user-scope detection, recursive orphan cleanup, snapshot retention, summary category totals/top slow steps, shared version compare, final pending reasons, build-warning filtering, tray state helpers, and reboot footer formatting) and never mutates; see `tests/` and `tests/test_helper.bash` (which sources `globals → ui → core → catalog`; tray tests additionally source `lib/tray.sh`). `--dry-run` registers every step as `skip` without running mutating commands, so it is the primary way to exercise the full flow safely.

## Architecture

Entrypoint `full-upgrade.sh` is thin: resolves the project root (follows symlinks so the `~/.local/bin` symlink works), sources `lib/*.sh` **in dependency order**, then runs `load_config → parse_args → apply_mode_and_early_exits → setup_logging → print_banner → run_all_steps → finalize`.

Load order matters (set in the entrypoint): `globals → ui → core → json → sudo → config → catalog → cli → report → history → notify → tray → steps/*.sh → main`. `lib/steps/*.sh` are sourced in glob order but only define functions, so order among them is irrelevant. `lib/main.sh` is sourced last because it uses everything.

### The step framework (the central pattern)

Everything is a step run via `run_step "Nome exato" funcao_impl` (`lib/core.sh`). `run_step`:
1. honors `FULL_UPGRADE_SKIP` (comma-separated exact step names);
2. short-circuits to `skip` under `--dry-run`;
3. reads the step's metadata from the catalog and skips with `cmd-ausente: X` if a declared command dependency is missing;
4. enforces the per-step timeout (background function + sentinel `sleep` + `wait -n`; timeout → rc 124 → `warn`);
5. maps the function's return code to a status.

Return-code contract (`lib/globals.sh`): `0`→ok, `RC_WARN`(10)→warn (non-blocking / transient, e.g. network), `RC_TODO`(11)→todo (manual action needed), anything else→fail. Only `fail` affects the exit code (final exit `2`). Network helpers `run_network_cmd` and `_retry` convert DNS/connectivity errors into `RC_WARN` so a flaky network never fails the run.

### Catalog ⇄ dispatch (two places, kept in sync)

- `lib/catalog.sh` — `step_catalog()` is a heredoc table, one line per step:
  `nome|categoria|tags|efeito|timeout|cmd_deps|func_name|descrição`. This drives `--list-steps`, `--explain-step`, command-dep skipping, per-step timeout, `--only`/`--skip-category` matching (matches against `categoria` + `tags`), and the progress-bar total (`count_effective_steps`).
- `lib/main.sh` — `run_all_steps()` is the actual execution order, gated by `has <cmd>` / `SUDO_READY` checks. When a precondition fails it calls `step_skip "Nome" "motivo"` so the step still appears in the summary.

**The step name string is the join key.** It must be byte-identical in the catalog line, the `run_step`/`step_skip` call in `main.sh`, and any `--skip`/`--explain-step` argument. A mismatch silently breaks metadata lookup (timeout/deps fall back to defaults).

### Adding or changing a step

1. Implement the function in the relevant `lib/steps/<domain>.sh` (ai, audit, backup, cleanup, containers, coverage, doctor, editor_shell, firmware, ide, lang_js, lang_other, lang_py, lang_rust, mcp, news, pacman, repair, self_update).
2. Add a catalog line in `lib/catalog.sh` with a realistic timeout and any `cmd_deps`.
3. Call it from the correct point in `lib/main.sh` `run_all_steps()`.
4. Use `RC_WARN`/`RC_TODO` for non-fatal outcomes; let a missing dependency become `skip`, not `fail`.

### Modes & filters

`--mode full|update|doctor|repair` and `--only`/`--skip-category` are resolved in `apply_mode_and_early_exits` (`lib/cli.sh`) by populating `FULL_UPGRADE_SKIP` before the run. `--only`/`--skip-category` always keep `core` and `final` category steps. `--mode doctor` additionally calls `add_skip_mutating_steps` so every step with `efeito=mutating` is skipped — doctor mode is guaranteed read-only even for core/final steps. So filtering is implemented entirely as "add to the skip list," and `run_all_steps` itself is filter-agnostic.

### Config & custom tools

`load_config` (`lib/config.sh`) sources `~/.config/full-upgrade/config` (plain Bash — zero-config works) and auto-detects binary paths. Packaged integrations in the repository `steps.d/*.sh` are always sourced; each step decides whether to run by tool presence and its own gate. User plugins in `~/.config/full-upgrade/steps.d/` are sourced only with `ENABLE_CUSTOM_TOOLS=1`, because they are arbitrary local code. Burp/Wireshark remains explicit opt-in through `custom_step_or_skip` because its helper may install `burpsuite`.

### Logging

`lib/json.sh` `setup_logging` defines `RUN_ID` and writes paired artifacts to `~/.cache/system-upgrade/`: `full-upgrade-<run_id>.log` (human) and `.jsonl` (one event per step + `run_start`/`run_end`/`summary`), with `latest.log`/`latest.jsonl` symlinks and rotation keeping the newest 20 of each. Use `log` (respects `--quiet`, tees to log) vs `log_always` (always to terminal). `--json` prints a one-line summary at the end.

### Systray daemon

`lib/tray.sh` implements the optional systray applet. On Wayland it uses AppIndicator via Python/GI when available; on X11 it falls back to `yad --notification --listen`. It is an early-exit CLI surface: `--tray` starts the daemon, `--tray --enable|--disable|--status|--check` manages/checks it, `--tray-launch` and `--tray-view-log` are internal menu actions. Pure helpers in `tray.sh` are covered by `tests/tray.bats`; GUI/runtime behavior is smoke-tested via `--tray --status` and `--tray --check` when network is acceptable. State priority is `running > error > attention > updates > idle`, persisted in `~/.cache/system-upgrade/tray-state.json`. Icons live in `assets/icons/` in dev, are copied to `${DEST_DIR}/icons`, and are also installed into hicolor by `install.sh`.

## CI / Quality / Security

GitHub Actions workflows in `.github/workflows/` (all pinned by SHA, least-privilege, `timeout-minutes`):

- **CI** (`ci.yml`) — `bash -n` + `shellcheck` + `shfmt` (advisory) + smoke flags + `bats tests/` + standalone build verification. On PRs the bats suite runs plain (fast feedback); kcov coverage → Codecov and the standalone artifact upload run only on push/dispatch (the suite would otherwise run twice). Mirrors the local validation above.
- **CodeQL** (`codeql.yml`) — analyzes the workflow files themselves (`language: actions`); **CodeQL does not support Bash**, so Bash SAST is handled by Semgrep. Path-filtered to `.github/workflows/**` + weekly schedule; NOT a required check (PRs that don't touch workflows never produce it).
- **Semgrep** (`semgrep.yml`) — SAST for Bash (`p/default`); uploads SARIF to Code Scanning. Advisory (`continue-on-error`) until findings are triaged — then drop `continue-on-error`. Path-filtered to `**.sh`/`**.bash` + its own setup files + weekly schedule.
- **OpenSSF Scorecard** (`scorecard.yml`) — publishes the repo security score (feeds the README badge) + SARIF.
- **Stale** (`stale.yml`) — marks/closes inactive issues & PRs (60 days → stale, +14 → close); weekly cron.
- **Labeler** (`labeler.yml` + `.github/labeler.yml`) — auto-labels PRs by changed path (`ci`, `lib`, `tests`, `steps`, `scripts`, `packaging`, `documentation`). The labels must exist in the repo.
- **Commitlint** (`commitlint.yml` + `.commitlintrc.json`) — enforces **Conventional Commits** on PR commit messages (`feat:`, `fix:`, `ci:`, …); self-contained ruleset (no node deps).
- **Dependabot** (`.github/dependabot.yml`) — `github-actions` ecosystem only (the project has no package manifests); groups minor/patch, opens majors individually, keeps the SHA-pinned actions current.
- **Release** (`release.yml`) — on `v*` tag push (or `workflow_dispatch`): validates, builds standalone + sha256, publishes a GitHub Release with auto notes, and publishes to the AUR (`KSXGitHub/github-actions-deploy-aur`).

Branch protection (`main-protection` ruleset): PR required; required checks are `Lint & Test` + `Validar Conventional Commits` only; no forced branch-up-to-date, no thread-resolution requirement, no bot reviewers.

Coverage (`codecov.yml`): kcov measures only what `bats` executes; orchestration/entrypoint files with side-effects (`install.sh`, `build.sh`, `full-upgrade.sh`, `lib/main.sh`, `lib/cli.sh`, `lib/sudo.sh`) are `ignore`d — they are not unit-testable by design (see `tests/test_helper.bash`). The `flags.bats` uses `carryforward`. `.editorconfig` pins the canonical `shfmt` style (`-i 4`, 4-space indent). Travis CI was removed (defunct free OSS tier; redundant with GitHub Actions).

## Conventions

- All step functions return via the RC contract; never `exit` from inside a step.
- Guard external tools with `has <cmd>` before calling; prefer letting `run_step`'s catalog-dep check produce the `skip`.
- `set -uo pipefail` is active (no `-e`) — check return codes explicitly.
- Comments and user-facing strings are PT-BR; keep that voice when editing.
- `build.sh` inlines all libs into one file — anything relying on separate file paths at runtime (beyond root resolution) will break the standalone build, so test `./build.sh && ./dist/full-upgrade-standalone.sh --list-steps` after structural changes. The systray can run from standalone, but icons are external assets; it falls back to hicolor/theme lookup if no `icons/` directory is beside the script.
- Commits use **Conventional Commits** (`feat:`, `fix:`, `ci:`, …), enforced by commitlint on PRs (`.commitlintrc.json`). This keeps the auto-generated release notes clean.
