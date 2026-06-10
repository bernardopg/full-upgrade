# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

## [3.1.1] — 2026-06-10

### Corrigido

- **Versão embutida errada ao buildar de um tarball dentro de outro repo git.**
  `build.sh`/`install.sh` rodavam `git describe` sem checar o repositório: ao
  construir o pacote AUR (makepkg extrai o tarball dentro do clone git do AUR),
  o `SCRIPT_VERSION` virava o commit do repo do AUR (ex.: `a0c4017`) em vez de
  `3.1.0`. Agora só usam `git describe` quando o toplevel do git é o próprio
  projeto (contém `full-upgrade.sh` + `build.sh`/`install.sh`); caso contrário
  usam o arquivo `VERSION`. Detectado testando a instalação real via AUR.

## [3.1.0] — 2026-06-10

### Distribuição

- **Pacote AUR `full-upgrade`** (`packaging/aur/PKGBUILD` + `.SRCINFO`). Pacote
  source: baixa o tarball da tag, roda `build.sh` e instala o executável único
  em `/usr/bin/full-upgrade`, com `config.example`, docs e licença nos caminhos
  padrão. Instale com `yay -S full-upgrade` / `paru -S full-upgrade`.
- **Publicação automática no AUR** a cada release (job `publish-aur` em
  `release.yml`): fixa `pkgver`, calcula o `sha256sums` real do tarball e
  publica via `KSXGitHub/github-actions-deploy-aur` (pinada por commit SHA).
  Requer os secrets `AUR_USERNAME`/`AUR_EMAIL`/`AUR_SSH_PRIVATE_KEY` — veja
  `packaging/aur/README.md`.

### CI/CD

- Workflows com todas as actions **pinadas por commit SHA** (supply-chain
  hardening), com o número da versão em comentário. `ci.yml` consolida a
  instalação de `shellcheck`+`bats` e passa a **verificar o standalone**
  construído (`bash -n` + `--list-steps` + `--dry-run`). `release.yml` roda a
  suíte `bats` antes de publicar e expõe a versão da tag para o job do AUR.

### Segurança

- **`--update` agora verifica a integridade do download (C2).** No canal
  `release`, baixa o standalone publicado **e** seu `.sha256`, confere o
  SHA-256 e só instala se bater — binário adulterado/corrompido em trânsito é
  recusado **antes** de qualquer execução, com backup do binário anterior em
  `~/.local/bin/full-upgrade.bak`. Sem `.sha256` na release ou sem
  `sha256sum`/`shasum` disponível, a atualização aborta por segurança. O canal
  `main` mantém o tarball-fonte, agora avisando explicitamente que a
  integridade não é verificada por checksum (somente TLS). Helpers puros novos
  em `lib/core.sh`: `parse_sha256_field`, `file_sha256`, `verify_sha256`
  (cobertos por testes, incluindo cenário de adulteração).

### Adicionado

- **Doctor: saúde do btrfs** (`doctor_btrfs_health`, F3). Em raiz btrfs, soma os
  erros de device acumulados (`btrfs device stats`) e checa a idade do último
  scrub; `RC_TODO` se houver erros > 0 ou o scrub estiver vencido
  (`BTRFS_SCRUB_MAX_DAYS`, default 30) — com remediação. Raiz não-btrfs → skip.
- **Doctor: tempo de boot** (`doctor_boot_time`, F4). Reporta o tempo total de
  boot (`systemd-analyze time`) e as 5 piores units (`blame`); `RC_WARN` acima
  de `BOOT_TIME_WARN_S` (default 60). Sem dados de boot (container) → skip.
- Helpers puros em `lib/core.sh`: `sum_btrfs_dev_errors`,
  `systemd_time_to_seconds` (com testes; suíte 79 → 87).
- **Backup de configs críticas antes das mutações** (`lib/steps/backup.sh`,
  step "Backup de configs críticas", categoria `core`). Arquiva uma lista
  configurável de paths de `/etc` (e dotfiles) em `tar.zst` (fallback `gzip`)
  em `~/.cache/system-upgrade/backups/`, com rotação (`BACKUP_KEEP`). Roda
  antes do snapshot/update. `--dry-run` lista o que arquivaria sem escrever.
  Configurável via `BACKUP_CONFIGS`, `BACKUP_KEEP`, `BACKUP_PATHS`.
- **Pré-flight de espaço para o snapshot** (`SNAPSHOT_MIN_FREE_GIB`, default 2):
  se o livre em `/` estiver abaixo do limiar, o snapshot é pulado com `RC_WARN`
  e remediação, evitando estourar o subvolume. `0` desliga a checagem.
- Helpers puros testáveis em `lib/core.sh`: `space_is_sufficient`,
  `avail_kib_for_path`; e em `lib/steps/backup.sh`: `backup_existing_paths`,
  `backup_rotation_victims`.
- `tests/backup.bats` (6 testes) + testes de `space_is_sufficient` e de
  integridade de catálogo (espaço em borda do nome / join key com `main.sh`).
  Suíte passa de 57 → 70 testes.
- `build.sh` ganhou guarda anti-regressão: falha se algum `lib/steps/*.sh` não
  estiver listado em `ORDER` (evita standalone quebrado em silêncio).

### Corrigido

