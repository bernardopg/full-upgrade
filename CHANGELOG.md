# Changelog

Formato baseado em [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Adicionado

- **Cabeçalhos de seção no output ao vivo.** A execução agora é dividida em
  blocos visuais (`── linha ──` + `▶▶ Grupo`) sempre que o grupo do step muda,
  reaproveitando o mesmo agrupamento do resumo final (`summary_group_specs`).
  O print fica organizado e alinhado, com a execução espelhando os blocos do
  resumo. Novo helper puro `_group_label_for_category` (com testes bats).

### Alterado

- **Burp Suite e Wireshark agora são steps independentes.** O antigo step único
  `Garantir Burp Suite e Wireshark` (`ensure_security_tools`) foi dividido em
  `Garantir Wireshark` (`ensure_wireshark`, só `wireshark-qt`) e `Garantir Burp
  Suite` (`ensure_burpsuite`, com fallback PortSwigger). Cada ferramenta tem
  agora status, timeout, tags e log próprios; um fica `warn`/`fail` sem mascarar
  o outro. Ambos seguem atrás de `ENABLE_CUSTOM_TOOLS=1`.

## [3.14.1] - 2026-06-25

### Corrigido

- **Resolução de versão (`SCRIPT_VERSION`) restaurada.** As três linhas de
  `full-upgrade.sh` carregavam o mesmo literal — o `sed` de bump do
  `release.yml` (sem isolar a linha de fallback) tinha sobrescrito os ramos que
  resolvem via `git describe` e arquivo `VERSION`, deixando-os mortos. Os ramos
  voltam a usar `$_git_ver`/`$_file_ver`; o `sed` do `release.yml` (full-upgrade.sh
  e build.sh) agora casa só o valor literal iniciado por dígito, preservando as
  linhas com variável.

## [3.14.0] - 2026-06-25

### Adicionado

- **Integração com o Orca IDE (Stably AI).** Novo step `Garantir Orca IDE`
  (`steps.d/80-orca.sh`): roda por presença do binário/pacote `stably-orca`;
  com `ENABLE_CUSTOM_TOOLS=1` instala quando ausente via helper AUR
  (`stably-orca-bin`) com fallback para AppImage do release oficial — este
  verificado por checksum SHA-256 do próprio release antes de ativar. Em todos
  os casos repara o `.desktop` do usuário e instala o ícone no
  `hicolor/512x512` local. Nova chave de config `ORCA_IDE_BIN` (override do
  binário, auto-detectado).

### Alterado

- **Ordem do fluxo: reparo de shadowing antes do upgrade base.**
  `Reparar comandos locais conflitantes` (genérico e preventivo) agora roda
  antes de `Atualizar pacotes do sistema e AUR`, não depois.
- **Reinício de serviços com libs antigas separado do doctor.**
  `Doctor: serviços com libs antigas` voltou a ser estritamente read-only
  (apenas lista as units afetadas); o reinício passou para um novo step
  mutating `Reiniciar serviços com libs antigas`, gateado por
  `--restart-services` + confirmação/`--yes`. Garante que
  `--mode doctor --restart-services` não reinicia nada.

### Removido

- **Step `Verificar Arch News` removido em definitivo.** Limpeza completa do
  que restava após a refatoração do pré-flight: `tests/arch_news.bats`,
  referências em `README.md`/`TO-DO.md` e a chave `ARCH_NEWS_CHECK`.

### Corrigido

- **Dead code em `doctor_stale_services`.** `return "$RC_TODO"` duplicado,
  indentação quebrada do bloco `RESTART_SERVICES` e variável `problems`
  declarada e nunca usada.

## [3.13.2] - 2026-06-23

### Corrigido

- **Metadados de empacotamento AUR sincronizados.** O `.SRCINFO` ficou em
  `3.13.0` após a v3.13.1, sem refletir o `pkgver` nem as novas `optdepends`
  do systray em Wayland (`python-gobject`, `libayatana-appindicator`) e o texto
  atualizado do `yad`. Regenerado a partir do `PKGBUILD` (`makepkg
  --printsrcinfo`); agora bate byte a byte.
- **Desktop entry do systray sem categoria duplicada.** `Categories` deixa de
  incluir `Utility;` junto de `System;`, eliminando o aviso de
  `desktop-file-validate` (a aplicação podia aparecer duas vezes no menu).
- **Documentação interna (`CLAUDE.md`) atualizada.** A lista de domínios de
  steps passou a incluir `audit`, `backup`, `ide`, `mcp`, `news` e
  `self_update`, que já existiam em `lib/steps/` mas não estavam documentados.

## [3.13.1] - 2026-06-23

### Corrigido

- **Systray agora aparece em Hyprland/DankMaterialShell (Wayland).** O backend
  anterior dependia de `yad --notification`, que aborta fora de X11 com
  `WARNING: This mode not supported outside X11`; o daemon ficava vivo, mas sem
  `StatusNotifierItem` para a barra. Em Wayland o tray agora usa AppIndicator via
  Python/GI (`python-gobject` + `libayatana-appindicator`) e mantém `yad` como
  fallback X11.
- **Daemon não considera `yad` com PID vazio como vivo.** Se o backend gráfico não
  inicializar, `--tray` falha de forma explícita em vez de ficar em background sem
  ícone. Cobertura adicionada em `tests/tray.bats` para seleção Wayland e PID do
  backend.
- **Unit systemd user sem chave inválida.** Remove `Description[pt_BR]`, que o
  systemd ignorava com warning.

## [3.13.0] - 2026-06-23

### Adicionado

- **Systray daemon opcional (`--tray`) inspirado no arch-update, mantendo Bash puro.**
  Novo `lib/tray.sh` implementa applet de bandeja com `yad --notification --listen`,
  sem Python/Qt e sem artefato compilado. O estado é persistido em
  `~/.cache/system-upgrade/tray-state.json` e segue a prioridade
  `running > error > attention > updates > idle`: detecta run em andamento pelo
  lock do full-upgrade, falhas/todos pelo último `latest.jsonl`, e updates por
  `checkupdates` + helper AUR. O clique esquerdo abre `full-upgrade` em terminal;
  o menu inclui fluxo completo, Doctor, verificar agora, último log e sair.
  Novas flags: `--tray`, `--tray --enable|--disable|--status|--check`,
  `--tray-launch` e `--tray-view-log`.

- **Ícones e integração desktop do systray.** SVGs em `assets/icons/` cobrem o
  ícone base e os estados `idle`, `updates`, `attention`, `running` e `error`.
  `install.sh` agora instala os ícones no diretório da aplicação e no tema
  hicolor, além de instalar o desktop entry em `~/.local/share/applications` e a
  unit systemd user em `~/.config/systemd/user`. O pacote AUR passa a instalar os
  mesmos ícones, desktop entry e unit systemd em paths de sistema.

- **Configurações do systray.** `TRAY_CHECK_INTERVAL_M` controla o intervalo de
  checagem, `TRAY_TERMINAL` permite fixar o terminal usado pelo applet, e
  `TRAY_NOTIFICATIONS` liga/desliga notificações de transição (`updates`,
  `attention`, `error`, retorno a `idle`). Helpers puros do tray têm cobertura
  em `tests/tray.bats` (+20 testes).

## [3.12.1] - 2026-06-21

### Corrigido

- **`Atualizar gems de usuário` recriava o shadowing da stdlib (N4).** O step
  rodava `gem update` no `GEM_USER_HOME`, puxando versões novas de gems que o
  Arch já gerencia (rdoc, rake, minitest, rbs…) para o dir do usuário — exatamente
  o shadowing que o `doctor_gem_shadow` (N3) sinaliza, recriado a cada run (e com
  o flood `already initialized constant`). Agora o step **exclui as gems
  gerenciadas pelo Arch** do `gem update`, atualizando só as gems próprias do
  usuário; se todas as desatualizadas forem do Arch, pula com aviso (use pacman).
  Helper puro `gem_user_updatable`; +5 testes.

## [3.12.0] - 2026-06-21

### Adicionado

- **`Doctor: gems do usuário sombreando o sistema` (N3).** Novo step doctor
  read-only que detecta gems instaladas pelo usuário (`~/.local/share/gem`) que
  **sombreiam uma gem real gerenciada pelo Arch** com versão divergente — ex.:
  `rdoc 7.2.0` (user) sobre `6.14.0` (Arch), que faz toda invocação ruby carregar
  a do usuário e despejar `already initialized constant RDoc::*`. Gems default do
  Ruby (`default: X`) são ignoradas (upgrades de usuário nelas são normais);
  sinaliza só divergência real. `RC_TODO` acionável com dica
  `gem uninstall --user-install <gem>`. Helper puro `gem_shadow_diff`; +7 testes.

### Corrigido

- **`todo` recorrente do refresh MCP por lock do cache uv (N2).** Quando o
  `uv cache clean` é adiado porque um server uvx está **ativo** (a própria sessão
  que dispara o upgrade mantém o serena vivo, segurando o lock global), isso é
  esperado e sem ação prática — agora vira **informativo (ok)** em vez de `todo`,
  com a dica `uv cache clean <dist>` para rodar com os MCP ociosos. Erro do uv por
  **outra** causa continua `RC_WARN`. Helper puro `mcp_uv_lock_busy`; testes
  atualizados. Mata o único `todo` que reaparecia em todo run.

## [3.11.1] - 2026-06-21

### Corrigido

- **`Doctor: CVEs de pacotes oficiais` cego no arch-audit moderno (N1).** O parser
  exigia o formato antigo do `arch-audit` (prefixo `Package …` + marcador
  `Update to V!`); o `arch-audit` atual emite `<pkg> is affected by <tipo>. <risco>
  risk!` e indica corrigíveis pelo flag `-u`, não no texto. Resultado: o step
  reportava "Sem CVEs" mesmo com dezenas de pacotes afetados (verificado: 0 contados
  vs 21 reais). Agora o total vem de `is affected by` (aceita os dois formatos) e os
  corrigíveis de `arch-audit -u`. Corrigível → `RC_WARN` (acionável, `pacman -Syu`);
  só sem correção upstream → informativo (return 0, como os CVEs de toolchain Rust
  do K3 — sem virar todo/warn recorrente), mas a contagem é exibida. O `--audit`
  consolidado também separa corrigível (high) de sem-correção (info). Helper puro
  `arch_audit_affected_count` (substitui `parse_arch_audit`); testes atualizados.

## [3.11.0] - 2026-06-21

### Adicionado

- **Typo-guard de chaves de config (L4).** Ao carregar o config, chaves
  atribuídas que não são reconhecidas mas estão a 1–2 edições (Levenshtein) de
  uma chave válida viram aviso não-fatal em stderr — ex.: `ENABLE_CUSTOM_TOOL`
  → "talvez `ENABLE_CUSTOM_TOOLS`?". Variáveis legítimas do usuário (sem
  near-miss) e identificadores curtos são ignorados; nunca bloqueia o run.
  `--config` ganhou uma seção **Chaves não reconhecidas** com as mesmas
  sugestões. Helpers puros `levenshtein`/`config_known_keys`/
  `config_assigned_keys`/`config_lint_keys`; +12 testes.

- **Resumo "o que mudou": diff de pacotes pós-run (L3).** O run captura
  `pacman -Q` antes do upgrade e no fim, e mostra no resumo um bloco **Pacotes
  alterados** com contagem (atualizados/instalados/removidos) e a lista: cada
  atualizado como `nome velha → nova`, instalados com `+`, removidos com `−`
  (capada em 30, restante no log). Inclui mudanças de pacman e AUR e também o que
  a limpeza de órfãos removeu. Evento jsonl `pkg_changes` com as contagens.
  No-op sob `--dry-run` ou sem pacman. Helpers puros `pkg_diff`/
  `capture_installed_pkgs`/`print_pkg_changes`; +3 testes.

- **`--resume`: re-roda só os steps que não fecharam ok no último run (L2).** Lê o
  jsonl do run **real** mais recente (ignora dry-runs, agora marcados com
  `"dry_run"` no evento de run), coleta os steps com status `warn`/`todo`/`fail` e
  re-executa apenas esses (+ core/final). Sem pendências → sai sem rodar. Enorme
  para iteração: depois de um run com 1 todo, `full-upgrade --resume` toca só
  aquele. Helpers `resume_pending_steps`/`resume_latest_real_jsonl`/
  `apply_only_names`; banner mostra `[RESUME]`; +4 testes.

- **`--only` aceita nome exato de step e listas (L1).** Antes `--only` só casava
  categoria/tag; agora cada token também casa o **nome exato** de um step, e
  aceita lista por vírgula. Ex.: `--only "Atualizar Ollama"`,
  `--only "lang,Doctor: saúde de rede"`. core/final continuam sempre rodando.
  Helpers puros `catalog_has_step_name` e `apply_only_filter` (substitui
  `apply_only_category` no caminho do `--only` do usuário); +5 testes.

## [3.10.1] — 2026-06-21

### Corrigido

- **`Auto-remediar CVEs de toolchain Rust` também classifica CVE não-acionável
  (K3).** Run real do v3.10.0 mostrou que o K3 cobriu o step de auditoria
  (`Auditar binários cargo` → `ok`), mas o step de auto-remediação ainda dava
  `warn` na mesma CVE irreparável do `rustup` upstream. Agora, após a remediação
  (que já roda `rustup update`), CVEs remanescentes restritas a binários da
  toolchain viram nota informativa (`ok`); só restam `warn` quando há CVE
  remanescente em binário cargo-installed (de fato acionável). +1 teste, e o caso
  toolchain-remanescente passou a esperar `ok`.

## [3.10.0] — 2026-06-21

### Adicionado

- **Dicas acionáveis no `Doctor: journal erros críticos` (K4).** Para assinaturas
  de erro ambientais recorrentes, o doctor agora imprime uma dica curta abaixo do
  agrupamento: menu XDG ausente (`applications.menu` → instalar `archlinux-xdg-menu`
  + `kbuildsycoca`), Bluetooth/áudio transitório (hci0/a2dp-sink) e falha de
  autenticação sudo/PAM. Read-only, sem mudar o RC do step; assinaturas
  desconhecidas seguem sem dica. Helper puro `journal_hint_for`; +4 testes.

### Alterado

- **CVEs de toolchain Rust não-acionáveis viram nota, não `warn` (K3).** Achado
  recorrente: `Auditar binários cargo` dava `warn` em todo run por CVEs no
  binário `rustup` upstream (crates vendorizadas), que persistem até o upstream
  reconstruir — irreparável localmente. Quando as CVEs estão restritas a binários
  da toolchain (rustup/cargo/rustc), sem nenhum binário cargo-installed
  acionável, e `rustup check` confirma que já está na última versão, o step agora
  rebaixa para nota informativa (`ok`) em vez de `warn`. CVEs em binários
  cargo-installed (atualizáveis via `cargo install-update`) ou com update de
  rustup pendente continuam `warn`. Helper puro `rustup_check_has_update`;
  `tests/lang_rust.bats`.
- **`Verificação final de pendências` distingue cluster segurado por rebuild (K2).**
  Achado recorrente: pacotes do cluster Haskell/GHC reaparecem como pendência
  "oficial" em todo run mesmo após `-Syu` limpo, porque o pacman evita o partial
  upgrade até o cluster inteiro publicar — não são acionáveis (rodar `-Syu` de
  novo não os sobe). O step agora separa esses pacotes (helper puro
  `pending_is_held_cluster`): lista-os como segurados por rebuild upstream (não
  acionável) e só vira `todo` quando há pendência **acionável** de fato. Se só
  restam pacotes segurados, o step fecha em `ok`. +2 testes em
  `tests/m_improvements.bats`.

## [3.9.1] — 2026-06-21

### Corrigido

- **Auto-update MCP (K1) não trava no lock do cache uv.** Achado de run real: com
  servers uvx em uso (sessão Claude/Codex ativa, ex.: `serena`), `uv cache clean`
  fica esperando o lock global de `~/.cache/uv` por `UV_LOCK_TIMEOUT` (default
  300s) e estourava o timeout do step (rc 124 → `warn` enganoso). Agora o step
  roda `uv cache clean` com `UV_LOCK_TIMEOUT=15` (falha rápido) e degrada para
  `todo` com a contenção de lock detectada — sugerindo rodar `uv cache clean
  <pkgs>` quando os servers estiverem ociosos. Nunca usa `--force` (corromperia o
  cache de um processo vivo). Timeout do catálogo do step subiu 120→180s. +2
  testes (lock→todo, erro genérico→warn).

## [3.9.0] — 2026-06-21

### Adicionado

- **Auto-update de servidores MCP (K1).** Novo step mutável "Atualizar servidores
  MCP" (`ai`/`mutating`), gateado por `MCP_AUTO_UPDATE=1` e pela presença de uma
  fonte MCP (`~/.claude.json` / `~/.codex/config.toml`). Fecha o gancho deixado
  pelo H6 (até então `MCP_AUTO_UPDATE` era reservado/no-op). Um planner puro
  (`mcp_update_plan`) classifica cada servidor pela ação de atualização real:
  `fresh` (npx/bunx/pnpm dlx sem versão fixa — já resolve a última a cada run),
  `refresh` (runtime uvx com ambiente em cache ou origem git, que defasa em
  silêncio), `pinned` (versão explícita `pkg@1.2.3`/`==`), `external` (binário
  global/node/script — atualiza pela própria toolchain) e `remote` (HTTP/SSE).
  Só os `refresh` são tocados, via `uv cache clean <dist>` (operação local, sem
  rede, nunca muta pacote do sistema), forçando o rebuild da última versão no
  próximo launch do servidor. Sem alvos uvx → `ok`; com alvos uvx mas sem `uv`
  → `todo` ("instalar uv"). Cobre Claude e Codex, com dedup global>projeto.
  Suíte `tests/mcp.bats` ampliada (+11 casos: classificação por runtime e o
  fluxo do step com `uv` presente/ausente).

## [3.8.2] — 2026-06-21

### Corrigido

- **Doctor MCP não lista subtabelas `.env` como servidores.** O parser do Codex
  agora lê `~/.codex/config.toml` via TOML real (`tomllib`) e enumera só as chaves
  diretas de `mcp_servers`, evitando falsos positivos como `notionApi.env`.
- **npm global sinaliza scripts de install bloqueados.** Quando o npm emite
  `npm warn allow-scripts`, o step "Atualizar npm global" retorna `todo` com
  remediação explícita, em vez de tratar a instalação como totalmente OK.

## [3.8.1] — 2026-06-21

### Corrigido

- **Auto-update (`full-upgrade -u`) resiliente a falha da API GitHub.** Se
  `api.github.com/repos/<repo>/releases/latest` retornar 5xx/rate-limit, o
  detector de última release agora cai para o redirect público
  `github.com/<repo>/releases/latest` e extrai a tag final (`/releases/tag/vX`).
  Isso evita o erro "Não foi possível consultar a última release (rede/API)" em
  cenários onde a API falha mas o GitHub/release está acessível.

## [3.8.0] — 2026-06-21

### Adicionado

- **Doctor: servidores MCP (H6).** Novo step read-only "Doctor: servidores MCP"
  que enumera servidores MCP configurados em Claude Code (`~/.claude.json`) e
  Codex (`~/.codex/config.toml`), agregando nomes repetidos entre fontes e
  mostrando escopo/runtime (`stdio:npx`, `stdio:uvx`, `remote`, etc.). Útil para
  identificar MCP servers npm/uvx que ficam defasados fora do update padrão.
  `MCP_AUTO_UPDATE` foi reservado (default `0`) para futura remediação mutável;
  hoje o step só diagnostica. Parsers puros `parse_mcp_claude_json` e
  `parse_mcp_codex_names`; suíte `tests/mcp.bats`.
- **Helpers AUR e elevação de privilégio alternativos (I3).** O full-upgrade
  agora autodetecta (ou aceita via config) o `AUR_HELPER` (paru > yay > pikaur)
  e o `PRIV_CMD` (sudo > doas > sudo-rs > run0). Com só `yay` (ou `pikaur`)
  instalado, o fluxo de update o usa; com `doas`, toda a elevação passa por ele
  via um **shim** `sudo()` que delega para `$PRIV_CMD` — os diagnósticos do
  doctor e as mutações do pacman continuam chamando `sudo <cmd>` e funcionam sob
  doas/sudo-rs sem refactor. Removido o `cmd_dep=paru` do step de update (que
  causava skip silencioso em máquinas só-yay). Helpers puros `detect_aur_helper`/
  `detect_priv_cmd` e suíte `tests/i3_helpers.bats`. Inspirado no
  [arch-update](https://github.com/Antiz96/arch-update).
- **Saída JSON para `--report` e `--history` (J2).** `--report --json` agora emite
  um objeto JSON estruturado (run_id, versão, início/fim, duração, summary e
  array de steps com status/duração/reason) em vez de Markdown; `--history --json`
  emite `{"runs":[...]}` em vez da tabela. Reaproveita os mesmos extratores awk do
  Markdown com re-escape correto de strings (aspas, contrabarra, controle). Sem
  `--json`, Markdown/tabela permanecem inalterados. Helpers puros
  `report_json_from_jsonl` + helper de teste `assert_json`; +6 testes.
- **Atualizar Kimi CLI — ciente da origem npm (H5).** Novo step "Atualizar Kimi
  CLI" (`ai`/`mutating`, gateado por `has kimi`). O Kimi (Moonshot) é publicado
  como `@moonshot-ai/kimi-code` no npm (bin `kimi`), então quando instalado via
  npm global **já é coberto por "Atualizar npm global"** — este step detecta a
  origem e apenas confirma a cobertura (evita duplicar o `npm install`);
  instalações standalone futuras → `RC_TODO`. Helper `kimi_npm_package` e suíte
  `tests/kimi.bats`.
- **Scrub btrfs em múltiplos mountpoints (J3).** O step "Auto-remediar scrub
  btrfs" agora avalia TODOS os filesystems btrfs montados (não só `/`),
  enumerando-os via `findmnt -t btrfs` e aplicando a mesma lógica de G1 a cada
  um. Subvolumes do mesmo dispositivo são dedupados (scrub é por-device) para
  evitar trabalho redundante; confirmação única para todos os pendentes. Helpers
  `unique_btrfs_mountpoints` (puro, testável) e `list_btrfs_mountpoints`; +6
  testes em `tests/btrfs_scrub.bats`.
- **Doctor: arquivos .pacnew/.pacsave (I2).** Novo step read-only "Doctor:
  arquivos .pacnew/.pacsave" que localiza configs pendentes de mesclagem
  (geradas pelo pacman) em `PACFILES_DIRS` (default `/etc /boot`); `todo` se
  houver, sugerindo `sudo pacdiff` (ou instalar `pacman-contrib`). Helper isolado
  `pacfiles_find` e suíte `tests/pacfiles.bats`. Inspirado no
  [arch-update](https://github.com/Antiz96/arch-update).
- **Atualizar Ollama (H2).** Novo step "Atualizar Ollama" (`ai`/`mutating`). O
  ollama vive em `/usr/local/bin` (instalador próprio), fora do pacman/npm. Por
  padrão só reporta a versão; sob `OLLAMA_SELF_UPDATE=1` reexecuta o instalador
  oficial (`curl -fsSL https://ollama.com/install.sh | sh`). Sem rede ou falha do
  instalador → `warn`; sem `ollama` → `skip`. Helper puro `parse_ollama_version`
  e suíte `tests/ollama.bats`.
- **Notificação desktop ao fim do run (I4).** Nova chave `NOTIFY_ON_FINISH`
  (default `0`). Quando `1` e `notify-send` presente, `finalize()` envia o resumo
  (ok/warn/todo/fail/skip) com urgência conforme o pior status (fail→critical,
  todo→normal, senão low). Nunca derruba o run. Helpers puros `_notify_counts`/
  `notify_body` em `lib/notify.sh` e suíte `tests/notify.bats`. Inspirado no
  [arch-update](https://github.com/Antiz96/arch-update).
- **Atualizar opencode (H1).** Novo step "Atualizar opencode" (`ai`/`mutating`)
  que atualiza o opencode via seu instalador próprio (`opencode upgrade`) — ele
  vive em `~/.opencode/bin`, fora do npm, então não era coberto pelo update de
  globais. Loga versão antes/depois. Falha de rede ou do upgrade → `warn`
  (não-fatal); sem `opencode` → `skip`. Coberto por `tests/opencode.bats`.
- **Checagem de Arch News antes das mutações (I1).** Novo step read-only
  "Verificar Arch News" que roda antes do `-Syu`: busca o feed RSS oficial
  (`https://archlinux.org/feeds/news/`) e alerta (`todo`) sobre itens novos desde
  a última verificação, listando título e data — Arch publica intervenções
  manuais necessárias antes de atualizar. Modelo "reconhece ao rodar" (persiste o
  epoch do item mais novo em `~/.cache/system-upgrade/arch-news-last`). Config
  `ARCH_NEWS_CHECK` (default `1`); sem `curl` → `skip`; sem rede → `warn`. Helper
  puro `parse_arch_news_rss` e suíte `tests/arch_news.bats`. Inspirado no
  [arch-update](https://github.com/Antiz96/arch-update).
- **Atualizar extensões de IDE da família VSCode (H3).** Novo step "Atualizar
  extensões de IDE (VSCode/Cursor)" (`editor`/`mutating`) que roda
  `<cli> --update-extensions` para cada IDE presente (`code`, `cursor`, `codium`,
  `code-insiders`, `vscodium`). Os binários já vêm do pacman/AUR, mas as
  extensões ficavam defasadas em silêncio. Lista de CLIs configurável via
  `IDE_EXT_CLIS` (default autodetect). Falha de rede num CLI → `warn`; nenhum IDE
  presente → `skip`. Helper puro `count_ext_updates` e suíte `tests/ide_ext.bats`.

### Alterado

- **Doctor: diagnóstico acionável de `pip check` quebrado (J1).** O step
  "Doctor: ambiente Python" agora resume os conflitos agrupados por pacote raiz
  (em vez do dump bruto), preserva versões com ponto e specs PEP 440 multi-bound
  (`>=1.0,<2.0`), classifica cada conflito por origem (`[pacman/AUR]` vs
  `[pip --user]`) via `importlib.metadata` e sugere remediação direcionada —
  inclusive o alerta **"NÃO use 'pip install' sobre pacote do sistema"** (quebra
  o pacman). Continua `warn`, sem auto-instalação. Fallback ao dump bruto se o
  parser não casar. Helpers `summarize_pip_check` (puro) e `_classify_pip_origins`
  + suíte `tests/pip_check.bats`.
- **Doctor: AI CLIs agora cobre o conjunto moderno (H4).** O step "Doctor: AI
  CLIs" passou de claude/copilot/hermes para um inventário data-driven read-only
  de claude, copilot, codex, gemini, qwen, cline, opencode, 9router, ollama, kimi
  e hermes, reportando a versão de cada um instalado e a contagem total. CLIs
  ausentes são omitidas (menos ruído); nunca falha o run. Helper puro
  `_ai_cli_first_version` e suíte `tests/doctor_ai_clis.bats`.

## [3.7.0] — 2026-06-20

### Adicionado

- **`--audit --report [ARQ]` — auditoria de segurança em Markdown (G4).** Quando
  `--report` acompanha `--audit`, o relatório de segurança (por severidade, com
  remediação) é emitido em Markdown — gravado em `ARQ` ou no stdout — em vez do
  relatório de run. `--audit` sozinho mantém a saída de texto colorida; `--json`
  segue disponível. Novo formatador puro `audit_report_markdown` (sem ANSI),
  coberto por `tests/audit.bats`.
- **Relatório Markdown automático ao fim do run (G3).** Nova chave de config
  `REPORT_ON_FINISH` (default `0`). Quando `1`, `finalize()` grava o relatório do
  run recém-concluído em `~/.cache/system-upgrade/full-upgrade-<run_id>.md`
  (mesmo conteúdo de `--report`), reaproveitando o JSONL do run. Nunca derruba o
  run: falhas apenas logam. Coberto por `tests/report_on_finish.bats`.
- **CVEs de pacotes oficiais no fluxo padrão via arch-audit (G2).** Novo step
  read-only "Doctor: CVEs de pacotes oficiais (arch-audit)" que roda no fluxo
  normal/`--mode doctor` (não só em `--audit`). Classifica os achados: pacotes
  com correção disponível → `warn` citando `sudo pacman -Syu`; apenas sem
  correção ainda → `todo`; nenhum → `ok`. Falha de rede ao consultar o tracker
  → `warn`. Sem `arch-audit` instalado o step é pulado (`cmd-ausente`). Helper
  puro `parse_arch_audit` e suíte `tests/arch_audit.bats`.
- **Auto-remediação opcional de scrub btrfs (G1).** Novo step "Auto-remediar
  scrub btrfs" (categoria `repair`, efeito `mutating`), atrás da chave de config
  `AUTO_BTRFS_SCRUB` (default `0`). Quando ligado e o scrub em `/` está ausente
  ou mais antigo que `BTRFS_SCRUB_MAX_DAYS`, oferece iniciar `btrfs scrub start /`
  (não-bloqueante) sob confirmação interativa ou `--yes`. Nunca roda sob
  `--mode doctor`, `--dry-run` ou `--no-repair`. Sem sudo sem prompt ou recusa/
  não interativo → `todo`; falha ao iniciar → `warn`. Helper puro
  `btrfs_scrub_state` e suíte `tests/btrfs_scrub.bats`.

### Corrigido

- **Parsing de data do scrub btrfs sob locale não-inglês.** `doctor_btrfs_health`
  (e o novo G1) agora invocam `btrfs scrub status` e `date -d` sob `LC_ALL=C`;
  antes, em ambientes pt_BR, a data localizada ("qui jun ...") não era reparseada
  e a idade do scrub caía silenciosamente em "indeterminada".

## [3.6.0] — 2026-06-20

### Adicionado

- **Flag `--report [ARQ]` — relatório Markdown de um run (F2).** Gera, a partir
  do JSONL já gravado em `~/.cache/system-upgrade/`, um relatório legível:
  cabeçalho (versão, início/fim, duração, resultado, log), tabela de steps
  (status/tempo/motivo) e seções de Falhas/Pendências/Avisos. Sem argumento
  imprime no stdout; com argumento grava no arquivo. `--from RUN_ID` escolhe o
  run (default: o último; aceita prefixo do run_id). Read-only, sai sem rodar o
  upgrade. Nova lib `lib/report.sh` com parser de JSONL em awk (sem dependência
  de `jq`) e suíte `tests/report.bats`.
- **Flags `--fail-fast` / `--continue-on-fail` — política ao primeiro fail (F5).**
  Com `--fail-fast`, o run aborta no primeiro step com status `fail`: os steps
  restantes viram `skip` com motivo `abortado por --fail-fast` (útil em CI ou
  execução manual). `--continue-on-fail` torna explícito o comportamento padrão
  (segue após falhas). O `fail` continua sendo o único status que afeta o
  exit code (2). Coberto por `tests/fail_fast.bats`.
- **Auto-remediação opcional de CVEs de toolchain Rust (F7).** Novo step
  "Auto-remediar CVEs de toolchain Rust", atrás da chave de config
  `AUTO_FIX_RUST_CVES` (default `0`). Quando ligado, audita os binários cargo,
  classifica os vulneráveis em toolchain (rustup/rustc/…) vs cargo-installed e,
  sob confirmação interativa ou `--yes`, aplica `rustup self update && rustup
  update` e `cargo install-update -a`, re-auditando e reportando antes→depois.
  Efeito `mutating` no catálogo: nunca roda sob `--mode doctor`, `--dry-run` ou
  `--no-repair`. Sem rede → `warn`; recusa/não interativo sem `--yes` → `todo`;
  CVEs remanescentes → `warn`. Coberto por `tests/lang_rust_autofix.bats`.
- **Flag `--history [N]` — tendência dos últimos N runs (F8).** Lê os JSONL
  rotacionados em `~/.cache/system-upgrade/` (default N=10) e imprime uma tabela
  por run (data, versão, ok/warn/todo/fail/skip, duração), a tendência de
  duração do run mais recente vs. o anterior e os warns/todos recorrentes (steps
  que aparecem em ≥2 runs). Read-only, sem rede, sai sem rodar o upgrade. Nova
  lib `lib/history.sh` com parser de JSONL em awk e suíte `tests/history.bats`.
- **Flag `--audit` — auditoria de segurança consolidada (F6).** Roda só checks
  read-only de segurança e emite um relatório único agrupado por severidade
  (alta/média/baixa/info) com remediação por item: CVEs de binários cargo
  (cargo-audit) e de pacotes oficiais (arch-audit, se houver), postura de
  firmware HSI (fwupd), Secure Boot, units systemd falhadas, erros de
  autenticação no journal e dependências pip quebradas. Não-mutável (como
  doctor), sai sem rodar o upgrade. `--audit --json` adiciona uma seção
  `{"event":"audit",...}` com findings e contagens. Nova lib
  `lib/steps/audit.sh` e suíte `tests/audit.bats`.

## [3.5.0] — 2026-06-19

### Adicionado

- **Novo step "Atualizar Bun".** Atualiza o runtime Bun via `bun upgrade`. Pula
  com aviso quando o binário é gerenciado pelo sistema (ex.: `/usr/bin/bun` do
  pacman, não-gravável) em vez de tentar e falhar com `EACCES` — nessas
  instalações a atualização fica a cargo do `pacman -Syu`. Catalogado (dep `bun`,
  timeout 120s).
- **Novo step "Atualizar Deno".** Análogo ao de Bun: roda `deno upgrade` e pula
  quando a instalação é root/pacman. Catalogado (dep `deno`, timeout 120s).
- **Novo step "Limpar cache de build do AUR".** Remove artefatos de build
  (`src/`, `pkg/`, `*.pkg.tar.*`, fontes baixadas) acumulados por `paru`/`yay`
  em `~/.cache` — que crescem sem limite (dezenas de GB). Preserva o clone git
  (`PKGBUILD`/`.SRCINFO`/`.git`) para o helper reaproveitar em vez de re-clonar.
  Não exige sudo. Catalogado (timeout 120s, despachado quando `paru` ou `yay`
  está presente; honra `--no-cleanup`).
- **Testes unitários** (bats) para os novos helpers: `npm_global_writable`,
  `npm_audit_prefix` e `cleanup_aur_cache` (preserva `PKGBUILD`/`.git`, remove
  artefatos, lida com cache ausente).

### Corrigido

- **Steps npm não falham mais com `EACCES` quando o prefixo global é `/usr`
  (pacman).** `update_npm_self`, `update_npm_globals` e `update_corepack` agora
  pulam com aviso quando o diretório de instalação global do npm não é gravável
  pelo usuário (caso do pacote `npm` do Arch em `/usr/lib/node_modules`). Antes,
  nesses ambientes o step tentava `npm install -g` e falhava com erro de
  permissão — o que ocorria, por exemplo, ao rodar o full-upgrade num shell
  mínimo (cron, `hyprctl exec`, CI) sem `NPM_CONFIG_PREFIX`.
- **Doctor: detecção do `xdg-desktop-portal` corrigida.** O binário vive em
  `/usr/lib/` (fora do `PATH`), então `has`/`command -v` davam falso-negativo de
  "não instalado"; e o nome do processo é truncado em 15 chars
  (`xdg-desktop-por`), o que fazia `pgrep -x` com o nome completo não casar. Agora
  detecta por arquivo/pacote (`/usr/lib/xdg-desktop-portal`, `pacman -Qq`) e
  checa execução por `pgrep -f` + nome truncado.

## [3.4.0] — 2026-06-19

### Adicionado

- **Integrações `steps.d/` agora são empacotadas e embutidas no standalone/AUR.**
  O `build.sh` inlina os arquivos `steps.d/*.sh` no distribuível single-file, então
  o pacote AUR passa a trazê-las de fábrica (antes só a instalação modular via
  `install.sh` as tinha; o binário AUR pulava todas com mensagem enganosa).

### Alterado

- **Integrações rodam por presença da ferramenta, sem flag.** Hermes, AdGuard VPN,
  GitHub Copilot, DankMaterialShell, OpenClaw e RTK agora são despachadas como os
  steps core (rodam se a ferramenta existir, `skip` caso contrário) — não exigem
  mais `ENABLE_CUSTOM_TOOLS=1`.
- **`ENABLE_CUSTOM_TOOLS` tem escopo reduzido.** Passa a controlar apenas (a)
  Burp/Wireshark, que **instala** o pacote `burpsuite` e por isso não deve rodar
  por padrão, e (b) o carregamento de plugins do usuário em
  `~/.config/full-upgrade/steps.d/`. As integrações empacotadas são sempre
  carregadas (código vetado do repositório).
- Headers dos `steps.d/` normalizados e documentação (README, `config.example`)
  atualizada com o novo modelo de ativação e os overrides `RTK_BIN`/`BURPSUITE_JAVA_BIN`.

### Corrigido

- **Mensagem de `skip` enganosa em steps opt-in.** `custom_step_or_skip` agora
  distingue "requer ENABLE_CUSTOM_TOOLS=1" de "função não carregada de steps.d/",
  em vez de sempre culpar `ENABLE_CUSTOM_TOOLS=0`.

## [3.3.0] — 2026-06-19

### Adicionado

- **Novo step "Atualizar RTK".** Atualiza o RTK (Rust Token Killer) a partir da
  release publicada no GitHub: descobre a última tag pelo redirect de
  `/releases/latest`, só atualiza se a versão local estiver desatualizada, baixa
  o tarball do alvo (`uname -m`: `x86_64-unknown-linux-musl` /
  `aarch64-unknown-linux-gnu`) com `checksums.txt`, **verifica o sha256 (recusa
  instalar binário não verificado)** e substitui o binário no diretório atual.
  Step custom (`steps.d/70-rtk.sh`), duplo-gated por `ENABLE_CUSTOM_TOOLS`,
  catalogado (dep `curl`, timeout 180s).

### Documentação

- README, `config.example`, `CONTRIBUTING.md` e `TO-DO.md` alinhados às
  correções C3–C9: órfãos recursivos, checagem parcial de `systemd --user`,
  fallback seguro de mirrorlist, agrupamento do resumo, timeout Docker e ignore
  efetivo de `poetry-core`.

### Corrigido

- **Melhorias M2–M8 concluídas.** Adicionada retenção de snapshots antigos do
  próprio `full-upgrade`, tempos por grupo e top 3 mais lentos no resumo,
  agregação `category_totals`/`slowest_steps` no `--json`, helper comum de
  comparação de versões, remediações padronizadas, motivo/remediação explícitos
  para pendências oficiais finais, supressão allow-listed de warnings ruidosos
  de build no terminal mantendo log bruto, e rodapé destacado de reboot
  recomendado quando kernel/systemd requer reinício.

- **Remoção de órfãos agora é recursiva e limitada.** `cleanup_orphans` repete
  `pacman -Qdtq` após cada remoção até estabilizar, com limite configurável
  (`ORPHAN_CLEANUP_MAX_ROUNDS`, default 5) e aviso se ainda sobrar lixo.
- **Doctor de systemd não mascara mais escopo `--user` indisponível.** Quando
  não há `XDG_RUNTIME_DIR`/bus de sessão, a checagem parcial é logada
  explicitamente em vez de afirmar "sistema/usuário".
- **Fallback de mirrorlist só restaura backup válido.** Em falha do
  `reflector`/`rate-mirrors`, o backup precisa conter linha `Server =` ativa;
  backup vazio/comentado não sobrescreve a mirrorlist atual.
- **Resumo final não joga Flatpak/Docker/Snap no bloco Doctor.** O agrupamento
  agora usa especificações de grupo e cobre todas as categorias do catálogo.
- **Resumo final não duplica o header "Shell / Editor".** Categorias `editor` e
  `shell` são renderizadas no mesmo bloco.
- **Docker inacessível não segura mais o run por ~75s.** A checagem inicial de
  `docker info` agora roda com timeout curto configurável (`DOCKER_INFO_TIMEOUT_S`,
  default 5s) e pula rapidamente quando o daemon não responde.
- **`poetry-core` não entra mais no update genérico do pip --user quando Poetry
  fixa uma versão exata.** O step calcula o ignore efetivo e evita o ping-pong
  `poetry-core` 2.4.0→2.4.1→2.4.0 no mesmo run.
- **`pip --user` não quebra mais constraints de deps transitivas.**
  `update_pip_user` atualiza apenas pacotes top-level (`pip list --not-required`)
  e deixa o resolver subir as deps dentro da faixa permitida pelo pai. Antes,
  subir uma dep isoladamente via `--upgrade` (ex.: `chardet`) furava a constraint
  do pacote pai (ex.: `pygount` exige `chardet<6`) e deixava `pip check` quebrado.
- **Imagens Docker de registry com porta classificadas corretamente.**
  `_docker_is_remote_image` passa a cortar só a tag (`${img%:*}`); antes
  `${img%%:*}` cortava no primeiro `:` e tratava `localhost:5000/app` como local,
  pulando o `docker pull`.
- **Doctor de saúde do pacman não reporta mais bytecode recompilado como
  problema.** `__pycache__/*.py[co]` (regenerado pelo interpretador) é tratado
  como ruído benigno; `.py`, `.orig` e `.pacnew` seguem reportados.
- **Backup de configs sem ruído de sockets.** `--warning=no-file-ignored`
  silencia os avisos de soquetes que o `tar` nunca arquiva (ex.:
  `/etc/pacman.d/gnupg/S.*`), sem alterar o conteúdo arquivado.

## [3.2.2] — 2026-06-13

### Adicionado

- **`--config` / `-c`**: inspeção read-only da configuração — caminhos (config,
  `steps.d/` empacotado e do usuário, logs/cache), valores efetivos em uso
  (config + defaults + auto-detecção), listas de ignore, paths de tools
  detectados e um exemplo completo de configuração.
- **`--config-example`**: imprime apenas o config de exemplo sem cores
  (pipe-friendly), para criar o arquivo via `full-upgrade --config-example >
  ~/.config/full-upgrade/config`. Usa `config.example` ao lado do projeto quando
  disponível e cai para um exemplo embutido no build standalone.

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
