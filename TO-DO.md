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

#### H5 — 🟢 P ☑ Atualizar Kimi CLI (opcional/gated)
> `kimi` (Moonshot) não está instalado na máquina-alvo hoje; manter como step
> opcional para quando existir. Se for npm, já cai no `update_npm_globals`.
- **Arquivos:** `steps.d/` (custom) ou `lib/steps/ai.sh`, `lib/catalog.sh`
- **O quê:** step "Atualizar Kimi CLI" gateado por `has kimi`; usa o método de
  update apropriado ao instalador detectado.
- **Aceite:** sem `kimi` → `skip`; com → atualiza; documentado no config-example.

#### H6 — 🟡 G ☑ Doctor/Atualizar servidores MCP
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

#### I3 — 🟢 M ☑ Suporte a helpers AUR e elevação alternativos
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

#### J2 — 🟢 M ☑ Saída JSON para `--report` e `--history`
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

### Série K — Diagnóstico de ruído recorrente (achados de run real)

> Mira reduzir os `todo`/`warn` que reaparecem em todo run e não são acionáveis
> hoje. Read-only/diagnóstico; sem mutação arriscada.

#### K1 — 🔴 M ☑ Auto-update de servidores MCP — PR #61/#63 (v3.9.0/v3.9.1)
> Fecha o gancho do H6. Step mutável gateado por `MCP_AUTO_UPDATE=1`; refresca o
> cache uv dos servers uvx via `uv cache clean` (com `UV_LOCK_TIMEOUT=15` p/ não
> travar em lock contention). Ver `lib/steps/mcp.sh` + `tests/mcp.bats`.

#### K2 — 🟡 M ☑ Diagnóstico de pendências oficiais seguradas — PR #66
> **Achado recorrente:** `Verificação final de pendências` vira `todo` cru quando
> um cluster (ex.: Haskell/cabal) fica segurado por rebuild upstream, mesmo com
> `-Syu` "limpo". Distinguir *partial upgrade / held por rebuild* de pendência
> real acionável e sugerir a causa.
- **Arquivos:** `lib/steps/pacman.sh` (verificação final), catálogo.
- **Aceite:** held-por-rebuild reportado como tal (não como pendência acionável);
  pendência real continua `todo`; helper coberto por bats.

#### K3 — 🟢 P ☑ Classificar CVE de toolchain Rust não-acionável — PR #67
> `Auto-remediar`/`Auditar CVEs Rust` dá `warn` em todo run por CVE do binário
> rustup upstream (crates vendorizadas), que persiste até upstream reconstruir.
- **Arquivos:** `lib/steps/lang_rust.sh` (autofix/audit).
- **O quê:** detectar "CVE em crate vendorizada do rustup/cargo upstream" e
  rebaixar de `warn` p/ nota informativa, parando de tentar remediar o irreparável.
- **Aceite:** CVE upstream vira info, não `warn`; CVE acionável continua `warn`.

#### K4 — 🟢 P ☑ Hints acionáveis no doctor de journal — PR #68
> Erros ambientais recorrentes (ex.: `applications.menu` ausente, Bluetooth hci0)
> aparecem crus. Quando barato, sugerir correção/pacote.
- **Arquivos:** `lib/steps/doctor.sh` (journal).
- **Aceite:** padrões conhecidos ganham dica; demais inalterados.

### Série L — Experiência de uso (UX) — v3.11.0 ☑

> Mira tornar o run mais rápido de iterar e o config mais à prova de erro. Tudo
> read-only/CLI; sem novos steps mutáveis. Liberados em **v3.11.0**.

#### L1 — 🟡 P ☑ `--only` aceita nome exato e listas — PR #72
> `--only` casava só categoria/tag; agora cada token também casa o **nome exato**
> e aceita lista por vírgula. Helpers `catalog_has_step_name`/`apply_only_filter`.

#### L2 — 🔴 M ☑ `--resume` re-roda só os steps não-ok — PR #73
> Lê o jsonl do último run **real** (dry-runs marcados/ignorados), pega
> `warn`/`todo`/`fail` e re-executa só esses (+ core/final). `resume_pending_steps`/
> `resume_latest_real_jsonl`/`apply_only_names`.

