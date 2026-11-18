# Configuração

O full-upgrade funciona sem configuração. Para personalizar, use o TUI ou edite
`~/.config/full-upgrade/config`. Para usar outro arquivo, exporte
`FU_CONFIG_FILE` (ou `FU_CONFIG_DIR`, que também muda onde ficam os
`steps.d/` do usuário) antes de rodar.

## TUI interativo (recomendado)

```bash
full-upgrade --config-tui
```

- TUI em Bash puro, sem dependências: liga e desliga steps do catálogo e edita
  parâmetros (bool, enum, número, caminho) com filtro e popup de detalhe.
- As alterações de **Steps** e **Parâmetros** valem juntas durante a sessão,
  mesmo ao trocar de tela.
- Todo salvamento passa por uma revisão com diff, paginada para terminais
  baixos.
- A gravação consolida chaves duplicadas, preserva comentários e guarda os 5
  configs anteriores em `config.bak.<timestamp>`.
- O TUI grava só no arquivo: skips vindos do ambiente não aparecem nele.

Teclas em `full-upgrade --help tui`.

## Arquivo de config

```bash
mkdir -p ~/.config/full-upgrade
full-upgrade --config-example > ~/.config/full-upgrade/config
$EDITOR ~/.config/full-upgrade/config
full-upgrade --config    # valores efetivos (config + defaults + autodetecção)
```

O arquivo é carregado com `source`: use sintaxe Bash válida. O `--config`
também aponta chaves com cara de erro de digitação e sugere a correta.

## Referência das chaves

### Geral e filtros

| Chave | Default | Descrição |
| --- | --- | --- |
| `FULL_UPGRADE_SKIP` | vazio | Nomes exatos de steps a pular, separados por vírgula. Ambiente e config são unidos. |
| `FULL_UPGRADE_DISABLED_INTEGRATIONS` | vazio | IDs estáveis de integrações desligadas: `openclaw`, `coderabbit`, `artcraft`, `cua-driver`. |
| `ENABLE_CUSTOM_TOOLS` | `0` | Liga Burp/Wireshark (que instalam pacote) e os plugins de `~/.config/full-upgrade/steps.d/`. |
| `AUR_HELPER` | auto | `paru`, `yay` ou `pikaur`; vazio autodetecta nessa ordem. |
| `PRIV_CMD` | auto | `sudo`, `doas`, `run0` ou `sudo-rs`; vazio usa `sudo`. |
| `LANG_OVERRIDE` | `auto` | Reservado (`auto`, `pt`, `en`); a saída é majoritariamente PT-BR. |
| `REPORT_ON_FINISH` | `0` | `1` grava o relatório Markdown do run ao final. |
| `NOTIFY_ON_FINISH` | `0` | `1` envia notificação desktop com o resumo ao final. |
| `GITHUB_TOKEN_FILE` | `~/.config/full-upgrade/github-token` | Token GitHub dedicado (modo `600`). Evita o rate limit de 60 req/h da API anônima. Sem ele, usa `GITHUB_TOKEN`/`GH_TOKEN` ou `gh auth token`. Recomendado: fine-grained, só leitura de repos públicos. |
| `GITHUB_UPDATER_TOKEN_FROM_GH` | `0` | `1` entrega o token do `gh` também aos updaters de terceiros. Prefira o token dedicado. |

### Preflight, snapshots e backup

