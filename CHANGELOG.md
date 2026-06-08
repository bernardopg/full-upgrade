# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/).

## [3.0.3] — 2026-06-08

### Adicionado

- **Suíte de testes `bats`** (`tests/`): primeira rede de testes unitários do
  projeto, cobrindo funções puras sem mutação:
  - `core.bats` — `elapsed`, `_strip_ansi`, `has`, `add_skip_step`/
    `skip_step_count`, `_step_skip_requested` (com trim), `aur_ignore_args`.
  - `catalog.bats` — `catalog_match_token`, `catalog_info_for_step`,
    `catalog_has_token`, `count_effective_steps`, `apply_only_category`.
  - `catalog_integrity.bats` — invariantes do `step_catalog`: 8 campos por linha,
    timeout inteiro, efeito `read`/`mutating`, nomes de step únicos (a chave de
    junção do framework) e todo `func_name` referenciado existindo em
    `lib/steps/*.sh`, `lib/sudo.sh` ou `steps.d/*.sh`.
  - `tests/test_helper.bash` carrega as libs num shell isolado
    (`globals → ui → core → catalog`) com I/O neutralizado.
- **CI**: novo passo `Unit tests (bats)` no workflow de CI, entre o smoke test e
  o build do standalone.
- Documentação de teste em `README.md`, `CLAUDE.md` e `CONTRIBUTING.md`.

## [3.0.2] — 2026-06-08

### Corrigido

- **`doctor_journal_errors`: timeout em journals grandes.** O filtro de ruído
  reprocessava a saída inteira a cada padrão em subshells encadeados; em journals
  com dezenas de milhares de linhas críticas isso estourava o timeout de 30s do
  step. Agora aplica todos os padrões em uma única passada com `grep -Evf`
  (com fallback defensivo se `mktemp` falhar).
- **`doctor_fwupd_security`: aviso indevido em HSI alto.** Passa a avaliar o nível
  HSI agregado (`>= 2` é aceitável) em vez de tratar todo sufixo `!`
  (HSI-Runtime) ou marcador `✘` de sub-item como problema. `HSI:3!` não vira mais
  `warn`.
- **Logs de auditoria com escapes ANSI crus.** A saída de comandos externos
  (ex.: `fwupdmgr`) era gravada no `$LOG_FILE` com sequências de cor; o arquivo
  agora é limpo via novos helpers `_strip_ansi`/`log_raw`, enquanto o terminal
  mantém as cores.

### Adicionado

- **Campo `reason` no JSONL para `ok`/`warn`/`todo`/`fail`.** Steps definem
  `STEP_REASON` (ex.: contagem de CVEs, `.pacnew` pendentes, serviços com libs
  antigas) e o evento JSONL passa a registrar o motivo. `run_step` recupera o
  valor mesmo quando a função roda no subshell de timeout.
- **`doctor_desktop_health`: sugestão de backend de portal.** Quando o
  `xdg-desktop-portal` está ausente, sugere o pacote correto conforme o
  compositor/sessão (`-hyprland`, `-gnome`, `-kde`, `-wlr`).
- **`CLAUDE.md`** documentando arquitetura, comandos e o padrão de steps para
  contribuição assistida.

## [3.0.1] — 2026-06-05

### Adicionado

- **Suporte a OpenClaw** (`steps.d/60-openclaw.sh`):
  - Novo step custom `update_openclaw` para atualização do OpenClaw CLI.
  - Integração completa com sistema de configuração: `OPENCLAW_BIN` em `config.example`,
    default vazio, auto-detecção via `command -v openclaw` em `lib/config.sh`.
  - Entry no catálogo (`lib/catalog.sh`): categoria `ai`, tags `openclaw,update,network`,
    timeout 120s, função `update_openclaw`.
  - Registro no fluxo principal (`lib/main.sh`) via `custom_step_or_skip` na seção AI CLIs.
  - Gated por `ENABLE_CUSTOM_TOOLS=1` (consistente com Hermes, AdGuard, Copilot, DMS).
- **Melhorias no step OpenClaw**:
  - Log do path do binário detectado.
  - Detecção e log de versão atual via `--version`.
  - Log estruturado no `$LOG_FILE` com timestamp ISO e separadores visuais.
  - Tratamento inteligente de "já atualizado" (case-insensitive, padrões PT/EN:
    `already up to date`, `latest version`, `já está atualizado`, `nothing to do`, etc.).
  - Sanitização de ANSI escape codes na saída do terminal.
  - Limite de 30 linhas no output do terminal (evita flood).
  - Retorno do código de saída original do comando.

### Corrigido

- `lib/cli.sh`: refatoração de formatação/indentação (estilo consistente, sem mudança lógica).
- `lib/sudo.sh`: refatoração de formatação/indentação (estilo consistente, sem mudança lógica).

### Notas

- Arquivo renomeado: `steps.d/60-openclawn.sh` → `steps.d/60-openclaw.sh` (correção ortográfica).
- Nova variável de configuração documentada: `OPENCLAW_BIN` (ex: `/usr/local/bin/openclaw`).

## [3.0.0] — 2026-06-01

### Adicionado

- **Arquitetura modular**: script monolítico (4243 linhas) fatiado em `lib/*.sh`
  por responsabilidade (globals, core, ui, json, sudo, config, catalog, cli, main
  - `lib/steps/` por domínio). Entrypoint fino faz source na ordem de dependência.
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
