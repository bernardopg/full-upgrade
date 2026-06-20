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

> **Concluídos** (removidos deste arquivo): C1–C9, M1–M8, F1–F8, G1.
> Histórico no `CHANGELOG.md` e nos PRs. F2/F5/F6/F7/F8 entregues na v3.6.0
> (PRs #29/#30/#31/#32/#33). G1 (scrub btrfs) entregue na PR #35.

---

## 🚀 Features (pendentes)

> Capacidade nova. Roadmap G-series, ancorado nos achados de run real ainda em
> aberto e na composição das libs já entregues (`report.sh`, `history.sh`,
> `audit.sh`).

### G1 — 🟡 ☑ Auto-remediação opcional de scrub btrfs
> **Concluído (PR #35).** Step "Auto-remediar scrub btrfs" (`repair`/`mutating`)
> gateado por `AUTO_BTRFS_SCRUB` (default 0); inicia `btrfs scrub start /`
> (não-bloqueante) quando ausente/vencido, sob `--yes`/confirmação. Helper puro
> `btrfs_scrub_state` + `tests/btrfs_scrub.bats`. Bônus: fix de locale no parse
> de data do scrub (`LC_ALL=C`) também no `doctor_btrfs_health`.

### G2 — 🟡 ☐ Elevar arch-audit ao fluxo normal (CVEs de pacotes oficiais)
> `--audit` (F6) já consulta `arch-audit` se presente; falta no run padrão.
- **Arquivos:** `lib/steps/pacman.sh` ou `lib/steps/doctor.sh`, `lib/catalog.sh`
- **O quê:** novo step read-only "Doctor: CVEs de pacotes oficiais (arch-audit)"
  que lista pacotes com advisories; `warn` se houver corrigíveis por `-Syu`,
  `todo` se exigir ação manual. Gateado por `has arch-audit` (vira `skip`).
- **Aceite:** sem `arch-audit` → `skip`; com CVEs corrigíveis → `warn` citando
  `pacman -Syu`; parser puro coberto por bats.

### G3 — 🟢 ☐ Relatório Markdown automático ao fim do run
> Reaproveita `generate_report` (F2) sem flag manual.
- **Arquivos:** `lib/main.sh` (`finalize`), `lib/config.sh`
- **O quê:** chave `REPORT_ON_FINISH=0` default; quando `1`, grava o relatório
  do run recém-concluído em `~/.cache/system-upgrade/full-upgrade-<run_id>.md`.
- **Aceite:** com a chave ligada, o arquivo `.md` existe e reflete o run; default
  inalterado; não falha o run se a geração falhar (`RC_WARN`/log).

### G4 — 🟢 ☐ `--audit --report [ARQ]` (persistir auditoria em Markdown)
> Compõe F6 + F2: hoje `--audit` só imprime texto/JSON.
- **Arquivos:** `lib/steps/audit.sh`, `lib/cli.sh`
- **O quê:** quando `--report [ARQ]` acompanha `--audit`, emitir o relatório de
  segurança em Markdown (por severidade, com remediação) no arquivo/stdout.
- **Aceite:** `--audit --report /tmp/a.md` grava Markdown válido com os achados;
  `--audit` sozinho mantém a saída atual; cobertura bats do formatador.

---

## Ordem de execução sugerida

1. ~~**G1** (scrub btrfs)~~ — ✅ concluído (PR #35).
2. **G2** (CVEs de pacotes oficiais no fluxo padrão). ← próximo
3. **G3, G4** (composição de relatórios — baixo risco, reuso das libs novas).

Cada item vira um PR isolado (branch protection na `main` exige PR + checks
verdes). Atualizar `CHANGELOG.md` (seção Unreleased) a cada PR.

## Progresso

- **Concluído:** C1–C9; M1–M8; F1–F8 (v3.6.0); **G1** (scrub btrfs, PR #35).
- **Próximo:** G2 (CVEs de pacotes oficiais via arch-audit no fluxo padrão).
- **Restante:** G2–G4.

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
  (inkscape, libreoffice-fresh, poppler/-glib/-qt6, python-tqdm).
- `Doctor: reboot pendente`: kernel 7.0.11 (rodando) vs 7.0.12 (instalado).
- `Doctor: saúde do btrfs`: nenhum scrub registrado em `/` (`btrfs scrub start /`).

**Anomalias de performance/UX (já corrigidas — C6–C9):**
- `Atualizar imagens Docker` levou 1m15s só para logar "daemon não acessível". → C8.
- Resumo agrupou Flatpak/Docker sob "Doctor (auditorias)". → C6.
- Header "Shell / Editor" impresso 2×. → C7.
- `poetry-core` 2.4.0→2.4.1 (pip --user) e revertido no mesmo run. → C9.

**Observações de ambiente (não acionáveis no script):**
- fwupd `HSI:3 de 4`; Secure Boot UEFI desabilitado; RAM não criptografada.
- `xdg-desktop-portal` não instalado (afeta screencast/file pickers/flatpaks).
- Boot ~41,6s total (firmware 27,7s domina); userspace 5,2s — saudável.
- SMART OK em nvme0/nvme1; disco 59% / e 26% /boot.