| Chave | Default | Descrição |
| --- | --- | --- |
| `MIN_FREE_GIB` | `2` | Espaço mínimo livre em `/`. |
| `MIN_BOOT_FREE_MIB` | `200` | Espaço mínimo livre em `/boot`. |
| `SNAPSHOT_TOOL` | `auto` | `auto`, `snapper`, `timeshift` ou `none`. |
| `SNAPSHOT_MIN_FREE_GIB` | `2` | Abaixo disso o snapshot é pulado com aviso; `0` desliga a checagem. |
| `SNAPSHOT_KEEP` | `5` | Snapshots `full-upgrade pré-upgrade` mantidos na limpeza. |
| `BACKUP_CONFIGS` | `1` | Arquiva configs críticas de `/etc` em `tar.zst` antes das mutações. |
| `BACKUP_KEEP` | `5` | Tarballs mantidos (mínimo 1 com o backup ligado). |
| `BACKUP_PATHS` | lista de `/etc` | Caminhos arquivados, separados por espaço. |
| `TIMESHIFT_CLOUD_BACKUP` | `0` | `1` replica o snapshot Timeshift mais recente (`@` + `@home`) num repositório Restic criptografado. |
| `TIMESHIFT_CLOUD_KEEP` | `3` | Versões mantidas no repositório remoto. |
| `TIMESHIFT_CLOUD_REPOSITORY` | `rclone:onedrive:full-upgrade/timeshift` | Repositório Restic (qualquer backend Restic/rclone). |
| `TIMESHIFT_CLOUD_PASSWORD_FILE` | `~/.config/full-upgrade/restic-timeshift-password` | Senha do Restic. Perdê-la torna o backup irrecuperável. |
| `TIMESHIFT_CLOUD_RCLONE_CONFIG` | `~/.config/rclone/rclone.conf` | Config do rclone com o remote. |
| `TIMESHIFT_CLOUD_EXCLUDE_FILE` | `~/.config/full-upgrade/restic-timeshift-excludes` | Padrões Restic para omitir caches e artefatos. |
| `TIMESHIFT_CLOUD_PROGRESS_INTERVAL` | `60` | Segundos entre heartbeats do upload. |

### Pacotes e limpeza

| Chave | Default | Descrição |
| --- | --- | --- |
| `MIRROR_TOOL` | `auto` | `auto`, `reflector`, `rate-mirrors` ou `none`. |
| `MIRROR_MAX_AGE_DAYS` | `7` | Pula o refresh se a mirrorlist for mais nova que isso. |
| `FULL_UPGRADE_AUR_IGNORE` | vazio | Pacotes AUR fora do update automático. |
| `ORPHAN_CLEANUP_MAX_ROUNDS` | `5` | Rodadas de remoção de órfãos; sobrou item, vira `todo`. |
| `COREDUMP_KEEP_DAYS` | `7` | Retenção de dumps em `/var/lib/systemd/coredump`. |
| `CODEX_TMP_KEEP_DAYS` | `1` | Retenção dos temp dirs do Codex em `~/.codex/.tmp`. |
| `DOCKER_INFO_TIMEOUT_S` | `5` | Timeout para detectar daemon Docker inacessível. |
| `DOCKER_PULL_JOBS` | `4` | Pulls simultâneos; `1` volta ao modo em série. |

### Linguagens

| Chave | Default | Descrição |
| --- | --- | --- |
| `FULL_UPGRADE_PIP_USER_IGNORE` | vazio | Pacotes `pip --user` fora do update. `poetry-core` entra sozinho quando o Poetry o fixa. |
| `FULL_UPGRADE_UV_TOOL_HOLD_IGNORE` | vazio | Ferramentas uv fixadas de propósito: o step não acusa que estão atrás do PyPI. |
| `RUST_CVE_REBUILD_TTL_D` | `7` | Dias antes de repetir um rebuild cargo que não corrigiu a CVE. |
| `GCLOUD_BIN`, `COPILOT_BIN`, `MIMO_BIN`, `OPENCLAW_BIN`, `RTK_BIN`, `ORCA_IDE_BIN` | auto | Overrides de binário. |
| `BURPSUITE_JAVA_BIN` | auto | Java do fallback de instalação do Burp. |

### IA, IDE e plugins