#### L3 — 🟡 M ☑ Diff de pacotes pós-run ("o que mudou") — PR #74
> Snapshot `pacman -Q` antes/depois → bloco **Pacotes alterados** no resumo
> (↑ atualizados / + instalados / − removidos, cap 30) + evento jsonl `pkg_changes`.
> `pkg_diff`/`capture_installed_pkgs`/`print_pkg_changes`.

#### L4 — 🟢 P ☑ Typo-guard de chaves de config — PR #75
> Chave do config não-reconhecida e a 1–2 edições (Levenshtein) de uma válida vira
> aviso não-fatal com sugestão; `--config` ganha seção. `levenshtein`/
> `config_known_keys`/`config_assigned_keys`/`config_lint_keys`.

### Série N — Achados dos runs reais v3.11.x

> Definida a partir dos runs reais de 2026-06-21 (v3.11.0/v3.11.1). O sistema está
> em estado estável (86 ok / 1 warn / 1 todo / 0 fail). Os itens abaixo miram os
> dois únicos sinais recorrentes/reais que sobraram.

#### N1 — 🔴 P ☑ Parser arch-audit cego no formato moderno — PR #78 (v3.11.1)
> `doctor_arch_audit_cves` exigia o formato antigo (`Package … Update to V!`) →
> reportava "Sem CVEs" com 21 pacotes afetados. Fix: total via `is affected by`
> (`arch_audit_affected_count`), corrigíveis via `arch-audit -u`; corrigível→warn,
> só-sem-fix→informativo (estilo K3). `--audit` separa high/info.

#### N2 — 🟡 P ☑ Matar o `todo` recorrente do refresh MCP (lock uv) — PR #81 (v3.12.0)
> **Achado:** em **todo** run, `serena` (uvx) está em uso (a própria sessão que
> dispara o upgrade), então `uv cache clean serena` é adiado → `todo` permanente.
> É o único `todo` que reaparece sempre e não há ação prática (o MCP está sempre
> ativo durante um upgrade conduzido por agente).
- **Arquivos:** `lib/steps/mcp.sh` (`mcp_update_servers`), catálogo.
- **O quê:** quando o adiamento é por **lock de server ativo** (esperado, não
  falha), classificar como **informativo (ok)** com a dica `uv cache clean serena`,
  em vez de `todo` — mesma filosofia de K3/N1 (não criar ruído recorrente não
  acionável). Distinguir de lock por *outra* causa (aí continua `todo`).
- **Aceite:** lock por server-ativo → ok + dica; demais contenções → `todo`;
  helper de classificação coberto por bats.

#### N4 — 🔴 P ☑ `Atualizar gems de usuário` recriava o shadowing — PR #84 (v3.12.1)
> **Achado:** após o N3 remover as gems user que sombreiam o Arch, o run as
> recriou — `update_gem_user` rodava `gem update` no GEM_USER_HOME, puxando versões
> novas de gems do Arch (rdoc/rake/…) pro dir do usuário (loop infinito de todo).
> **Fix:** exclui as gems gerenciadas pelo Arch do `gem update` (helper puro
> `gem_user_updatable`); só atualiza gems próprias do usuário. Verificado no run
> real: gems step pula as do Arch, shadow fica zero, doctor_gem_shadow → ok.

#### N3 — 🟡 M ☑ Doctor: gems do usuário sombreando gems do sistema (Arch) — PR #81 (v3.12.0)
> **Achado:** o build do pacote AUR despejou dezenas de warnings Ruby
> `already initialized constant RDoc::*` — causa raiz: `rdoc 7.2.0` instalado como
> user gem sombreia o `rdoc 6.14.0` gerenciado pelo Arch (`/usr/lib/ruby/gems`).
> Várias default gems do Ruby têm cópia user duplicando a do sistema; quando a
> versão **diverge**, há skew/conflito e ruído em toda invocação ruby.
- **Arquivos:** novo helper em `lib/steps/lang_other.sh` (ou `doctor.sh`), catálogo.
- **O quê:** step doctor read-only que lista gems do usuário que **duplicam** uma
  gem gerenciada pelo Arch **com versão divergente** (duplicata de mesma versão é
  benigna e ignorada); `RC_TODO`/informativo com dica `gem uninstall --user-install <g>`.
