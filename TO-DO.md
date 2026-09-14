# TO-DO — Roadmap full-upgrade

Roadmap vivo de **correções, melhorias e ampliações** derivadas de runs reais.
Este arquivo mantém apenas o backlog acionável atual; itens concluídos antigos
foram removidos daqui e ficam rastreáveis pelo `CHANGELOG.md`, tags e PRs.

Base deste ciclo:

- Ciclo aberto sobre a v3.42.0, a partir de um run real de manutenção
  (`full-upgrade -y -d`) usado como amostra de comportamento em produção.
- Resultado do run de referência: praticamente todo verde, com 1 aviso e
  nenhum `todo`/`fail`.
- Único aviso: `Atualizar pi (pi-coding-agent)` — `pi update --extensions`
  falhou com npm `EALLOWREMOTE` (fetch de URL remota desabilitado por
  política local; o pacote upstream `pi-mcp-adapter` aponta uma dependência
  para `pkg.pr.new`). Causa upstream, não acionável no full-upgrade.
- Série O (run 2026-07-01): mesclada na `main` via PR #107.
- Revisão estrutural de steps/categorias (2026-09-14): originou as Séries S e T.

Convenções obrigatórias em todos os itens:

- Steps retornam via RC contract (`0`, `RC_WARN`, `RC_TODO`, fail); nunca `exit` dentro de step.
- Mudanças validam com `bash -n`, `shellcheck -S warning -x`, `bats tests/`, smoke flags, `--dry-run` e build quando estrutural.
- Comentários e strings de usuário ficam em PT-BR.
- Nome de step é byte-idêntico entre catálogo, `main.sh`, relatório e argumentos `--skip`/`--explain-step`.
- Categoria de step é chave de agrupamento (`summary_group_specs` em `ui.sh`) e de filtro (`--only`/`--skip-category`); mudança de categoria exige atualizar grupos, rótulos e testes de catálogo.
- Preferir a menor mudança correta; sem backward compatibility nova sem necessidade concreta.
- Achado não acionável localmente não deve virar `warn`/`todo` recorrente.

Legenda de prioridade: 🔴 alta · 🟡 média · 🟢 baixa · 🟠 grande impacto/esforço.
Status: ☐ pendente · ◐ em andamento · ☑ concluído.
Esforço: P/M/G.

Próximas 3 prioridades definidas em 2026-09-14: **(1)** Série S completa
(S1+S2+S3: categorias coerentes + guard-rails + higiene de tags, numa onda
só — os testes novos falham sem a reclassificação) — ☑ CONCLUÍDA (suíte
completa verde), **(2)** T1 (split do doctor.sh) — ☑ CONCLUÍDA (6 módulos, 65 funções)
e **(3)** T2+T3 (preflight.sh e extrações) — ☑ CONCLUÍDA (suíte completa
verdes). Restam T4/T5 (documentação de regra e guard-rail opcional).

---

## Série S — Coerência do catálogo de steps (revisão estrutural 2026-09-14)

Objetivo: alinhar categoria ↔ semântica ↔ arquivo de implementação, tornar o
modo `doctor` read-only de fato (hoje a promessa só é cumprida por um filtro
em runtime, `add_skip_mutating_steps`) e blindar a taxonomia com guard-rails
de teste. Critério geral: **nomes de step não mudam** (chave de junção
byte-idêntica com `main.sh`, config e relatórios); identidades antigas de
categoria sobrevivem como **tags** para compat de `--only`/`--skip-category`.

### S1 — 🔴 M ☑ Reclassificar categorias para a taxonomia alvo

Mudanças de categoria (19 categorias finais, todas com ≥ 2 steps):

- `Backup Timeshift em nuvem`: `cleanup` → `backup` (era o único step de
  backup fora de lugar; `--skip-category cleanup` desligava um backup).
- `Backup de configs críticas` e `Snapshot pré-upgrade`: `pacman` → `backup`.
- `Garantir Wireshark` e `Garantir Burp Suite`: `repair` → `security`
  (instalam pacotes, não reparam); os `Reparar *` de Wireshark/Burp ficam em
  `repair` (reparos genuínos).
- `Garantir Orca IDE`, `Garantir Antigravity`: `ai` → `ide` (IDEs desktop AUR).
- `Verificar arquivos .pacnew/.pacsave`: `final` → `packages` (higiene de
  config do pacman; doctor tem o próprio check).
- Doman AI vs `manual` arbitrário — CLIs standalone self-updating idênticos
  em categorias diferentes (`grok` era `manual`, `kimi` era `ai`). Migrar de
  `manual` para `ai`: Factory droid, CodeRabbit, Kiro CLI, grok, jcode,
  qodercli, qoderwake, kimchi. `manual` deixa de existir como categoria.
- `Atualizar Snyk CLI` e `Atualizar OWASP ZAP`: `manual` → `security`.
- `Atualizar GitKraken CLI (gk)`, `Atualizar cua-driver`,
  `Atualizar OBS (plugins e extensões)`: `manual` → `tools`.