| Chave | Default | Descrição |
| --- | --- | --- |
| `AI_PLUGIN_BLOCKLIST` | vazio | Plugins ou marketplaces que os steps do Codex e do Claude Code desinstalam antes de renovar. |
| `CLAUDE_PLUGIN_PREFILTER` | `1` | Só chama `claude plugin update` nos plugins cuja versão mudou no marketplace; `0` chama em todos. |
| `CLAUDE_NATIVE_VERSIONS_DIR` | `~/.local/share/claude/versions` | Versões do instalador nativo do Claude Code (varridas em busca de downloads truncados). |
| `AGENT_SKILLS_TIMEOUT_S` | `60` | Orçamento do `npx skills update --global`; versão lenta do CLI cai para a última boa. |
| `AI_CLI_VERSION_TIMEOUT_S` | `5` | Limite de cada `<cli> --version` no Doctor. |
| `OLLAMA_SELF_UPDATE` | `0` | `1` reexecuta o instalador oficial do Ollama. |
| `MCP_AUTO_UPDATE` | `0` | `1` renova o cache uv dos servidores MCP uvx. |
| `MCP_HUB_RENDER` | `1` | Realinha as configs MCP de todos os harnesses ao hub `mcp/servers.json` do claude-env. |
| `CLAUDE_ENV_DIR` | `~/claude-env` | Repositório claude-env (hub MCP e renderer). |
| `IDE_EXT_CLIS` | auto | CLIs da família VSCode para atualizar extensões. |
| `FULL_UPGRADE_DMS_PLUGINS_IGNORE` | vazio | Plugins DankMaterialShell fixados (globs permitidos): nunca sofrem fetch, pull nem reset. |
| `DMS_PLUGINS_DIR` | `~/.config/dms/plugins` | Diretório dos plugins DankMaterialShell. |
| `ARTCRAFT_DIR` | `~/development/artcraft` | Inventário da suíte Artcraft. |

### Doctor

| Chave | Default | Descrição |
| --- | --- | --- |
| `BTRFS_SCRUB_MAX_DAYS` | `30` | Alerta se o último scrub de `/` for mais antigo. |
| `BTRFS_DEVICE_STATS_ACK_SHA256` | vazio | Reconhece o estado exato de UUID e contadores por device; qualquer mudança volta a alertar. |
| `BOOT_TIME_WARN_S` | `60` | Alerta se o boot exceder N segundos. |
| `FWUPD_HSI_MIN` | `2` | Avisa se o nível HSI ficar abaixo. `1` ou `0` silencia máquina já avaliada. |
| `STALE_SERVICES_IGNORE` | vazio | Units (globs) fora da auditoria de libs antigas e do `--restart-services`. |
| `COREDUMP_IGNORE_EXE` | vazio | Executáveis (globs) cujos crashes recorrentes são esperados. |

### Auto-remediação (opt-in)

| Chave | Default | Descrição |
| --- | --- | --- |
| `AUTO_FIX_RUST_CVES` | `0` | `1` remedia CVEs de toolchain Rust. |
| `AUTO_BTRFS_SCRUB` | `0` | `1` inicia o scrub quando vencido. |
| `AUTO_MERGE_PACNEW` | `0` | `1` mescla os `.pacnew` cujo merge preserva exatamente a config ativa (com backup). `sudoers`, `passwd`, `shadow`, `group`, `gshadow`, `fstab` e `crypttab` nunca entram. |
| `AUTO_FIX_PIP_DEPS` | `0` | `1` instala dependências **ausentes** apontadas pelo `pip check`. |
| `AUTO_RECREATE_STALE_CONTAINERS` | `0` | `1` recria serviços Compose que seguem com imagem antiga (volumes preservados). |

### Rede

| Chave | Default | Descrição |
| --- | --- | --- |
| `NETWORK_GATE` | `1` | Espera a conectividade antes dos steps com tag `network`. |
| `NETWORK_GATE_HOST` | `archlinux.org` | Host usado na sonda de DNS. |
| `NETWORK_GATE_PROBE_TIMEOUT_S` | `2` | Limite de cada sonda de conectividade. |
| `NETWORK_GATE_WAIT_S` | `20` | Espera máxima pela volta da rede antes de fechar o step como `warn`. |

### Systray

| Chave | Default | Descrição |
| --- | --- | --- |
| `TRAY_CHECK_INTERVAL_M` | `30` | Minutos entre checagens (mínimo efetivo: 1). |
| `TRAY_TERMINAL` | auto | Terminal usado pelas ações do menu. |
| `TRAY_NOTIFICATIONS` | `1` | `0` só troca o ícone, sem notificar. |
| `TRAY_BADGE` | `1` | `0` esconde o contador ao lado do ícone. |
| `TRAY_ICON_COLOR` | `auto` | Cor dos ícones: `auto` (texto do tema GTK) ou `#rrggbb`. |

### Atualização do full-upgrade

| Chave | Default | Descrição |
| --- | --- | --- |
| `FULL_UPGRADE_REPO` | `bernardopg/full-upgrade` | Origem das releases. |
| `FULL_UPGRADE_UPDATE_CHANNEL` | `release` | `release` ou `main`. |