- **Aceite:** divergência real (ex.: rdoc 7.2.0 vs 6.14.0) é listada; mesma-versão
  e gems não-Arch são ignoradas; helper puro de diff coberto por bats.

## Ordem de execução sugerida (impacto × esforço)

**Rodada 1 (alto impacto):** ✅ concluída (PRs #42/#43/#44).
1. ~~**H3** (extensões de IDE)~~ — ✅ PR #42.
2. ~~**I1** (Arch News pré-upgrade)~~ — ✅ PR #43.
3. ~~**H1** (opencode)~~ — ✅ PR #44.

**Rodada 2:** ← em andamento
4. ~~**H2** (Ollama)~~, ~~**H4** (doctor de versões IA)~~, ~~**I4** (notify)~~,
   ~~**I2** (pacnew/pacsave)~~, ~~**J1** (diagnóstico pip)~~.

**Rodada 3 (maior esforço / menor urgência):** ✅ concluída.
6. ~~**H6** (MCP)~~, ~~**I3** (helpers/elevação alt.)~~,
   ~~**J2** (JSON)~~, ~~**J3** (btrfs multi-mount)~~, ~~**H5** (kimi)~~.

**Rodada 4 — Série K (pós-v3.8.x):**
7. ~~**K1** (auto-update MCP)~~ — ✅ PR #61 (feat) + #63 (fix lock uv); v3.9.0/v3.9.1.
8. ~~**K5** (sync doc)~~ — ✅.
9. ~~**K2** (pendências seguradas)~~ #66, ~~**K3** (CVE rustup não-acionável)~~ #67,
   ~~**K4** (hints de journal)~~ #68 — ✅ todos em **v3.10.0**.

Cada item vira um PR isolado (branch protection na `main` exige PR + checks
verdes). Atualizar `CHANGELOG.md` (Unreleased) a cada PR. Agrupar uma série
fechada numa release (ex.: H-series → v3.8.0; K1 → v3.9.0).

## Progresso

- **Concluído:** C1–C9; M1–M8; F1–F8 (v3.6.0); G1–G4 (v3.7.0); H1, H3, I1
  (PRs #42/#43/#44); H2, H4, I2, I4, J1; **H5, H6, I3, J2, J3** → todos liberados
  em **v3.8.0**. Patches v3.8.1/v3.8.2. **Série K:** K1 (auto-update MCP) → v3.9.0,
  fix de lock uv → v3.9.1; K2/K3/K4/K5 → v3.10.0; fix autofix CVE Rust → v3.10.1.
  **Série L (UX):** L1 #72, L2 #73, L3 #74, L4 #75 → **v3.11.0**.
  **Série N (achados run real):** N1 (fix parser arch-audit) #78 → **v3.11.1**;
  N2 (fix `todo` recorrente MCP) + N3 (doctor gems sombreando) #81 → **v3.12.0**;
  N4 (fix gem-user-update recriava shadowing) #84 → **v3.12.1**.
- **Próximo:** série N concluída; backlog vazio. Run real v3.12.1 = **88 ok / 1
  warn / 0 todo / 0 fail / 3 skip** (0 todo pela 1ª vez). Único warn = journal,
  benigno (Bluetooth/a2dp transiente; `applications.menu` histórico deste boot,
  já corrigido — some no reboot). Novos itens só de achados de run real.
- **Restante:** nenhum item pendente no backlog.

---

## Achados do run real (auditoria)

Registro factual dos sinais de cada execução real, para rastrear regressões e
priorizar. Não é roadmap — é evidência.

### Run 2026-06-21 (K1 live) · v3.9.0→v3.9.1 · step `Atualizar servidores MCP`

- **Achado que virou patch v3.9.1:** primeiro run live do K1 classificou certo
  (14 servers: serena uvx-git = único `refresh`), mas `uv cache clean serena`
  estourou o timeout de 120s → `warn` enganoso. **Causa raiz:** lock contention,
  não lentidão — server uvx em uso (sessão Claude/Codex segura `serena`) deixa o
  lock global de `~/.cache/uv` ocupado e o uv espera `UV_LOCK_TIMEOUT` (default
  300s). **Fix:** `UV_LOCK_TIMEOUT=15` + degrada p/ `todo` em contenção; nunca
  `--force`; timeout do step 120→180s. **Verificado:** rc=11 (`todo`) em 16s.
- **Gotcha de ambiente:** cache uv do user = **22G** (uvx acumula envs).

### Run 2026-06-21 (v3.11.1, full -y tudo ativo) · 86 ok / 1 warn / 1 todo / 0 fail / 3 skip · 5m47s

- **Estado:** saudável e estável. N1 confirmado em produção (step `Doctor: CVEs de
  pacotes oficiais` agora roda e conta 21 afetados em vez de "Sem CVEs"). L3 ao
  vivo: `↑ full-upgrade 3.11.0→3.11.1`.
- **warn (journal):** 3 assinaturas — `Bluetooth hci0 0x0401 -110` (3×, transiente
  HW), `applications.menu not found` (2×, **histórico deste boot**: corrigido em
  2026-06-21 com archlinux-xdg-menu + symlink repointado; some no próximo reboot),
  `a2dp-sink busy` (1×, transiente). Nenhum acionável por código.
- **todo (MCP):** `serena` uvx em uso → refresh adiado. Recorrente → vira **N2**.
- **Achado novo → N3:** build do AUR despejou dezenas de warnings Ruby
  `already initialized constant RDoc::*`. Causa: `rdoc 7.2.0` (user gem) sombreia
  `rdoc 6.14.0` (Arch). Várias default gems do Ruby têm cópia user duplicando a do
  sistema; versão divergente = skew/ruído.
- **skips:** Snap, Bun, Kimi CLI — tools não instaladas (legítimo).

### Run 2026-06-21 15:28 · v3.8.2 · `--mode full -y`

- **Resultado:** 81 ok · 3 warn · 1 todo · 0 fail · 5 skip em **5m22s** (exit 0).
- **Contexto:** primeiro run real após ligar as chaves opt-in das séries H/I/J no
  config do usuário (`AUTO_BTRFS_SCRUB`, `AUTO_FIX_RUST_CVES`, `NOTIFY_ON_FINISH`,
  `REPORT_ON_FINISH`, `OLLAMA_SELF_UPDATE`). Todos os steps novos dispararam OK:
  "Auto-remediar scrub btrfs", "Verificar Arch News" (3s), "Atualizar Ollama"
  (18s, self-update), "Atualizar extensões de IDE", "Atualizar RTK", relatório
  `.md` gravado em `~/.cache/system-upgrade/`.
- **todo (1)** — `Verificação final de pendências`: cluster Haskell/cabal segurado
  em repositórios oficiais (cabal-install, haskell-aeson, -attoparsec-aeson,
  -bitvec, -casa-*, -cborg, …). `-Syu` rodou em 4s (sistema já corrente); held por
  rebuild upstream → não acionável localmente.
- **warn (3)** — `Auto-remediar CVEs de toolchain Rust` + `Auditar binários cargo`:
  CVE do binário rustup upstream (crates vendorizadas), rustup já atual → persiste
  até upstream reconstruir. `Doctor: journal erros críticos`: 6 erros reais (3×
  Bluetooth hci0 0x0401 -110; 2× `applications.menu` ausente; 1× a2dp-sink busy),
  2413 linhas de ruído filtradas — ambientais, fora do escopo do script.
- **Conclusão:** fluxo verde end-to-end. Sem gaps de implementação pendentes
  (roadmap H/I/J 100% liberado). Os 3 warn + 1 todo são recorrentes e não
  acionáveis por software.

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
