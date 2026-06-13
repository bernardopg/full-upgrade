# TO-DO — Roadmap full-upgrade

Roadmap vivo: **correções + melhorias + features**, decididos a partir de gaps
reais do código e de **achados de runs reais** (ver seção "Achados do run real"
ao final). Priorizados por impacto × esforço. Cada item lista: **arquivos**,
**o quê**, **critério de aceite**.

Convenções respeitadas em todos os itens:

- Funções de step retornam via RC contract (`0`/`RC_WARN`/`RC_TODO`/fail); nunca `exit`.
- Toda mudança valida com: `bash -n` + `shellcheck -S warning -x` + `bats tests/` + `--dry-run` + `build.sh`.
- Comentários e strings de usuário em PT-BR.
- Nome de step é byte-idêntico entre catálogo, `main.sh` e `--skip`/`--explain-step`.

Legenda de prioridade: 🔴 alta · 🟡 média · 🟢 baixa.
Status: ☐ pendente · ◐ em andamento · ☑ concluído.

---

## 🔧 Correções (5)

> Bugs reais ou comportamento incorreto identificado no código atual.

### C1 — 🔴 ☑ Join key quebrado nos steps custom (espaço inicial no catálogo)
> **Concluído (PR #6).** Espaço removido das 5 linhas; testes de integridade
> rejeitam espaço em borda e validam a correspondência catálogo⇄`main.sh`.
- **Arquivos:** `lib/catalog.sh`, `tests/catalog_integrity.bats`
- **Problema:** linhas 47–51 do catálogo têm um espaço à frente do nome
  (` Atualizar Hermes`), mas `lib/main.sh` chama `"Atualizar Hermes"` (sem
  espaço). O nome é a chave de junção catálogo⇄dispatch — o mismatch faz a
  busca de metadata falhar **silenciosamente**, e timeout/`cmd_deps` caem para
  o default. Afeta: Hermes, AdGuard VPN, OpenClaw, Claude Code CLI, Copilot CLI.
- **Fazer:** remover o espaço inicial das 5 linhas do catálogo.
- **Aceite:** novo teste bats que falha se qualquer nome de step do catálogo
  tiver espaço em borda (`^ ` ou ` $`); `--explain-step "Atualizar Hermes"`
  retorna timeout/deps corretos (não o default).

### C2 — 🔴 ☑ self_update sem verificação de integridade do tarball
> **Concluído (PR #8).** Canal `release` baixa standalone + `.sha256`, verifica
> SHA-256 e só instala se bater (backup do anterior); aborta sem checksum.
> Canal `main` avisa que não há verificação por checksum. Helpers puros
> `parse_sha256_field`/`file_sha256`/`verify_sha256` com testes (inclui
> cenário de adulteração).
- **Arquivos:** `lib/steps/self_update.sh`, `lib/core.sh`
- **Problema:** `--update` baixa o tarball da release e roda `install.sh` sem
  validar checksum/assinatura. Tarball adulterado em trânsito = execução
  arbitrária com as permissões do usuário.
- **Fazer:** baixar o `*.sha256` (ou digest da API do GitHub) junto e validar
  antes de extrair; abortar com erro claro se não bater. Opcional: validar
  assinatura GPG se a release publicar `.sig`.
- **Aceite:** update aborta (rc≠0, mensagem PT-BR) com checksum forjado;
  prossegue com checksum válido; teste bats da função pura de comparação de hash.

### C3 — 🟡 ☑ `cleanup_orphans` não trata órfãos recursivos remanescentes
> **Concluído.** `cleanup_orphans` agora roda em loop até `pacman -Qdtq` zerar
> (limite `ORPHAN_CLEANUP_MAX_ROUNDS`, default 5), com teste Bats simulando
> `pkg-a → pkg-b → vazio`.
- **Arquivos:** `lib/steps/pacman.sh`
- **Problema:** `pacman -Qdtq` lista órfãos de um nível; após remover, novos
  órfãos podem surgir (deps que só o removido puxava). Hoje roda uma passada só.
- **Fazer:** loop até a lista estabilizar (máx. N iterações), confirmando a
  lista total ao usuário antes da 1ª remoção (mantém gate interativo/`--yes`).
- **Aceite:** segunda passada não deixa órfãos triviais; dry-run não muta;
  teste do parser puro de lista de órfãos.

### C4 — 🟡 ☑ `doctor_failed_systemd_units` ignora units `--user` em alguns casos
> **Concluído.** `systemd_user_scope_status` distingue `available`, `no-runtime`
> e `no-bus`; o doctor agora registra explicitamente quando a checagem `--user`
> foi pulada em vez de afirmar "sistema/usuário".
- **Arquivos:** `lib/steps/doctor.sh`
- **Problema:** a coleta de units falhadas de usuário depende de
  `DBUS_SESSION_BUS_ADDRESS`/`XDG_RUNTIME_DIR`; sob sudo/cron o escopo de
  usuário fica vazio e mascara falhas reais. Sem aviso de que a checagem foi
  parcial.
- **Fazer:** detectar ausência de bus de sessão e logar explicitamente que a
  checagem `--user` foi pulada (não silenciar); tentar resolver `XDG_RUNTIME_DIR`.
- **Aceite:** sem bus de sessão → mensagem clara "checagem --user pulada
  (sem sessão)"; com sessão → lista units `--user` falhadas.

### C5 — 🟢 ☑ Restauração de mirrorlist não verifica conteúdo do backup
> **Concluído.** `mirrorlist_has_server` valida `^Server =` ativo antes da
> restauração; backups vazios/comentados não sobrescrevem a mirrorlist corrente.
- **Arquivos:** `lib/steps/coverage.sh`
- **Problema:** em falha do reflector, restaura `cp` do backup sem checar se o
  backup tem ao menos uma linha `Server =`. Backup vazio/corrompido deixaria o
  sistema sem mirrors.
- **Fazer:** validar que o backup contém `^Server` antes de restaurar; se
  inválido, manter o atual e avisar.
- **Aceite:** backup vazio não sobrescreve mirrorlist válido; teste do
  validador puro.

### C6 — 🔴 ☑ Resumo final classifica Flatpak/Docker em "Doctor (auditorias)"
> **Concluído.** `summary_group_specs` agrupa `containers flatpak docker snap`
> sob "Contêineres"; teste garante que toda categoria do catálogo pertence a
> algum grupo.
- **Arquivos:** `lib/ui.sh` (`print_summary` → `cat_order`/`_category_label`)
- **Problema:** `cat_order` em `print_summary` lista `containers`, mas os steps
  Flatpak/Docker têm `categoria=flatpak` e `categoria=docker` no catálogo
  (`lib/catalog.sh` linhas 27/29). Como nenhum dos dois está em `cat_order`,
  caem no laço "defensivo" de steps sem categoria conhecida e são impressos
  **após** o último grupo (Doctor), parecendo parte dele. `_category_label` já
  mapeia `flatpak|docker|containers → "Contêineres"`, mas o agrupamento usa a
  string crua da categoria, não o rótulo.
- **Fazer:** incluir `flatpak` e `docker` em `cat_order` (logo após `containers`),
  ou normalizar a categoria via `_category_label` antes de agrupar. Garantir que
  os três compartilhem o mesmo bloco "Contêineres" sem duplicar header.
- **Aceite:** no resumo, Flatpak e Docker aparecem sob "Contêineres"; nenhum
  step real cai no laço defensivo de "categoria desconhecida"; teste/QA visual
  com `--dry-run` confirma agrupamento.

### C7 — 🟡 ☑ Header de categoria duplicado no resumo ("Shell / Editor" 2x)
> **Concluído.** O resumo agora itera por grupos (`Shell / Editor|editor shell`),
> não por categoria crua; teste garante um único header para editor+shell.
- **Arquivos:** `lib/ui.sh` (`print_summary`, `_category_label`)
- **Problema:** `cat_order` tem `editor` e `shell` como entradas separadas, mas
  `_category_label` mapeia **ambas** para a mesma string "Shell / Editor".
  Cada categoria imprime seu próprio header → rótulo repetido em blocos
  distintos.
- **Fazer:** ou (a) fundir a iteração por rótulo (agrupar categorias que
  compartilham label sob um único header), ou (b) dar rótulos distintos
  ("Editor" e "Shell"). Preferir (a) para manter a intenção de agrupamento.
- **Aceite:** cada rótulo de categoria aparece no máximo uma vez no resumo;
  steps `editor` e `shell` ficam sob um único bloco coerente.

### C8 — 🔴 ☑ `docker info` trava ~75s quando o daemon está inacessível
> **Concluído.** `update_docker_images` agora usa `docker_daemon_accessible`
> com `timeout ${DOCKER_INFO_TIMEOUT_S:-5}`; valor inválido cai para 5s. Teste
> real com daemon inacessível retornou em **5,011s**.
- **Arquivos:** `lib/steps/containers.sh` (`update_docker_images`)
- **Problema:** o socket `/var/run/docker.sock` existe (Docker instalado mas
  parado/sem permissão), então `docker info` bloqueia no timeout de conexão
  padrão (~75s) em vez de falhar rápido. O step só é salvo pelo timeout de
  catálogo (600s), desperdiçando ~25% do tempo total do run.
- **Fazer:** envolver a checagem com timeout curto — `timeout 5 docker info`
  ou `DOCKER_CLIENT_TIMEOUT`/`COMPOSE_HTTP_TIMEOUT`, ou checar o socket antes
  (`[[ -S /var/run/docker.sock ]]` + `systemctl is-active docker`). Pular em
  <5s quando o daemon não responde.
- **Aceite:** com daemon parado, o step retorna em ≤5s com "daemon não
  acessível; pulando"; com daemon ativo, comportamento atual; sem regressão no
  caminho de pull.

### C9 — 🟡 ☑ Conflito recorrente poetry-core entre pip --user e Poetry
> **Concluído.** O update genérico do pip --user agora calcula uma lista efetiva
> de ignore e adiciona `poetry-core` automaticamente quando o Poetry instalado
> declara requisito fixo (`poetry-core (==2.4.0)`).
- **Arquivos:** `lib/steps/lang_py.sh` (update pip --user e step Poetry), config
- **Problema:** `poetry-core` não está na lista de ignore default de pip --user
  (`FULL_UPGRADE_PIP_USER_IGNORE` está vazio na config do usuário), então o
  update genérico o atualiza, e o step do Poetry tem que reverter. Ping-pong.
- **Fazer:** detectar Poetry gerenciado por pip --user e tratar `poetry-core`
  como pinned (adicionar ao ignore efetivo automaticamente quando Poetry está
  presente), ou ordenar/condicionar para não atualizar `poetry-core` isolado.
  Documentar a chave de ignore recomendada no `config.example`.
- **Aceite:** em duas execuções seguidas, `poetry-core` não oscila de versão;
  `pip check` não reporta o conflito poetry↔poetry-core introduzido pelo run.

---

## ⚡ Melhorias (5)

> Refino de algo que já funciona: robustez, clareza, performance, UX.

### M1 — 🔴 ☑ Pré-flight de espaço para o snapshot
> **Concluído (PR #6).** `SNAPSHOT_MIN_FREE_GIB` (default 2; `0` desliga);
> helpers puros `space_is_sufficient`/`avail_kib_for_path` com testes.
- **Arquivos:** `lib/steps/coverage.sh`, `lib/core.sh`
- **O quê:** antes de criar snapshot btrfs, checar espaço livre no subvolume; se
  abaixo de um limiar configurável (`SNAPSHOT_MIN_FREE_GIB`), avisar e
  prosseguir sem falhar (snapshot que enche o disco é pior que não ter).
- **Aceite:** espaço baixo → `RC_WARN` com motivo, não cria snapshot; espaço OK
  → comportamento atual.

### M2 — 🟡 ☐ Cleanup de snapshots antigos (retenção)
- **Arquivos:** `lib/steps/cleanup.sh`, `lib/catalog.sh`, `lib/main.sh`
- **O quê:** novo step opcional que remove snapshots full-upgrade antigos
  (snapper/timeshift) mantendo os N mais recentes (`SNAPSHOT_KEEP`, default 5),
  análogo ao `paccache -k 2`. Gate interativo/`--yes`.
- **Aceite:** mantém só os N mais novos criados pelo script; dry-run não muta;
  não toca snapshots de outras origens.

### M3 — 🟡 ☐ Sumário agrupado por categoria com tempos
- **Arquivos:** `lib/main.sh` (finalize), `lib/json.sh`
- **O quê:** no resumo final, agrupar steps por categoria com total de tempo por
  grupo (já existe `STEP_CATEGORIES`); destacar os 3 steps mais lentos.
- **Aceite:** resumo mostra blocos por categoria + "top 3 mais lentos";
  `--json` inclui agregação por categoria.

### M4 — 🟡 ☐ Padronizar normalização de versão (reuso do semver)
- **Arquivos:** `lib/core.sh`, `lib/steps/lang_*.sh`
- **O quê:** vários steps fazem parsing ad-hoc de "update available". Centralizar
  num helper puro reutilizável (já há `normalize`/`compare` em self_update);
  promover para `core.sh` e reusar onde houver checagem de versão.
- **Aceite:** ≥3 steps passam a usar o helper comum; testes bats cobrem o helper
  promovido; sem regressão de comportamento.

### M5 — 🟢 ☐ Mensagens de remediação acionáveis e consistentes
- **Arquivos:** `lib/steps/*.sh`
- **O quê:** padronizar avisos `todo`/`warn` para sempre incluir o comando exato
  de remediação (padrão "Remediação: <cmd>"), como já feito em cargo/pipx.
- **Aceite:** todo `RC_TODO`/`RC_WARN` com ação manual imprime uma linha
  `Remediação:` reproduzível.

### M6 — 🟡 ☐ Resumo destaca pendências oficiais não aplicadas
> **Achado no run real 3.2.2.** "Verificação final de pendências" (`RC_TODO`)
> listou 6 pacotes oficiais com update disponível (inkscape, libreoffice-fresh,
> poppler*, python-tqdm) que **não foram aplicados** no mesmo run — a base de
> dados foi sincronizada por outro step depois do `-Syu`.
- **Arquivos:** `lib/steps/coverage.sh` (verificação final), `lib/main.sh`
- **O quê:** quando a verificação final detectar pendências oficiais, deixar
  claro no resumo/`todo` por que não foram aplicadas (db sincronizado após o
  upgrade) e oferecer remediação direta (`sudo pacman -Syu`). Idealmente,
  reordenar para que a verificação final rode antes de qualquer `-Sy` posterior,
  ou re-rodar o upgrade se a checagem encontrar pendências triviais.
- **Aceite:** pendências oficiais no fim de um run aparecem com motivo +
  remediação; em ambiente estável a verificação final não acusa pendências logo
  após o upgrade.

### M7 — 🟢 ☐ Suprimir ruído de build no log (setuptools/rdoc warnings)
> **Achado no run real 3.2.2.** Builds AUR (zapzap-git em run anterior; rdoc no
> empacotamento do próprio full-upgrade) despejam dezenas de linhas de
> `SetuptoolsDeprecationWarning` e `already initialized constant RDoc::...` no
> log, afogando sinais úteis.
- **Arquivos:** `lib/core.sh` (`run_logged`/helpers de captura), steps de build
- **O quê:** filtrar/colapsar classes conhecidas de warning de build no output
  ao terminal (mantendo o log bruto completo em arquivo), com um contador
  ("N warnings de build suprimidos; ver log"). Não alterar o que vai para o
  `.log`/`.jsonl`.
- **Aceite:** terminal mostra resumo compacto; `latest.log` mantém o output
  bruto; nenhuma supressão de erros reais (apenas warnings allow-listed).

### M8 — 🟢 ☐ Sugerir reboot ao final quando kernel/microcode mudou
> **Achado no run real 3.2.2.** "Doctor: reboot pendente" detectou kernel em
> execução `7.0.11` vs instalado `7.0.12` (`RC_TODO`), mas isso só aparece no
> meio do bloco Doctor; fácil de perder num run de 75 steps.
- **Arquivos:** `lib/main.sh` (`finalize`/`print_summary`), `lib/steps/doctor.sh`
- **O quê:** quando houver reboot pendente (kernel/microcode/systemd), elevar
  isso a um aviso de destaque no rodapé do resumo (linha própria, cor), além do
  item Doctor. Reaproveitar a detecção existente.
- **Aceite:** com kernel novo instalado e não rebootado, o rodapé do resumo
  mostra "Reboot recomendado: kernel X→Y"; sem pendência, nada é impresso.

---

## 🚀 Features (5)

> Capacidade nova.

### F1 — 🔴 ☑ Backup de configs críticas de `/etc` antes das mutações
> **Concluído (PR #6).** `lib/steps/backup.sh` com `tar.zst` (fallback gzip),
> rotação (`BACKUP_KEEP`), dry-run sem escrita, helpers puros testados. Config:
> `BACKUP_CONFIGS`/`BACKUP_KEEP`/`BACKUP_PATHS`. `build.sh` ganhou guarda
> anti-regressão de `ORDER`.
- **Arquivos:** novo `lib/steps/backup.sh`, `lib/catalog.sh`, `lib/main.sh`, config
- **O quê:** step core opcional que arquiva (tar.zst) uma lista configurável de
  paths (`/etc/pacman.conf`, `/etc/pacman.d/`, `/etc/fstab`, `/etc/mkinitcpio.conf`,
  `/etc/systemd/`, dotfiles do usuário) em `~/.cache/system-upgrade/backups/`,
  com rotação. Roda antes do update.
- **Aceite:** gera tarball verificável; rotação mantém N backups; `--dry-run`
  lista o que arquivaria sem escrever; lista de paths via `FULL_UPGRADE_BACKUP_PATHS`.

### F2 — 🟡 ☐ Export de relatório do run (Markdown)
- **Arquivos:** `lib/json.sh` ou novo `lib/report.sh`, `lib/cli.sh`
- **O quê:** flag `--report [arquivo.md]` que gera, a partir do JSONL, um
  relatório legível: resumo, tabela de steps (status/tempo/motivo), pendências
  `todo`, links do log. Reaproveita os eventos já gravados.
- **Aceite:** `--report /tmp/r.md` produz Markdown válido refletindo o run;
  funciona a partir de um JSONL existente (`--report --from <run_id>`).

### F3 — 🟡 ☑ Doctor: status de scrub/erros btrfs
> **Concluído (PR #9).** `doctor_btrfs_health` + helper puro
> `sum_btrfs_dev_errors`; `BTRFS_SCRUB_MAX_DAYS`. Testado real (sem erros,
> scrub ausente → `RC_TODO`).
- **Arquivos:** `lib/steps/doctor.sh`, `lib/core.sh`, `lib/catalog.sh`, `lib/main.sh`
- **O quê:** novo `doctor_btrfs_health`: em raiz btrfs, reporta `btrfs device
  stats` (erros de I/O acumulados) e a idade do último scrub; `RC_TODO` se scrub
  vencido (> `BTRFS_SCRUB_MAX_DAYS`) ou erros > 0.
- **Aceite:** raiz não-btrfs → skip limpo; erros/scrub vencido → `RC_TODO` com
  remediação (`btrfs scrub start /`).

### F4 — 🟡 ☑ Doctor: tempo de boot (systemd-analyze)
> **Concluído (PR #9).** `doctor_boot_time` + helper puro
> `systemd_time_to_seconds`; `BOOT_TIME_WARN_S`. Testado real (boot ~24s, top-5
> units, `RC_WARN` acima do limiar).
- **Arquivos:** `lib/steps/doctor.sh`, `lib/core.sh`, `lib/catalog.sh`, `lib/main.sh`
- **O quê:** novo `doctor_boot_time`: `systemd-analyze time` + top de
  `systemd-analyze blame`; `RC_WARN` se boot acima de limiar
  (`BOOT_TIME_WARN_S`) ou se houver serviço dominando o tempo.
- **Aceite:** mostra tempo total + 5 piores units; acima do limiar → `RC_WARN`.

### F5 — 🟢 ☐ Flag `--fail-fast` / `--continue-on-fail`
- **Arquivos:** `lib/globals.sh`, `lib/cli.sh`, `lib/core.sh` (run_step), `lib/main.sh`
- **O quê:** controlar política ao primeiro `fail`: `--fail-fast` aborta o run
  imediatamente (útil em CI/manual); default continua (comportamento atual,
  explicitável via `--continue-on-fail`).
- **Aceite:** `--fail-fast` para no 1º fail e marca os restantes como skip com
  motivo "abortado por --fail-fast"; default inalterado; smoke em `--dry-run`.

### F6 — 🟡 ☐ `--audit` / modo auditoria de segurança consolidada
> **Motivado pelo run real 3.2.2:** o run já coleta sinais de segurança
> dispersos — CVEs de binários cargo (rustls-webpki, tar, tracing-subscriber),
> `fwupd security` (HSI:3, Secure Boot desabilitado), units falhadas, erros
> críticos do journal (falha de auth sudo). Falta uma visão única.
- **Arquivos:** novo `lib/steps/audit.sh` ou `lib/report.sh`, `lib/cli.sh`, catálogo
- **O quê:** flag `--audit` que roda só os checks read-only de segurança e emite
  um relatório consolidado: CVEs (cargo-audit + pacman/arch-audit se houver),
  postura fwupd/HSI, Secure Boot, units falhadas, erros de auth no journal,
  pip/npm quebrados. Severidade por item.
- **Aceite:** `--audit` é não-mutável (como doctor), agrega achados de segurança
  num bloco único com severidade e remediação; `--json` inclui a seção audit.

### F7 — 🟡 ☐ Auto-remediação opcional de CVEs de toolchain (rustup/cargo)
> **Achado no run real 3.2.2.** "Auditar binários cargo (CVEs)" reportou 7 CVEs
> em `rustup` e instruiu manualmente `rustup self update && rustup update`, mas
> não age.
- **Arquivos:** `lib/steps/lang_rust.sh`, `lib/catalog.sh`, config
- **O quê:** quando a auditoria encontrar CVEs corrigíveis por
  `rustup self update`/`rustup update`/`cargo install-update`, oferecer aplicar
  (gate interativo/`--yes`), atrás de uma chave de config
  (`AUTO_FIX_RUST_CVES=0` default). Reportar antes/depois.
- **Aceite:** com a chave ligada e `--yes`, CVEs de toolchain corrigíveis são
  aplicadas e re-auditadas; default não muta nada; sem rede → `RC_WARN`.

### F8 — 🟢 ☐ Histórico/tendência de runs (`--history`)
> **Motivado pelo run real:** já existem ~20 `.jsonl` rotacionados em
> `~/.cache/system-upgrade/` com `summary` por run (ok/warn/todo/fail/duração),
> mas nada os consome de forma agregada.
- **Arquivos:** novo `lib/report.sh`, `lib/cli.sh`, `lib/json.sh`
- **O quê:** flag `--history [N]` que lê os eventos `summary` dos últimos N
  JSONL e mostra uma tabela/tendência: data, versão, ok/warn/todo/fail, duração,
  e deltas (ex.: tempo subindo, novos warns recorrentes). Puramente leitura.
- **Aceite:** `--history 10` lista os 10 runs mais recentes com contagens e
  duração; identifica warns/todos recorrentes; funciona sem rede e sem mutar.

---

## Ordem de execução sugerida

1. ~~**C1, C2**~~ ✅ (correções de alto impacto: join key + segurança do self-update).
2. ~~**M1, F1**~~ ✅ (segurança de dados antes de mutar: espaço de snapshot + backup /etc).
3. ~~**F3, F4**~~ ✅ (cobertura doctor: btrfs + boot time).
4. **M6, M8** (clareza de pendências/reboot).
5. **M3, F2** (observabilidade: sumário por categoria + relatório).
6. **F6, F8, F7** (segurança consolidada + histórico + auto-remediação CVEs).
7. **M2, M4, M5, M7, F5** (refino e robustez restantes).

Cada item vira um PR isolado (branch protection na `main` exige PR + checks
verdes). Atualizar `CHANGELOG.md` (seção Unreleased) a cada PR.

## Progresso

- **Concluído:** C1, M1, F1 (PR #6); C2 (PR #8); F3, F4 (PR #9); C3–C9.
- **Próximo:** M6/M8 (clareza de pendências/reboot) ou M3/F2 (observabilidade).
- **Restante:** M2–M8, F2, F5–F8.

---

## Achados do run real (auditoria)

Registro factual dos sinais de cada execução real, para rastrear regressões e
priorizar. Não é roadmap — é evidência.

### Run 2026-06-13 14:23 · v3.2.2 · `--mode full -y`

- **Resultado:** 68 ok · 3 warn · 3 todo · 0 fail · 1 skip em **4m43s** (exit 0).
- **Host:** PC-689c341c · kernel em execução 7.0.11-arch1-1.
- **Log:** `~/.cache/system-upgrade/full-upgrade-20260613-142301-900745.log`.

**Mutações reais aplicadas:**
- Snapshot timeshift pré-upgrade criado (rsync, 12s).
- Backup de 9 configs `/etc` → `configs-*.tar.zst` (1,3M), rotação mantendo 5.
- Mirrorlist atualizada via reflector (top 20 por rate; 4 mirrors com 404 ao ratear).
- AUR: `full-upgrade` atualizado para 3.2.2-1 (recém-publicado — pipeline de release validado end-to-end).
- Órfãos removidos (5): `python-pyproject-hooks`, `cli11`, `ioruba-desktop-debug`, `python-build`, `python-installer`.

**warn (3):**
- `Auditar binários cargo (CVEs)`: 7 CVEs em `rustup` (rustls-webpki ×4:
  RUSTSEC-2026-0049/0098/0099/0104; tar ×2: 0067/0068; tracing-subscriber:
  2025-0055; rand unsound: 2026-0097). → **F7**, **F6**.
- `Doctor: journal erros críticos`: 3 reais (2× falha de auth sudo `[bitter]`;
  1× Bluetooth hci0 opcode 0x0401 -16). 872 linhas de ruído filtradas.
- `Doctor: ambiente Python`: `pip check` quebrado — pygount↔chardet 7.4.3,
  doctoralia-scrapper↔redis 8.0.0/uvicorn 0.49.0, auto-cpufreq↔urwid 4.0.2.

**todo (3):**
- `Verificação final de pendências`: 6 pacotes oficiais com update não aplicado
  (inkscape, libreoffice-fresh, poppler/-glib/-qt6, python-tqdm). → **M6**.
- `Doctor: reboot pendente`: kernel 7.0.11 (rodando) vs 7.0.12 (instalado). → **M8**.
- `Doctor: saúde do btrfs`: nenhum scrub registrado em `/` (`btrfs scrub start /`).

**Anomalias de performance/UX (viraram itens):**
- `Atualizar imagens Docker` levou **1m15s** só para logar "daemon não acessível"
  (≈25% do run). → **C8**.
- Resumo agrupou Flatpak/Docker sob "Doctor (auditorias)". → **C6**.
- Header "Shell / Editor" impresso 2×. → **C7**.
- `poetry-core` 2.4.0→2.4.1 (pip --user) e revertido 2.4.1→2.4.0 (step Poetry) no
  mesmo run. → **C9**.

**Observações de ambiente (não acionáveis no script):**
- fwupd `HSI:3 de 4`; Secure Boot UEFI desabilitado; RAM não criptografada.
- `xdg-desktop-portal` não instalado (afeta screencast/file pickers/flatpaks).
- Boot ~41,6s total (firmware 27,7s domina); userspace 5,2s — saudável.
- SMART OK em nvme0/nvme1; disco 59% / e 26% /boot.
