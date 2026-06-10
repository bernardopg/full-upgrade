# TO-DO — Roadmap full-upgrade

Planejamento dos próximos 15 passos: **5 melhorias + 5 correções + 5 features**.
Decididos a partir de gaps reais do código (não genéricos), priorizados por
impacto × esforço. Cada item lista: **arquivos**, **o quê**, **critério de aceite**.

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

### C1 — 🔴 ☐ Join key quebrado nos steps custom (espaço inicial no catálogo)
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

### C2 — 🔴 ☐ self_update sem verificação de integridade do tarball
- **Arquivos:** `lib/steps/self_update.sh`
- **Problema:** `--update` baixa o tarball da release e roda `install.sh` sem
  validar checksum/assinatura. Tarball adulterado em trânsito = execução
  arbitrária com as permissões do usuário.
- **Fazer:** baixar o `*.sha256` (ou digest da API do GitHub) junto e validar
  antes de extrair; abortar com erro claro se não bater. Opcional: validar
  assinatura GPG se a release publicar `.sig`.
- **Aceite:** update aborta (rc≠0, mensagem PT-BR) com checksum forjado;
  prossegue com checksum válido; teste bats da função pura de comparação de hash.

### C3 — 🟡 ☐ `cleanup_orphans` não trata órfãos recursivos remanescentes
- **Arquivos:** `lib/steps/pacman.sh`
- **Problema:** `pacman -Qdtq` lista órfãos de um nível; após remover, novos
  órfãos podem surgir (deps que só o removido puxava). Hoje roda uma passada só.
- **Fazer:** loop até a lista estabilizar (máx. N iterações), confirmando a
  lista total ao usuário antes da 1ª remoção (mantém gate interativo/`--yes`).
- **Aceite:** segunda passada não deixa órfãos triviais; dry-run não muta;
  teste do parser puro de lista de órfãos.

### C4 — 🟡 ☐ `doctor_failed_systemd_units` ignora units `--user` em alguns casos
- **Arquivos:** `lib/steps/doctor.sh`
- **Problema:** a coleta de units falhadas de usuário depende de
  `DBUS_SESSION_BUS_ADDRESS`/`XDG_RUNTIME_DIR`; sob sudo/cron o escopo de
  usuário fica vazio e mascara falhas reais. Sem aviso de que a checagem foi
  parcial.
- **Fazer:** detectar ausência de bus de sessão e logar explicitamente que a
  checagem `--user` foi pulada (não silenciar); tentar resolver `XDG_RUNTIME_DIR`.
- **Aceite:** sem bus de sessão → mensagem clara "checagem --user pulada
  (sem sessão)"; com sessão → lista units `--user` falhadas.

### C5 — 🟢 ☐ Restauração de mirrorlist não verifica conteúdo do backup
- **Arquivos:** `lib/steps/coverage.sh`
- **Problema:** em falha do reflector, restaura `cp` do backup sem checar se o
  backup tem ao menos uma linha `Server =`. Backup vazio/corrompido deixaria o
  sistema sem mirrors.
- **Fazer:** validar que o backup contém `^Server` antes de restaurar; se
  inválido, manter o atual e avisar.
- **Aceite:** backup vazio não sobrescreve mirrorlist válido; teste do
  validador puro.

---

## ⚡ Melhorias (5)

> Refino de algo que já funciona: robustez, clareza, performance, UX.

### M1 — 🔴 ☐ Pré-flight de espaço para o snapshot
- **Arquivos:** `lib/steps/coverage.sh`
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

---

## 🚀 Features (5)

> Capacidade nova.

### F1 — 🔴 ☐ Backup de configs críticas de `/etc` antes das mutações
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

### F3 — 🟡 ☐ Doctor: status de scrub/erros btrfs
- **Arquivos:** `lib/steps/doctor.sh`, `lib/catalog.sh`, `lib/main.sh`
- **O quê:** novo `doctor_btrfs_health`: em raiz btrfs, reporta `btrfs device
  stats` (erros de I/O acumulados) e a idade do último scrub; `RC_TODO` se scrub
  vencido (> `BTRFS_SCRUB_MAX_DAYS`) ou erros > 0.
- **Aceite:** raiz não-btrfs → skip limpo; erros/scrub vencido → `RC_TODO` com
  remediação (`btrfs scrub start /`).

### F4 — 🟡 ☐ Doctor: tempo de boot (systemd-analyze)
- **Arquivos:** `lib/steps/doctor.sh`, `lib/catalog.sh`, `lib/main.sh`
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

---

## Ordem de execução sugerida

1. **C1, C2** (correções de alto impacto: join key + segurança do self-update).
2. **M1, F1** (segurança de dados antes de mutar: espaço de snapshot + backup /etc).
3. **F3, F4** (cobertura doctor: btrfs + boot time).
4. **M3, F2** (observabilidade: sumário por categoria + relatório).
5. **C3, C4, C5, M2, M4, M5, F5** (refino e robustez).

Cada item vira um PR isolado (branch protection na `main` exige PR + checks
verdes). Atualizar `CHANGELOG.md` (seção Unreleased) a cada PR.
