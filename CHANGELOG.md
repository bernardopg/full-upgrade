# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/).

## [3.0.0] — 2026-06-01

### Adicionado
- **Arquitetura modular**: script monolítico (4243 linhas) fatiado em `lib/*.sh`
  por responsabilidade (globals, core, ui, json, sudo, config, catalog, cli, main
  + `lib/steps/` por domínio). Entrypoint fino faz source na ordem de dependência.
- **Sistema de configuração** (`~/.config/full-upgrade/config`): zero-config funciona;
  overrides de path, listas de ignore, idioma, ferramentas de snapshot/mirror.
- **Plugin dir** (`steps.d/`): tools custom drop-in, habilitados via `ENABLE_CUSTOM_TOOLS=1`.
- **4 coberturas novas**:
  - Lockfile (`flock`) anti-concorrência entre instâncias.
  - Snapshot pré-upgrade (snapper/timeshift, auto-detect, só em btrfs).
  - Mirror refresh (reflector/rate-mirrors, com backup do mirrorlist).
  - Pré-flight de disco (espaço mínimo) + `archlinux-keyring`.
- **Visual**: símbolos `✔ ✘ ⚠ → ⊘` (fallback ASCII), largura adaptativa,
  barra de progresso `[N/TOTAL] ▓▓░░ NN%`, resumo agrupado por categoria.
- `install.sh`, `build.sh` (standalone opcional), `config.example`.

### Corrigido
- `update_dms_plugins`: auto-recuperação de divergência git (reset/stash) em vez de
  falhar com `pull --ff-only`.

### Notas
- Saída permanece em **PT-BR** (i18n bilíngue planejado para versão futura).
- De-hardcode: caminhos de gcloud/copilot/adguard/DMS agora vêm do config.