- **Join key dos steps custom estava quebrado.** As linhas de Hermes, AdGuard
  VPN, OpenClaw, Claude Code CLI e Copilot CLI tinham um espaço inicial no nome
  no catálogo, mas `lib/main.sh` os chama sem o espaço — o mismatch fazia a
  busca de metadata (timeout/`cmd_deps`) cair para o default em silêncio.
  Removido o espaço; teste de integridade agora rejeita espaço em borda.

- **Update AUR não falha mais o run inteiro por pacote isolado quebrado.**
  Quando a transação dos repositórios oficiais aplica com sucesso mas um pacote
  AUR opcional falha o build/download (checksum upstream mudou, PKGBUILD
  travado), `update_system_aur` agora rebaixa o resultado de `fail` (exit 2)
  para `todo` (ação manual), listando os pacotes afetados e a remediação. Falha
  real de transação pacman (conflito, espaço, hook) continua sendo `fail`.
- **Retry do paru agora limpa downloads parciais corrompidos.** A causa do
  `... FALHOU` (checksum) eram arquivos `.part`/fontes baixadas interrompidas
  que a limpeza antiga (só `*.tar.*`) não removia. Novo `_purge_aur_partial_sources`
  apaga `*.part` e formatos de fonte (`*.zip/*.deb/*.AppImage/*.tar.*/...`)
  antes da 2ª tentativa, e o retry só ocorre para erros de rede/integridade
  (não para erro de PKGBUILD/compilação, que não cura com retry).
- **`checkservices` reportava contagem inflada** (ex.: 14 itens para 10
  serviços). O parser confundia `Found: N`, delimitadores `---8<---` e o aviso
  `pacnew file found` com serviços. Agora extrai apenas as units de
  `systemctl restart '<unit>'` (helper puro `parse_checkservices_units`).
- **`cargo audit` dava remediação errada para binários da toolchain.** CVEs em
  `rustup`/`cargo`/`rustc` eram reportadas com "atualize via
  `cargo install-update -a`", que não os toca. Agora classifica cada binário
  (`classify_cargo_bin`) e sugere `rustup self update`/pacman para a toolchain
  e `cargo install-update` só para o que foi instalado via cargo.
- **`_strip_ansi` colapsa barras de progresso (`\r`)**, mantendo só o estado
  final de cada linha — o log deixa de acumular quadros gigantes de
  progresso do `curl`/`wget` gerados pelo paru.
- Filtro de ruído do journal expandido com erros benignos não-acionáveis:
  bugs de firmware/ACPI (`ACPI BIOS Error`, `AE_ALREADY_EXISTS`, `WMI6`),
  drivers (`thinkpad_acpi`, `ftdi_sio` latency, `hci0`), `gkr-pam` (keyring de
  sessão) e o race transitório `Original source was unlinked while parsing
  service file` (flatpak reinstalando `.service` durante o boot scan do dbus).
- `update_pipx` detecta e sinaliza symlinks auto-referentes em `~/.local/bin`
  (ferramenta instalada por `pip --user` **e** `pipx`), com remediação, sem
  falhar o step.
- Removida a definição duplicada de `aur_ignore_args` (vivia em `core.sh` **e**
  `steps/pacman.sh`); fica só em `core.sh`.

### Adicionado

- Helpers puros testáveis em `lib/core.sh`: `parse_checkservices_units`,
  `parse_cargo_vuln_bins`, `classify_cargo_bin` — parsing separado do I/O.
- `tests/core.bats`: +9 testes (parsers acima + colapso de `\r` no
  `_strip_ansi`). Suíte passa de 48 → 57 testes.

### Anterior

- `run_network_cmd`/`_retry`/`log_raw` gravam no log via `log_raw` com guarda de
  `LOG_FILE` vazio, evitando o erro `core.sh: arquivo ou diretório inexistente`
  quando esses helpers são usados antes de `setup_logging` (ex.: durante
  `--update`).

## [3.0.4] — 2026-06-08

### Adicionado

- **Auto-atualização do próprio script** (`lib/steps/self_update.sh`):
  - `full-upgrade --update` / `-u`: baixa a última release do GitHub (tarball da
    tag), extrai e roda o `install.sh`. Pede confirmação, exceto com `-y`.
    Requer apenas `curl` e `tar` — sem depender de `git`/`gh`.
  - `full-upgrade --version` / `-V`: imprime a versão instalada.
  - Step **"Checar atualização do full-upgrade"** no fluxo normal: avisa
    (`todo`) quando há versão nova, sem baixar nada.
  - Configurável via `FULL_UPGRADE_REPO` e `FULL_UPGRADE_UPDATE_CHANNEL`
    (`release` | `main`) no config.
- `tests/self_update.bats`: 12 testes da comparação de versão semver (pura),
  incluindo ordenação numérica (`3.0.10 > 3.0.3`) e normalização de sufixos do
  `git describe`.

### Corrigido

- **Versão exibida como `3.0.0` em instalações.** Como `install.sh` não copia o
  `.git`, `git describe` falhava e a versão caía no fallback embutido. Agora a
  instalação grava um arquivo `VERSION` e o entrypoint resolve a versão na ordem
  `git describe → VERSION → fallback`. `build.sh` também passa a embutir a versão
  sem o prefixo `v`, consistente com o modo modular.
- `log`/`log_always` toleram `LOG_FILE` vazio (chamadas antes de `setup_logging`,
  como em `--update`).

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