- `lang` divide-se em `lang-js` (8: npm×3, corepack, pnpm×2, Bun, Deno),
  `lang-py` (6: pip, pipx, uv×3, Poetry), `lang-rust` (3: rustup, cargo bins,
  cargo audit) e `lang-other` (6: Arduino, Go, .NET, gcloud, gems, ghcup).
  Tag `lang` permanece em todos para `--only lang` continuar funcionando.
- `flatpak`/`snap`/`docker` (1 step cada) fundem-se em `packages` junto com o
  núcleo pacman (system/AUR, mirrors, news, pacnew). Tags `flatpak`/`snap`/
  `docker`/`pacman` preservadas para compat de filtros.
- Eixo `autofix` (novo, 5 steps): `Auto-remediar CVEs de toolchain Rust`
  (era `lang`), `Auto-remediar pendências finais` (era `final`),
  `Auto-remediar deps Python ausentes`, `Auto-remediar scrub btrfs` e
  `Reiniciar serviços com libs antigas` (eram `doctor`).
- `doctor` fica read-only (27 steps); invariante passa a ser testada, não
  depende de filtro em runtime.
- `shell` absorve `hyprland` (hyprpm) e `reference` (tldr), que eram
  singletons; `editor` fica com nvim (Lazy/Mason); extensões VSCode/Cursor
  vão para `ide`.

Arquivos a tocar: `lib/catalog.sh` (heredoc), `lib/ui.sh`
(`summary_group_specs` + `_category_label`), `tests/catalog.bats`,
`tests/ui_summary.bats`, `tests/manual_apps.bats`, README/help se citarem
categoria removida. Validação: `bash -n`, `shellcheck -S warning -x`, bats de
catálogo/ui/report/manual_apps, `--list-steps`, `--dry-run -n`.

### S2 — 🔴 P ☑ Guard-rails de integridade semântica em `tests/catalog_integrity.bats`

Hoje os testes cobrem o join (nome↔função↔main.sh) mas nada valida coerência
de categoria. Adicionar:

1. Categoria ∈ conjunto fechado de 19 categorias (impede categoria nova por
   digitação).
2. `categoria != doctor` quando `efeito == mutating` (doctor é read-only).
3. Tags não contêm `mutating`/`read` (redundantes com o campo efeito).
4. Toda categoria tem ≥ 2 steps (mata singletons).
5. Tag usada em exatamente 1 step precisa estar na allowlist explícita do
   teste (vocabulário controlado; aceita nomes de ferramenta documentados).
6. Steps `core`/`final` mantêm invariantes existentes (já cobertos) — apenas
   conferir que os novos testes reusam o mesmo parser do heredoc.

### S3 — 🟡 P ☑ Higiene de tags: remover `mutating`/`read` redundantes

- 23 de 93 steps mutantes tinham tag `mutating`; 70 não tinham. 34 de 36
  steps read tinham tag `read`. Remover as tags duplicadas (o campo `efeito`
  é canônico e já testado); `add_skip_mutating_steps` usa o campo, não a tag.
- Eixos de tag legítimos que permanecem: `network`, `slow`, `sudo`,
  `security`, `desktop`, `snapshot`, `cve`, `config`, `read-only`-related
  removidos; nomes de ferramenta viram allowlist no teste S2.5.

### S4 — 🟢 P ☐ Documentar a taxonomia no README/help

- Tabela de categorias com semântica (o que `--only X` pega) em `README.md`
  e tópico `--help steps`.

---

## Série T — Reorganização física dos arquivos de steps

Objetivo: acabar com o monolito e com nomes enganosos; uma regra única de
co-localização. Executar DEPOIS da Série S (categorias estáveis primeiro).

### T1 — 🟠 G ☑ Dividir `lib/steps/doctor.sh` (2.589 linhas, 30 steps) em `lib/steps/doctor/`

- Proposta: `doctor/system.sh` (reboot, units, journal, coredump, sessão
  desktop), `doctor/storage.sh` (disk, SMART/NVMe, btrfs, TRIM),
  `doctor/boot.sh` (boot health/tempo, fwupd security), `doctor/packages.sh`
  (pacman health, pacfiles, hooks ALPM, arch-audit, paru Devel, flatpak
  repair), `doctor/dev.sh` (AI CLIs, ambiente Python, conflitos JS, gems,
  MCP, apps manuais).
- Helpers puros já extraídos em `lib/testable/doctor_pure.sh` não se movem;
  atualizar `load_libs` dos testes e a lista de `source` do entrypoint.
- Testes existentes (`doctor*.bats`, ~600 asserts) devem passar sem mudança
  de comportamento; só caminhos de load mudam.

### T2 — 🟡 P ☑ Renomear `lib/steps/coverage.sh` → `lib/steps/preflight.sh`

- O arquivo implementa lock/sudo/disco/keyring/snapshot/mirrors — nada a ver
  com cobertura. Renomear arquivo, atualizar `full-upgrade.sh` (source),
  `build.sh` (se listar arquivos), `load_libs` dos testes e comentários que
  citam o caminho.

### T3 — 🟡 M ☑ Extrair responsabilidades fora de lugar

- Verificações finais (`final_check_pending`, `final_check_managers`,
  `autofix_final_pending`) saem de `lib/steps/cleanup.sh` →
  `lib/steps/final_checks.sh`.
