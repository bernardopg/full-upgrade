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

> **Concluídos** (removidos deste arquivo): C1–C9, M1–M8, F1–F8, **G1–G4**.
> Histórico no `CHANGELOG.md` e nos PRs. F2/F5/F6/F7/F8 → v3.6.0
> (PRs #29/#30/#31/#32/#33). G1–G4 → v3.7.0 (PRs #35/#37/#38/#39).

---

## 🚀 Features (pendentes)

Roadmap pós-v3.7.0, organizado em séries temáticas. Prioridade 🔴/🟡/🟢 e
esforço (P/M/G). Cada item vira um PR isolado. **Princípio:** não duplicar o que
o update genérico já cobre — `Atualizar npm global` (`update_npm_globals`) já
atualiza os CLIs de IA instalados via npm (9router, codex, cline, gemini, qwen),
e `cursor`/`code` são pacotes AUR (`cursor-bin`/`visual-studio-code-bin`)
atualizados pelo `pacman -Syu`/paru. Os steps novos miram **gaps reais**:
instaladores próprios, extensões de IDE, MCP e diagnóstico de versões.

---

### Série H — Ferramentas de IA & IDE (novos steps)

> Mira gaps de IA/IDE não cobertos pelo update genérico. Todos: efeito
> `mutating`, categoria `ai`/`editor`, gateados por `has <cmd>` (→ `skip`), rede
> via `run_network_cmd`/`RC_WARN`. Custom/autorais ficam em `steps.d/` se preciso.

#### H1 — 🟡 M ☑ Atualizar opencode (instalador próprio) — PR #44
> opencode vive em `~/.opencode/bin/opencode`, **fora do npm** → não é coberto
> pelo `update_npm_globals`. Tem subcomando próprio `opencode upgrade`.
- **Arquivos:** `lib/steps/ai.sh`, `lib/catalog.sh`, `lib/main.sh`
- **O quê:** step "Atualizar opencode" que roda `opencode upgrade` quando o
  binário existe. Loga versão antes/depois. Sem rede → `RC_WARN`.
- **Aceite:** sem `opencode` → `skip` (cmd_dep); com → roda upgrade e reporta;
  smoke `--dry-run`.

#### H2 — 🟡 M ☐ Atualizar Ollama (instalador próprio)
> `ollama` em `/usr/local/bin/ollama` (script de install upstream), fora do
> pacman e do npm → sem cobertura hoje.
- **Arquivos:** `lib/steps/ai.sh`, `lib/catalog.sh`, `lib/main.sh`, config
- **O quê:** step "Atualizar Ollama" que reexecuta o instalador oficial
  (`curl -fsSL https://ollama.com/install.sh | sh`) **somente** se
  `OLLAMA_SELF_UPDATE=1` (default 0, pois baixa+executa script remoto) e
  `/usr/local/bin/ollama` for gravável; senão reporta a versão e sugere update
  manual. Opcional: `ollama list`/`ollama ps` no doctor.
- **Aceite:** chave off → só reporta versão; chave on + gravável → atualiza;
  sem rede → `RC_WARN`; cobertura bats da decisão (gate/gravabilidade).

#### H3 — 🔴 M ☑ Atualizar extensões de IDE (VSCode/Cursor/Codium) — PR #42
> **Gap real e pedido explícito.** Os binários (`code`/`cursor`/`codium`) são
> AUR e já atualizam no pacman, mas **as extensões instaladas não** — ficam
> defasadas em silêncio.
- **Arquivos:** novo `lib/steps/ide.sh`, `lib/catalog.sh`, `lib/main.sh`, config
- **O quê:** para cada CLI presente (`code`, `cursor`, `codium`,
  `code-insiders`), rodar a atualização de extensões. VSCode 1.86+ tem
  `code --update-extensions`; fallback: `code --list-extensions` +
  `code --install-extension <id> --force` em loop. Lista de CLIs configurável
  (`IDE_EXT_CLIS`, default autodetect). Helper puro para parsear/diferenciar.
- **Aceite:** sem nenhum CLI → `skip`; com → atualiza extensões e reporta
  contagem; respeita `--dry-run`; parser coberto por bats.

#### H4 — 🟡 M ☐ Doctor: versões de CLIs de IA
> Visão única das versões instaladas vs. últimas — sem mutar.
- **Arquivos:** `lib/steps/doctor.sh` (ou `ai.sh`), `lib/catalog.sh`
- **O quê:** step read-only "Doctor: CLIs de IA" que lista versão de cada CLI
  detectado (claude, codex, copilot, gemini, qwen, cline, opencode, 9router,
  ollama, kimi) e marca os que têm método de update conhecido. `todo` se algum
  estiver claramente defasado (quando a checagem for barata/local).
- **Aceite:** lista versões dos instalados; ausentes não aparecem; read-only;
  parser de versão coberto por bats.

#### H5 — 🟢 P ☐ Atualizar Kimi CLI (opcional/gated)
> `kimi` (Moonshot) não está instalado na máquina-alvo hoje; manter como step
> opcional para quando existir. Se for npm, já cai no `update_npm_globals`.
- **Arquivos:** `steps.d/` (custom) ou `lib/steps/ai.sh`, `lib/catalog.sh`
- **O quê:** step "Atualizar Kimi CLI" gateado por `has kimi`; usa o método de
  update apropriado ao instalador detectado.
- **Aceite:** sem `kimi` → `skip`; com → atualiza; documentado no config-example.

#### H6 — 🟡 G ☐ Doctor/Atualizar servidores MCP
> Hoje nada gerencia MCP. Vários CLIs (claude, codex, opencode…) consomem MCP
> servers definidos em config; muitos são pacotes npm/uvx que ficam defasados.
- **Arquivos:** novo `lib/steps/mcp.sh`, `lib/catalog.sh`, `lib/main.sh`, config
- **O quê:** (a) read-only "Doctor: servidores MCP" que enumera MCP configurados
  (`claude mcp list` e/ou parse de configs conhecidas) e reporta os defasados;
  (b) opcional `mutating` gateado por `MCP_AUTO_UPDATE=1` que atualiza servers
  npm/uvx. Começar só pelo doctor (read-only).
- **Aceite:** sem fontes MCP → `skip`; com → lista servers/versões; auto-update
  atrás de chave; parsers cobertos por bats.

---

### Série I — Inspirado no arch-update (Antiz96/arch-update)

> Boas práticas de manutenção Arch ainda não cobertas. Ref:
> <https://github.com/Antiz96/arch-update>.

#### I1 — 🔴 M ☑ Checagem de Arch News pré-upgrade — PR #43
> **Maior ganho de segurança.** Arch publica intervenções manuais necessárias
> ANTES do `-Syu` (ex.: troca de chaves, particionamento). `arch-update` checa
> e exibe news antes de atualizar; hoje o full-upgrade não.
- **Arquivos:** novo `lib/steps/news.sh`, `lib/catalog.sh`, `lib/main.sh`, config
- **O quê:** step "Verificar Arch News" (read-only, antes das mutações) que lê o
  feed RSS (`https://archlinux.org/feeds/news/`) e mostra entradas desde o último
  upgrade. Se houver news não vista → `RC_TODO` (gate de atenção). Usa
  `informant` se instalado; senão parse RSS via `curl` + helper puro. Config
  `ARCH_NEWS_CHECK=1` (default), janela por data do último run.
- **Aceite:** news recente → `todo` citando os títulos; nenhuma → `ok`; sem rede
  → `RC_WARN`; parser de RSS coberto por bats (fixture).

#### I2 — 🟡 M ☐ Processar pacnew/pacsave (pacdiff)
> `arch-update` trata `.pacnew`/`.pacsave`. Configs órfãs/novas acumulam e
> divergem silenciosamente.
- **Arquivos:** `lib/steps/repair.sh` ou novo `lib/steps/pacfiles.sh`, catálogo
- **O quê:** step "Doctor: arquivos .pacnew/.pacsave" (read-only) que lista
  pendências via `pacdiff -o` (ou `find /etc -name '*.pacnew'`); `todo` se houver.
  Remediação interativa opcional (`pacdiff`) atrás de `--yes`/chave (mutating).
- **Aceite:** sem pendências → `ok`; com → `todo` listando arquivos; merge só sob
  confirmação; parser coberto por bats.

#### I3 — 🟢 M ☐ Suporte a helpers AUR e elevação alternativos
> `arch-update` suporta paru/yay/pikaur e sudo/doas/run0/sudo-rs. Hoje o projeto
> assume `paru` + `sudo`.
- **Arquivos:** `lib/config.sh`, `lib/sudo.sh`, `lib/steps/pacman.sh`
- **O quê:** autodetectar helper AUR (`AUR_HELPER` ∈ paru/yay/pikaur) e elevador
  (`PRIV_CMD` ∈ sudo/doas/run0/sudo-rs); usar o configurado/detectado em vez de
  hardcode.
- **Aceite:** com só `yay` instalado, o fluxo AUR usa `yay`; com `doas`, a
  elevação usa `doas`; defaults atuais preservados; cobertura bats da detecção.

#### I4 — 🟢 P ☐ Notificação desktop ao fim do run
> `arch-update` notifica via libnotify. Útil para runs longos/agendados.
- **Arquivos:** `lib/main.sh` (`finalize`), `lib/config.sh`
- **O quê:** `NOTIFY_ON_FINISH=0` default; quando `1` e `notify-send` presente,
  envia resumo (ok/warn/todo/fail + duração) ao final. Não derruba o run.
- **Aceite:** chave on + `notify-send` → notifica; ausência → no-op; default
  inalterado.

---

### Série J — Diagnóstico & integração (backlog acumulado)

#### J1 — 🟡 M ☑ Diagnóstico melhorado de `pip check` quebrado
> **Achado real recorrente:** pygount↔chardet, doctoralia↔redis/uvicorn,
> auto-cpufreq↔urwid. Auto-aplicar é arriscado (quebra constraints) → focar em
> **diagnóstico acionável**, não remediação automática.
- **Arquivos:** `lib/steps/doctor.sh` (`doctor_python_env`)
- **O quê:** agrupar os conflitos por pacote raiz, sugerir o comando exato de
  correção por conflito (ex.: `pipx`/venv isolado, ou pin), e separar conflitos
  de ferramentas de usuário (pipx/AUR) dos do sistema. Continua `warn`.
- **Aceite:** saída lista cada conflito com remediação sugerida; nenhum
  auto-`pip install`; parser coberto por bats.

#### J2 — 🟢 M ☐ Saída JSON para `--report` e `--history`
> Hoje `--report` é Markdown e `--history` é tabela. JSON habilita consumo por
> outras ferramentas/dashboards.
- **Arquivos:** `lib/report.sh`, `lib/history.sh`, `lib/cli.sh`
- **O quê:** `--report --json` e `--history --json` emitem JSON estruturado
  (reaproveitando os parsers awk já existentes).
- **Aceite:** JSON válido refletindo o run/histórico; Markdown/tabela inalterados
  sem `--json`; cobertura bats.

#### J3 — 🟢 P ☑ Remediação opcional de scrub btrfs em múltiplos mountpoints
> G1 cobre `/`. Sistemas com `/home`, `/.snapshots` btrfs separados ficam de fora.
- **Arquivos:** `lib/steps/doctor.sh` (`autofix_btrfs_scrub`)
- **O quê:** enumerar mountpoints btrfs via `findmnt -t btrfs` e aplicar a mesma
  lógica de G1 a cada um.
- **Aceite:** com 2+ mounts btrfs, cada um é avaliado/iniciado; helper de
  enumeração coberto por bats.

---

## Ordem de execução sugerida (impacto × esforço)

**Rodada 1 (alto impacto):** ✅ concluída (PRs #42/#43/#44).
1. ~~**H3** (extensões de IDE)~~ — ✅ PR #42.
2. ~~**I1** (Arch News pré-upgrade)~~ — ✅ PR #43.
3. ~~**H1** (opencode)~~ — ✅ PR #44.

**Rodada 2:** ← em andamento
4. ~~**H2** (Ollama)~~, ~~**H4** (doctor de versões IA)~~, ~~**I4** (notify)~~,
   ~~**I2** (pacnew/pacsave)~~, ~~**J1** (diagnóstico pip)~~.

**Rodada 3 (maior esforço / menor urgência):**
6. **H6** (MCP), **I3** (helpers/elevação alt.), **J2** (JSON), **J3** (btrfs multi-mount), **H5** (kimi).

Cada item vira um PR isolado (branch protection na `main` exige PR + checks
verdes). Atualizar `CHANGELOG.md` (Unreleased) a cada PR. Agrupar uma série
fechada numa release (ex.: H-series → v3.8.0).

## Progresso

- **Concluído:** C1–C9; M1–M8; F1–F8 (v3.6.0); G1–G4 (v3.7.0); **H1, H3, I1**
  (Rodada 1, PRs #42/#43/#44 — em `[Unreleased]`, candidatos a v3.8.0);
  **H2, H4, I2, I4, J1** (Rodada 2, em `[Unreleased]`).
- **Próximo:** Rodada 3 — **H6** (MCP), **I3** (helpers/elevação alt.), **J2**
  (JSON em report/history), **J3** (btrfs multi-mount), **H5** (kimi).
- **Restante:** H5, H6, I3, J2, J3.

---

## Achados do run real (auditoria)

Registro factual dos sinais de cada execução real, para rastrear regressões e
priorizar. Não é roadmap — é evidência.

### Audit 2026-06-20 · v3.7.0 · `--audit`

- **ALTA — CVEs em binários cargo:** `rustup` flagado (rustls-webpki/tar etc.).
  Remediação tentada (`rustup self update && rustup update`): rustup já em 1.29.0
  e toolchain `rustc 1.96.0` atual; `cargo install-update -a` → nada a atualizar.
  **Conclusão:** CVE é do binário rustup upstream (crates vendorizadas), persiste
  até upstream reconstruir — **não acionável localmente**. F7/autofix não resolve.
- **MÉDIA — Secure Boot desabilitado:** UEFI; não acionável por software.
- **INFO — fwupd HSI:3 de 4:** postura de firmware; informativo.
- **Conclusão de produto:** o audit funciona end-to-end. Próximos ganhos não vêm
  de "mais remediação Rust", e sim de **cobertura de IA/IDE e segurança Arch**
  (séries H/I acima).

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