- `lib/steps/pacman.sh` perde `cleanup_paccache`/`cleanup_orphans` (vão para
  `cleanup.sh`) e ganha foco em update/reparo do pacman.
- `lib/steps/editor_shell.sh` (3 categorias) divide-se em `shell.sh` (omz,
  dms, yazi, hyprpm, tldr) e `editor.sh` (nvim).
- `lib/steps/containers.sh` renomeia para `packages.sh` (flatpak/snap/docker
  + futuros empacotadores) — hoje “containers” só descreve docker.
- `lib/steps/self_update.sh` mantém notices/update; os `repair_full_upgrade_*`
  migram para `repair.sh` (ou ficam, documentando a exceção).

### T4 — 🟢 M ☐ Regra única de co-localização de `doctor_*`

- Hoje 4 checks de doctor vivem fora do monolito (`doctor_gem_shadow` em
  `lang_other.sh`, `doctor_manual_apps` em `manual_apps.sh`,
  `doctor_mcp_servers` em `mcp.sh`, `doctor_obs_modules` em
  `steps.d/85-obs.sh`). Definir: cada `doctor_*` vive no arquivo do seu
  domínio; o split T1 absorve os que ficarem.

### T5 — 🟢 P ☐ `catalog.sh` declara `func_name` → teste de caminho

- Guard-rail opcional: função de step da categoria X vive no arquivo/dir
  esperado de X (evita regressão da co-localização).

---

## Série R — Experiência de configuração: TUI, healthcheck e help de padrão indústria

Objetivo: transformar a superfície de entrada do full-upgrade em três peças de
qualidade de produto — (1) um TUI interativo para gerenciar config (steps e
parâmetros), (2) um comando `--healthcheck` que inventaria o setup da máquina,
(3) um sistema de ajuda (`--help` + tópicos) no padrão de software de ponta.
Zero dependências externas novas: TUI em bash puro (ANSI + raw mode),
healthcheck só com ferramentas que já existem na máquina (degrada com elegância
quando algo falta).

Ordem de implementação: R1 (help é a documentação dos outros dois) → R3
(healthcheck) → R2 (TUI, o maior) → R4 (integração + testes).

### R1 — 🔴 M ☑ Help de padrão indústria (`--help` + tópicos)

- Reescrever `usage()` em `lib/cli.sh` com estrutura de seções: SINOPSE,
  MODOS DE EXECUÇÃO, AÇÕES, FILTROS DE STEPS, SAÍDA E FORMATO, TRAY, STATUS,
  AMBIENTE — colunas alinhadas com quebra de descrição em hanging indent
  (reaproveita `ui_wrap_hang`).
- Cores TTY-aware (respeita `NO_COLOR`): flags em ciano, seções em bold;
  pipe-friendly quando stdout não é TTY.
- `--help [TÓPICO]`: tópicos `modes`, `steps`, `config`, `healthcheck`, `tui`,
  `tray`, `env`. Tópico desconhecido lista os válidos e sai com 2.
- Compatibilidade: asserts existentes de `tests/cli.bats` sobre `usage()`
  continuam passando (mesmo vocabulário, layout melhor).

### R2 — 🔴 G ☑ TUI interativo de config (`--config-tui`)

Novo módulo `lib/tui.sh`, bash puro (alt screen + raw mode via `stty`), sem
`fzf`/`dialog`/`whiptail`.

**Arquitetura (helper reutilizável):**

- `tui_open`/`tui_close` — entra/sai de alt screen (`\033[?1049h`), esconde
  cursor, raw mode; `trap` garante restauração mesmo com Ctrl-C.
- `tui_read_key` — decodifica sequências: ↑↓←→, PgUp/PgDn, Home/End, Space,
  Enter, Esc, Backspace, letras/dígitos; timeout curto no ESC órfão.
- `tui_draw` — frame completo por tecla: barra de título com abas e contador de
  mudanças pendentes, janela de itens com scroll, barra de rodapé com hints;
  limpeza por linha (`\033[K`) sem flicker de clear total.
- Filtro vivo com `/` (digita e filtra no mesmo loop; Backspace corrige; Esc
  sai do filtro).
- Popup de detalhe com `d` (descrição/categoria/efeito do step; tipo/opções do
  parâmetro).

**Tela 1 — Steps:** catálogo via `step_catalog`, agrupado visualmente por
categoria; estado por step = `run`/`skip` derivado do valor de `FULL_UPGRADE_SKIP`
**do arquivo de config** (não do valor mesclado com ambiente — o TUI edita o
arquivo, nunca o ambiente); Space/t alterna; indicador de efeito
(read/mutating) colorido.

**Tela 2 — Parâmetros:** catálogo de chaves editáveis com metadados
(`key|tipo|opções|descrição`) — bools (Space alterna), enums (←→ cicla:
LANG_OVERRIDE, SNAPSHOT_TOOL, MIRROR_TOOL, canais...), ints e strings/path/list
(Enter abre prompt inline em modo cooked, validação numérica com rechamada).
Valor efetivo atual mostrado ao lado; valor alterado marca com `*`.

**Salvar (tecla `s` global):** tela de revisão com diff `chave: antigo → novo`
(pendentes apenas); confirmação; gravação segura em `~/.config/full-upgrade/config`:

- backup automático `config.bak.<timestamp>` antes de reescrever;
- upsert linha a linha (substitui `KEY=` existente no lugar, preservando
  comentários do usuário; chave nova vai para seção gerenciada no fim);
- `FULL_UPGRADE_SKIP` serializado como CSV com nomes byte-idênticos do catálogo;
- valores com aspas/`$` escapados corretamente (double-quote com `\`); nomes
  sempre de chaves do `config_known_keys`;
- valida `bash -n` do arquivo novo em temp antes do `mv` atômico;
- sai 0; sair com mudanças sem salvar pede confirmação.

**Guardas:** sem TTY (`[[ -t 0 && -t 1 ]]`) → erro claro no stderr sugerindo
`--config`/`--config-example` e exit 2; terminal mínimo (20 cols × 10 rows);
`NO_COLOR`/`NO_UNICODE` respeitados via cores/símbolos de `lib/ui.sh`.

### R3 — 🔴 M ☑ Healthcheck do setup (`--healthcheck`)

Novo módulo `lib/healthcheck.sh`, 100% read-only, sem sudo obrigatório (tenta
`$PRIV_CMD -n` só onde precisa, degrada para "requer root"). Cada coletor é
função pura testável; seção falível nunca derruba o relatório.

Seções (nesta ordem):

1. **Sistema** — distro (`/etc/os-release`), kernel em execução (`uname -r`),
   pacote kernel instalado + flag de reboot pendente, uptime, arquitetura.
2. **Desktop e sessão** — DE/WM (env + varredura de processos), tipo de sessão
   (wayland/x11/tty), TTY ativo (`XDG_VTNR` / `/sys/class/tty/tty0/active`),
   terminal em uso (env `TERM_PROGRAM`/`KITTY_*` + subida da cadeia de pais em
   `/proc/*/comm` contra lista conhecida), DankMaterialShell: se quickshell/DMS
   presente, lista plugins de `DMS_PLUGINS_DIR` com estado git.
3. **Specs** — CPU (modelo, núcleos), RAM/swap (`/proc/meminfo`), GPU
   (`lspci` VGA/3D, fallback `nvidia-smi`), disco raiz (tamanho, livre, fstype).
4. **Gerenciadores de pacotes** — pacman, AUR helpers (paru/yay/pikaur),
   flatpak, snap, npm/pnpm/bun/deno, pip/uv/pipx/poetry, cargo/rustup, gem,
   go, dotnet, ghcup, arduino-cli — caminho resolvido (`command -v`) + versão
   (com `timeout` de guarda; versão lenta/ruim não trava).
5. **Ferramentas do full-upgrade** — timeshift, snapper, restic, rclone, borg,
   btrfs, smartctl, nvme, fwupdmgr, bootctl, reflector, rate-mirrors,
   arch-audit, cargo-audit, yad, notify-send, needrestart/checkservices,
   fastfetch/neofetch — presente/ausente + caminho.
6. **Timeshift** — se presente: nº de snapshots (parser da saída de
   `timeshift --list`, tentativa sem sudo e depois `sudo -n`), nome do mais
   recente, destino; indisponível sem root diz exatamente isso.
7. **Backup em nuvem** — primeiro a config do full-upgrade
   (`TIMESHIFT_CLOUD_BACKUP=1` + restic/rclone + repositório = EM USO);
   depois detecção genérica de ferramentas de backup instaladas (restic,
   borg, kopia, deja-dup, pika-backup, vorta, syncthing, rclone remotes).
8. **Fetch** — saída de `fastfetch` se presente, senão `neofetch`; nenhum →
   mini-fetch sintetizado com os dados já coletados.
9. **Resumo final** — caixa com os fatos-chave (distro, kernel+reboot, DE,
   terminal, TTY, CPU/RAM, disco, nº de gerenciadores, nº de tools, snapshots
   timeshift, backup em nuvem) e veredito do setup (críticos presentes?).

**Flags:** `--healthcheck` sai antes do fluxo normal (exit 0);
`--healthcheck --json` emite objeto único estruturado (validado no teste com
`assert_json`); exclusão mútua com `--audit`/`--report`/`--history`/
`--config-tui`.

### R4 — 🟡 M ☑ Integração, testes e docs

- `lib/globals.sh`: flags novas (`DO_HEALTHCHECK`, `DO_CONFIG_TUI`,
  `HELP_TOPIC`) com defaults.
- `lib/cli.sh`: parse das flags novas, validação de exclusão mútua, early
  exits em `apply_mode_and_early_exits` (antes de `--audit`); help dos tópicos
  novos.
- `full-upgrade.sh` e `build.sh` (ORDER): carregar `lib/healthcheck.sh` e
  `lib/tui.sh`.
- Testes: `tests/help.bats` (seções, tópicos, exit 2 em tópico inválido),
  `tests/healthcheck.bats` (coletores puros com fixtures, parser de
  `timeshift --list`, JSON válido, resumo contém campos, funciona sem TTY),
  `tests/tui.bats` (writer/upsert/backup/escape de aspas, serialização de
  skip CSV, catálogo de parâmetros com chaves conhecidas, recusa sem TTY,
  validação numérica).
- `CHANGELOG.md` (Unreleased) + seção do README para os três comandos.

**Concluído (2026-09-07):** os 4 itens implementados e testados — 1356 testes
bats verdes (77 novos: help, healthcheck, tui), `bash -n` + `shellcheck -S
warning -x` limpos em todos os módulos tocados, standalone buildado e
verificado. Aprendizados registrados: (1) `config.sh` redefine
`FU_CONFIG_DIR/FU_CONFIG_FILE` no source — testes devem apontar o config de
teste DEPOIS do source; (2) o save do TUI nasce o work file de uma CÓPIA do
config atual (um work vazio substituiria o arquivo inteiro — pego no teste
antes de qualquer dano em config real; backup automático permitiu auditoria);
(3) `uname -r` com sabor (`-lts`) nunca casa com a versão do pacote sem
normalização de pontos/traços.

---

## Série Q — Ampliações pós-v3.20.0

Objetivo: fechar lacunas clássicas de manutenção Arch que nenhum step cobria.

### Q1 — 🔴 M ☑ Checar notícias do Arch Linux antes do upgrade

Prática nº 1 pré-`pacman -Syu`: news de intervenção manual avisam de passos
que um update às cegas quebraria. Novo step read/network "Checar notícias do
Arch Linux" (`lib/steps/news.sh`) antes de "Atualizar mirrors": parser RSS puro
(awk, sem xmllint), estado em `~/.cache/system-upgrade/arch-news-last-seen`,
título com `manual intervention|action required|breaking change|...` => `todo`
com link; demais novidades = informativas; rede fora = warn. Testes em
`tests/news.bats` (validado contra o feed real).

### Backlog Q — próximos itens

#### Q2 — 🟡 M ☑ Doctor journal: erros do journal de usuário (verificado: já coberto)

Verificado em 2026-07-02: `journalctl -p 3 -b` sem `--su` roda como usuário
(grupo `wheel`) e já mescla o journal da sessão (`user-1000.journal`) — as
assinaturas de apps de sessão (ZapZap, antigravity-ide) aparecem no scan
padrão do doctor. Passada `--user` separada duplicaria linhas. Nada a fazer.

#### Q3 — 🟢 P ☑ Notícias: fonte informativa no relatório .md

Implementado (PR a seguir): o step `Checar notícias do Arch Linux` agora grava
os itens novos em `full-upgrade-<run_id>.news` e um evento `news` no JSONL;
o relatório Markdown (`REPORT_ON_FINISH` / `--report`) ganhou a seção
"## Notícias do Arch" com data, tipo (intervenção/informativa) e título clicável.

#### Q4 — 🟢 P ☐ Acompanhar upstream ZapZap (ex-P10)

rafatosta/zapzap#767; remover patch local do launcher quando corrigido.

---

## Série P — Resiliência de rede e auto-remediação (Run 2026-07-02)

Objetivo: nenhum soluço transitório de rede pode derrubar o run ou bloquear os
repos oficiais; pendências detectáveis no fim do run se resolvem sozinhas
quando o usuário optar por isso.

Status do ciclo: P1–P9 implementados na branch `fix/network-transient-resilience` (v3.20.0).

### P1 — 🔴 P ☑ Regex central de rede transitória + erro reqwest do paru

`NETWORK_TRANSIENT_RE` em `lib/globals.sh` como fonte única para
`run_network_cmd`/`_retry`/retry AUR; cobre `error sending request`/`channel
closed` (reqwest do paru contra `https://aur.archlinux.org/rpc`), causa do fail
do run-base. Regressão em `tests/core.bats`.

### P2 — 🔴 M ☑ Retry + fallback pacman no step de sistema/AUR

`update_system_aur`: 3 tentativas com backoff; AUR persistindo fora →
`pacman -Syu` aplica os repos oficiais e o step vira `warn` com motivo.

### P3 — 🔴 M ☑ Auto-remediação de pendências finais

Novo step mutating "Auto-remediar pendências finais" (`AUTO_FIX_FINAL_PENDING`,
default 0): aplica `pacman -Syu` (+ retry `paru -Sua`/`yay -Sua`) para
pendências acionáveis. Roda ANTES da "Verificação final de pendências" para o
resumo não registrar `todo` obsoleto após remediação bem-sucedida.

### P4 — 🟡 P ☑ Contrato RC em Oh My Zsh / plugins Zsh / plugins DMS

GitHub inacessível virava `fail` nesses 3 steps (run 2026-07-01 23:34); agora
falha de rede classifica como `RC_WARN`.

### P5 — 🟡 M ☑ Monorepos do registry DMS

Plugins instalados via `dms plugins install` (symlinks para
`plugins/.repos/<hash>/`) nunca eram atualizados; o step agora faz fetch+pull
ff-only dos monorepos e reporta os plugins como gerenciados via registry.

### P6 — 🟡 M ☑ Steps OBS (update de plugins user-scope + doctor de módulos)

`steps.d/85-obs.sh`: "Atualizar OBS (plugins e extensões)" e "Doctor: módulos
OBS" (log da última sessão → módulo com load falho = `todo`; crash recente =
`warn`). Testes em `tests/obs.bats`.

### Backlog P — próximos itens

#### P7 — 🟡 P ☑ Paridade de retry/fallback para yay/pikaur no update principal

`update_system_aur` só tem retry+fallback no caminho paru; os caminhos
yay/pikaur ainda são `run_logged` direto. Extrair o loop para helper e reusar.
Arquivos: `lib/steps/pacman.sh`, `tests/pacman_pure.bats`.

#### P8 — 🟡 M ☑ Doctor journal: classificar coredumps com hint de coredumpctl

Coredumps recorrentes (ex.: `antigravity-ide` NodeService) aparecem como
assinatura crua. Adicionar hint com `coredumpctl info <pid>` e classificação
`app-crash` (warn com hint apontando o app, não o sistema).
Arquivos: `lib/steps/doctor.sh`, `tests/doctor*.bats`.

#### P9 — 🟢 P ☑ Doctor módulos OBS: suporte a OBS Flatpak

`_obs_install_kind` já detecta Flatpak, mas `OBS_CONFIG_DIR` default só cobre o
nativo; Flatpak usa `~/.var/app/com.obsproject.Studio/config/obs-studio`.
Arquivos: `steps.d/85-obs.sh`, `tests/obs.bats`.

#### P10 — 🟢 P ☐ ZapZap upstream

Bug reportado em rafatosta/zapzap#767 (ThemeContext + spam de console.error);
mitigação local no launcher. Quando o upstream corrigir, remover o patch de
`~/.local/share/zapzap-patch/launch.py`.

---

## Série O — Achados do Run 2026-07-01

Objetivo: reduzir ruído recorrente, alinhar severidade entre `--audit` e run
normal, e transformar sinais informativos em recomendações claras sem mascarar
falhas reais.

Status do ciclo: O1–O7 implementados nesta branch; manter os detalhes abaixo como
registro de escopo/aceite até o PR ser mesclado.

### O1 — 🔴 P ☑ Alinhar `--audit` com CVEs Rust não acionáveis

**Problema:** o run normal já classifica CVEs restritas ao `rustup` atualizado
como informativas, mas `--audit` ainda mostra o mesmo caso como `[ALTA] CVEs em
binários cargo` com remediação genérica.

**Evidência:**

- `Auditar binários cargo (CVEs)` retorna `ok` quando só `rustup` está afetado e
  `rustup check` indica última versão.
- `Auto-remediar CVEs de toolchain Rust` também retorna `ok` após confirmar que o
  remanescente vive em crates vendorizadas upstream.
- `./full-upgrade.sh --audit` ainda reporta `1 alta` por `rustup`.

**Arquivos:**

- `lib/steps/audit.sh`
- `lib/steps/lang_rust.sh` se for necessário extrair helper reutilizável
- `tests/` (`audit`/`lang_rust` conforme padrão existente)

**O quê:**

- Atualizar `_audit_probe_cargo` para separar binários `toolchain` de binários
  `cargo-installed`, usando a mesma classificação de `audit_cargo_bins`.
- Quando todos os binários vulneráveis forem `rustup`/toolchain e `rustup` já
  estiver atualizado, registrar achado `info`, não `high`.
- Manter `high` para binários `cargo-installed` com CVE e para toolchain quando
  houver update disponível.
- Ajustar a remediação exibida para refletir origem: `cargo install-update -a`
  só para bins instalados via cargo; `rustup self update && rustup update` só
  para toolchain acionável.

**Critério de aceite:**

- Caso `rustup` atualizado com CVE vendorizada aparece como `INFO` ou nota
  informativa em `--audit`.
- CVE em binário cargo-installed continua `ALTA`.
- Falha de rede no cargo-audit continua informativa/não fatal.
- Bats cobre pelo menos: só toolchain irreparável, cargo-installed acionável,
  mistura toolchain + cargo-installed.

---

### O2 — 🔴 M ☑ Melhorar classificação do `Doctor: journal erros críticos`

**Problema:** o único warn do run foi o journal. As assinaturas remanescentes são
majoritariamente ruído de sessão gráfica/app e Bluetooth/PipeWire, mas ainda
entram como `RC_WARN` genérico.

**Evidência do run:**

- `7x` `Uncaught (in promise) DisconnectedError`.
- `5x` `[ZapZap WAWeb Theme Controller] Unable to find WhatsApp Web ThemeContext`.
- `2x` `Uncaught (in promise) CustomError: fh`.
- `1x` `Uncaught (in promise) cancel`.
- `1x` PipeWire/BlueZ `pw.node ... running -> error`.
- `2x` Bluetooth AVDTP (`No reply to Start request`, `Connection refused`).
- `1x` `ftdi_sio ttyUSB0: error from flowcontrol urb`.

**Arquivos:**

- `lib/steps/doctor.sh`
- `tests/doctor*.bats` ou arquivo novo focado em journal helpers

**O quê:**

- Preservar melhor a origem antes de agrupar mensagens: unit, comm/syslog
  identifier ou prefixo bruto suficiente para diferenciar app, kernel, bluetooth,
  pipewire e serviço.
- Expandir `journal_hint_for` para padrões conhecidos:
  - ZapZap/WhatsApp Web ThemeContext.
  - Promise errors genéricos de Electron/Chromium quando sem unit crítica.
  - PipeWire/BlueZ output node em erro transitório.
  - Bluetooth AVDTP connect/start sem resposta.
  - `ftdi_sio ttyUSB0` flowcontrol URB.
- Adicionar classificação pura para assinatura: `noise`, `known-benign`,
  `actionable`, `unknown`.
- Se todas as assinaturas pós-filtro forem conhecidas benignas, retornar `0` com
  nota informativa e lista no log.
- Manter `RC_WARN` quando houver assinatura desconhecida, erro de serviço crítico,
  I/O/storage, kernel panic/oops, falha de autenticação relevante ou systemd unit
  problemática.

**Critério de aceite:**

- O conjunto do run de 2026-07-01 deixa de gerar `warn` se composto apenas pelos
  padrões benignos acima.
- Erro desconhecido ainda gera `warn`.
- Hints aparecem no terminal para padrões conhecidos.
- Últimas linhas brutas continuam gravadas no log para auditoria.
- Helpers de classificação são cobertos por Bats sem depender de journal real.

---

### O3 — 🟡 M ☑ Separar apps manuais reais de backups/remanescentes

**Problema:** `Doctor: apps manuais` detectou 25 itens fora de gerenciador, com
12 “sem step”. Parte da lista são backups, binários auxiliares ou remanescentes
que não deveriam ser tratados como candidatos de update.

**Evidência do run:**

- Backups/remanescentes: `dumpcap.manual.*`, `wireshark.manual.*`,
  `antigravity.manual-backup-*`, `nomacs-original`.
- Apps/candidatos reais sem step: `codexbar`, `kimchi`, `purple`, `idea-*`,
  `resolve`, `vscode-*`, `sharkd`, `tshark`.

**Arquivos:**

- `lib/steps/manual_apps.sh`
- `tests/manual_apps.bats` ou equivalente
- Opcional: `lib/config.sh` para lista de ignore configurável

**O quê:**

- Classificar inventário em categorias:
  - `coberto` por step.
  - `sem step` candidato real.
  - `backup/remanescente`.
  - `auxiliar`/binário de pacote manual conhecido.
  - `ignorado por config`.
- Ignorar ou rebaixar padrões como `*.manual.*`, `*.manual-backup-*`,
  `*-original`, diretórios versionados antigos quando houver symlink/instalação
  atual equivalente.
- Adicionar recomendação segura para limpeza manual de backups antigos, sem
  remover automaticamente.
- Adicionar configuração opcional para allowlist/ignore local de nomes conhecidos.

**Critério de aceite:**

- Backups/remanescentes não inflam a contagem de “sem step”.
- Lista de candidatos reais continua visível.
- Nenhum binário desconhecido é executado durante o doctor.
- Bats cobre classificação por nome/path.

---

### O4 — 🟡 M ☑ Doctor informativo para pacotes AUR marcados out-of-date

**Problema:** durante o update, o AUR reportou pacotes marcados como
desatualizados, mas isso aparece apenas no log bruto e não vira diagnóstico
estruturado.

**Evidência do run:**

- `apple-fonts`
- `github-desktop`
- `nomacs`
- `quickshell-git`
- `whitesur-gtk-theme`

**Arquivos:**

- `lib/steps/pacman.sh`
- `lib/catalog.sh`
- `lib/main.sh`
- `tests/pacman*.bats`

**O quê:**

- Adicionar helper puro para extrair `marcado como desatualizado` da saída de
  `paru`/`yay`.
- Persistir a lista em arquivo temporário do run ou `STEP_REASON` estruturado
  quando disponível.
- Criar doctor read-only “Doctor: pacotes AUR marcados desatualizados” ou anexar
  ao `Verificação final de pendências` sem virar pendência de update.
- Classificar como informativo: pacote marcado pelo mantenedor não significa que
  há versão instalável agora.

**Critério de aceite:**

- Pacotes out-of-date aparecem em seção própria do relatório/summary.
- Não gera `warn`/`todo` se não há atualização aplicável.
- Pendência real de AUR continua sendo detectada como hoje.
- Parser cobre saída em PT-BR e, se simples, em EN.

---

### O5 — 🟡 P ☑ Melhorar pendência adiada de MCP quando cache `uv` está em uso

**Problema:** o step `Atualizar servidores MCP` já classifica lock de `uv` como
`ok`, mas a pendência operacional fica apenas no motivo do step e pode passar
despercebida.

**Evidência do run:**

- `Cache uv em uso (server uvx ativo); refresh adiado...`
- Comando sugerido: `uv cache clean serena`.

**Arquivos:**

- `lib/steps/mcp.sh`
- `lib/report.sh` se necessário expor “ações adiadas”
- `tests/mcp.bats`

**O quê:**

- Registrar refresh adiado como nota operacional no relatório, sem alterar status
  para `warn`/`todo`.
- Padronizar `STEP_REASON` para facilitar parse por relatório futuro.
- Opcional: adicionar helper que emite uma seção “Ações adiadas não-fatais”.

**Critério de aceite:**

- Lock de server ativo continua `ok`.
- Relatório `.md` mostra claramente o comando para rodar quando MCP estiver
  ocioso.
- Erro real de `uv cache clean` continua `RC_WARN`.

---

### O6 — 🟢 P ☑ Reduzir ruído de Ruby quando tudo é gerenciado pelo Arch

**Problema:** `Atualizar gems de usuário` lista várias gems desatualizadas, mas
conclui corretamente que todas são gerenciadas pelo Arch e não devem ser
atualizadas via `gem update`. A saída é longa para um caso não acionável.

**Arquivos:**

- `lib/steps/lang_other.sh`
- `tests/lang_other*.bats`

**O quê:**

- Quando `updatable` estiver vazio e todas as outdated forem Arch-managed, mostrar
  no terminal só contagem/resumo.
- Gravar lista completa no log.
- Manter modo verboso atual se houver gems próprias do usuário para atualizar.

**Critério de aceite:**

- Terminal fica conciso no caso “todas Arch-managed”.
- Log mantém auditoria completa.
- Nunca atualiza gems que sombreariam o sistema.

---

### O7 — 🟢 M ☑ Unificar postura de segurança entre doctor e `--audit`

**Problema:** `Doctor: fwupd security` considera HSI:3 aceitável e trata
marcadores `✘` como normais, enquanto `--audit` destaca Secure Boot desabilitado
como média. Ambos estão corretos isoladamente, mas a leitura conjunta pode soar
contraditória.

**Arquivos:**

- `lib/steps/audit.sh`
- `lib/steps/doctor.sh`
- `lib/config.sh` se houver política configurável

**O quê:**

- Explicitar no `--audit` que Secure Boot é postura/política, não falha
  operacional.
- Considerar config para severidade de Secure Boot: `info` por default,
  `medium` quando o usuário optar por política estrita.
- Reutilizar texto comum para HSI/Secure Boot entre doctor e audit.

**Critério de aceite:**

- `--audit` deixa claro “não acionável por software”.
- Usuário pode optar por política estrita sem afetar default.
- HSI:3 continua informativo/aceitável.

---

## Ordem de Execução Sugerida

Rodada 1 — limpar severidade enganosa e warn recorrente:

1. **O1** — alinhar `--audit` com CVEs Rust não acionáveis.
2. **O2** — melhorar classificação do journal.

Rodada 2 — melhorar diagnóstico de inventário e updates:

3. **O3** — apps manuais reais vs backups/remanescentes.
4. **O4** — AUR out-of-date informativo.
5. **O5** — ações MCP adiadas no relatório.

Rodada 3 — acabamento/UX:

6. **O6** — saída Ruby concisa.
7. **O7** — postura de segurança unificada.

Cada item deve virar PR isolado quando possível. Atualizar `CHANGELOG.md` em
`Unreleased` a cada PR.

---

## Validação Padrão

Antes de considerar um item concluído:

```bash
bash -n full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh
shellcheck -S warning -x full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh
bats tests/
./full-upgrade.sh --help
./full-upgrade.sh --list-steps
./full-upgrade.sh --audit
./full-upgrade.sh --mode doctor
XDG_CONFIG_HOME=/tmp/nocfg ./full-upgrade.sh --dry-run --mode full
```

Após mudança estrutural ou novo arquivo em `lib/steps`:

```bash
./build.sh
./dist/full-upgrade-standalone.sh --list-steps
```

---

## Achados do Run Real

### Run 2026-07-01 16:33 · v3.19.0-7-gaee842d · `--mode full`

**Resultado:** `101 ok · 1 warn · 0 todo · 0 fail · 3 skip` em `6m14s`.

**Mutação principal:**

- `tmux` atualizado de `3.7-1` para `3.7_a-1`.

**Warn formal:**

- `Doctor: journal erros críticos` com `19` erros pós-filtro, `8` assinaturas.
- Causa dominante: ruído de sessão gráfica/app (`ZapZap`, promises desconectadas)
  e Bluetooth/PipeWire/USB serial transitório.
- Não houve falha em pacman, AUR, disk, boot, SMART, btrfs, systemd units,
  Python, JS ou Ruby shadowing.

**Informativos relevantes:**

- CVEs em `rustup` persistem por crates vendorizadas upstream; `rustup` já está na
  última versão.
- `arch-audit`: `21` pacotes oficiais com CVE conhecida, todos sem correção
  upstream disponível no momento.
- MCP: `serena` uvx com cache `uv` em uso; refresh adiado sem falha.
- Ruby: gems outdated listadas são gerenciadas pelo Arch; corretamente puladas.
- AUR marcou `apple-fonts`, `github-desktop`, `nomacs`, `quickshell-git` e
  `whitesur-gtk-theme` como out-of-date, sem update aplicável no run.

**Skips legítimos:**

- Snap não instalado.
- Bun não instalado.
- Kimi CLI não instalado.

### Audit 2026-07-01 · `--audit`

**Resultado:** `1 alta · 1 média · 0 baixa · 2 info`.

**Achados:**

- `[ALTA] CVEs em binários cargo`: `rustup`.
- `[MÉDIA] Secure Boot desabilitado`.
- `[INFO] 21 pacote(s) oficial(is) com CVE sem correção upstream`.
- `[INFO] fwupd HSI:3`.

**Conclusão de produto:**

- O audit está funcional, mas `rustup` deve seguir a mesma regra do run normal:
  quando a toolchain já está atualizada e o remanescente é vendorizado upstream,
  o achado é informativo, não alta severidade.
