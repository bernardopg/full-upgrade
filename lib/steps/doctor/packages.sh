#!/usr/bin/env bash
# lib/steps/doctor/packages.sh — auditorias de pacotes: pacman, AUR (paru), arch-audit, pacnew/pacsave, hooks ALPM e Flatpak.
# Extraído de lib/steps/doctor.sh (Série T1); carregado junto com os demais
# doctor/*.sh pelo entrypoint. Read-only, exceto funções autofix_* marcadas.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)



doctor_paru_devel_mode() {
  if ! has paru; then
    log "  paru não instalado; pulando auditoria de Devel."
    return 0
  fi

  local conf
  for conf in "${PARU_SYSTEM_CONF:-/etc/paru.conf}" "$HOME/.config/paru/paru.conf"; do
    [[ -r "$conf" ]] || continue
    if awk '$1 == "Devel" { found=1 } END { exit found ? 0 : 1 }' "$conf"; then
      log "  paru tem Devel ativo em ${conf}."
      log "  Isso faz pacotes -git/-svn atualizarem mesmo sem passar --devel ao script."
      return "$RC_WARN"
    fi
  done

  log "  paru Devel global não está ativo."
  return 0
}




# `flatpak repair --dry-run` confere o checksum de todo objeto do repo do
# usuário: com runtimes do Flathub instalados (6,7 GB num caso real) custa
# 40–70s e estourava o limite do step. A verificação completa só roda quando
# os refs mudaram desde a última verificação limpa ou quando ela tem mais de
# FLATPAK_REPAIR_MAX_AGE_DAYS dias (corrupção silenciosa não muda os refs).
FLATPAK_REPAIR_MAX_AGE_DAYS="${FLATPAK_REPAIR_MAX_AGE_DAYS:-7}"
FLATPAK_REPAIR_STAMP="${FLATPAK_REPAIR_STAMP:-${LOG_DIR}/flatpak-repair-ok}"

# Impressão digital dos refs do repo Flatpak do usuário. Sem repo: rc 1.
flatpak_user_repo_fingerprint() {
  local repo="${FLATPAK_USER_REPO:-${HOME}/.local/share/flatpak/repo}"
  [[ -d "$repo/refs" ]] || return 1
  find "$repo/refs" -type f -printf '%P %T@\n' 2>/dev/null | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}

# rc 0 quando a última verificação limpa vale para os refs atuais e não
# expirou. Qualquer dúvida (sem stamp, sem repo, stamp ilegível) => rc 1.
flatpak_repair_recent() {
  local fp="$1" stamp="$FLATPAK_REPAIR_STAMP" age
  [[ -n "$fp" && -r "$stamp" ]] || return 1
  [[ "$(<"$stamp")" == "$fp" ]] || return 1
  age=$(( $(date +%s) - $(stat -c %Y "$stamp" 2>/dev/null || echo 0) ))
  (( age >= 0 && age < FLATPAK_REPAIR_MAX_AGE_DAYS * 86400 ))
}

doctor_flatpak_repair_dry_run() {
  if ! has flatpak; then
    log "  flatpak não instalado."
    return 0
  fi

  local fp=""
  fp="$(flatpak_user_repo_fingerprint 2>/dev/null || true)"
  if flatpak_repair_recent "$fp"; then
    log "  Repo Flatpak do usuário sem mudança desde a última verificação limpa (verificação completa a cada ${FLATPAK_REPAIR_MAX_AGE_DAYS} dia(s))."
    return 0
  fi

  # Leitura de vários GB: prioridade de I/O ociosa para não travar a sessão.
  local -a prio=()
  has ionice && prio+=(ionice -c3)
  has nice && prio+=(nice -n 10)
  local output rc
  output="$("${prio[@]}" flatpak repair --user --dry-run 2>&1)"
  rc=$?
  log_raw "$output"

  if (( rc != 0 )); then
    log "  flatpak repair --user --dry-run retornou código ${rc}:"
    printf '%s\n' "$output" | grep -v '^$' | log_out || true
    return "$RC_WARN"
  fi

  if [[ $output != *[![:space:]]* ]]; then
    log "  Flatpak repair dry-run: nenhuma inconsistência reportada."
  else
    printf '%s\n' "$output" | grep -v '^$' | log_out || true
  fi
  # Só uma saída sem problema apontado vale como verificação limpa.
  if [[ -n "$fp" ]] && ! grep -qiE 'problem|error|erro|corrupt|missing|invalid' <<<"$output"; then
    printf '%s\n' "$fp" > "$FLATPAK_REPAIR_STAMP" 2>/dev/null || true
  fi
  return 0
}



# Remove de um relatório `pacman -Qkq` (stdin) as linhas que casam padrões de
# falso-positivo (passados como argumentos). Emite só as linhas "reais".
pacman_qk_filter_noise() {
  local filtered; filtered="$(cat)"
  local pat
  for pat in "$@"; do
    filtered="$(printf '%s\n' "$filtered" | grep -Ev "$pat" || true)"
  done
  printf '%s\n' "$filtered" | grep '[^[:space:]]' || true
}




doctor_pacman_health() {
  if ! has pacman; then
    log "  pacman não encontrado."
    return 0
  fi

  local output rc count filtered noise_count check_cmd_label
  local -a check_cmd=(pacman -Qkq)

  if has sudo && sudo -n true >/dev/null 2>&1; then
    check_cmd=(sudo pacman -Qkq)
    check_cmd_label="sudo pacman -Qkq"
  else
    check_cmd_label="pacman -Qkq"
  fi

  # Padrões de falsos positivos conhecidos:
  #   hicolor-icon-theme declara dirs 256x256@2 que apps instalam conforme necessário
  #   intel-ucode /boot/intel-ucode.img é embutido no initramfs pelo mkinitcpio
  local -a _pacman_health_noise=()
  _pacman_health_noise+=('^hicolor-icon-theme /usr/share/icons/hicolor/256x256@2/')
  _pacman_health_noise+=('^intel-ucode /boot/intel-ucode.img$')
  # Bytecode em __pycache__ é regenerado pelo interpretador (recompila a cada
  # bump de Python ou import); mtime/size divergem do empacotado mas o arquivo
  # é reconstruído sob demanda — não indica pacote quebrado. Filtra só .pyc/.pyo
  # dentro de __pycache__/. Arquivos .py, .orig e .pacnew seguem reportados.
  _pacman_health_noise+=('/__pycache__/[^ ]*\.py[co]$')

  output="$("${check_cmd[@]}" 2>&1)"
  rc=$?

  if (( rc != 0 )) && [[ $output != *[![:space:]]* ]]; then
    log "  ${check_cmd_label} retornou código ${rc} sem saída:"
    return "$RC_WARN"
  fi

  if [[ $output != *[![:space:]]* ]]; then
    log "  ${check_cmd_label}: nenhum pacote com arquivo faltando."
    return 0
  fi

  if [[ "$check_cmd_label" == "pacman -Qkq" ]] && grep -Eqi 'permission denied|permiss[aã]o negada' <<<"$output"; then
    log "  pacman -Qkq encontrou caminhos sem permissão; rode com sudo para uma auditoria conclusiva."
    printf '%s\n' "$output" | grep -Ei 'permission denied|permiss[aã]o negada' | log_stream | head -n 20
    return "$RC_WARN"
  fi

  # Filtrar falsos positivos
  filtered="$(printf '%s\n' "$output" | pacman_qk_filter_noise "${_pacman_health_noise[@]}")"
  noise_count=$(( $(printf '%s\n' "$output" | grep -c '[^[:space:]]' || true) - $(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true) ))

  if [[ $filtered != *[![:space:]]* ]]; then
    log "  ${check_cmd_label}: apenas falsos positivos conhecidos (${noise_count} ignorados)."
    return 0
  fi

  count="$(printf '%s\n' "$filtered" | grep -c '[^[:space:]]' || true)"
  local noise_note=""
  (( noise_count > 0 )) && noise_note=" (+ ${noise_count} falso(s) positivo(s) filtrado(s))"
  log "  ${check_cmd_label}: ${count} arquivo(s)/pacote(s) com problema${noise_note} (mostrando até 60):"
  printf '%s\n' "$filtered" | grep '[^[:space:]]' | log_stream | head -n 60
  if (( count > 60 )); then
    log "  Saída completa registrada no log."
  fi
  STEP_REASON="${count} arquivo(s)/pacote(s) com problema via ${check_cmd_label}${noise_note}"
  return "$RC_TODO"
}




# G2/N1 — helper puro: conta pacotes afetados na saída do `arch-audit`. Aceita o
# formato MODERNO ("<pkg> is affected by <tipo>. <risco> risk!") e o ANTIGO
# ("Package <pkg> is affected by ..."). O parser antigo exigia o prefixo "Package"
# e o marcador "Update to", ambos ausentes no arch-audit atual — fazia o step
# reportar "Sem CVEs" mesmo com dezenas de pacotes afetados. Lê stdin; imprime o
# total (inteiro). A classificação corrigível×sem-correção vem do flag `-u` do
# próprio arch-audit (ver doctor_arch_audit_cves), não mais de regex no texto.
arch_audit_affected_count() {
  grep -cE 'is affected by' || true
}



# G2/N1 — CVEs de pacotes oficiais via arch-audit, no fluxo padrão (read-only).
# Sem arch-audit, o run_step pula via cmd_deps do catálogo.
#  • corrigíveis (já há versão corrigida nos repos, via `arch-audit -u`) → RC_WARN
#    acionável (`pacman -Syu`);
#  • sem versão corrigida cadastrada → RC_WARN, requer validação upstream;
#  • nenhuma → 0. Consulta falhada → RC_WARN inconclusivo.
doctor_arch_audit_cves() {
  if ! has arch-audit; then
    log "  arch-audit não instalado; pulando."
    return 0
  fi

  local out rc netre total fixable manual
  netre='name or service not known|name resolution|could not resolve|network is unreachable|no route to host|connection timed out|connection refused|failed to connect'
  out="$(arch-audit 2>&1)"
  rc=$?
  # O tracker (security.archlinux.org) às vezes estoura o tempo numa consulta e
  # responde em ~2s na seguinte (run real 2026-09-25); uma nova tentativa evita
  # um aviso por instabilidade momentânea.
  if (( rc != 0 )) && grep -qiE "$netre" <<<"$out"; then
    log_raw "$out"
    sleep 5
    out="$(arch-audit 2>&1)"
    rc=$?
  fi
  if (( rc != 0 )); then
    log_raw "$out"
    log "  arch-audit: consulta ao tracker falhou (rc=${rc}); diagnóstico inconclusivo."
    STEP_REASON="consulta ao tracker arch-audit inconclusiva"
    return "$RC_WARN"
  fi
  log_raw "$out"

  total="$(printf '%s\n' "$out" | arch_audit_affected_count)"
  total="${total:-0}"
  if (( total == 0 )); then
    log "  Sem CVEs conhecidas em pacotes oficiais (arch-audit)."
    return 0
  fi

  # -u só informa correções cadastradas no tracker, não todo fix upstream.
  # Uma consulta falha não pode virar zero corrigíveis.
  local fixes
  fixes="$(arch-audit -u --quiet 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    log_raw "$fixes"
    STEP_REASON="arch-audit: consulta de correções inconclusiva"
    return "$RC_WARN"
  fi
  fixable="$(printf '%s\n' "$fixes" | grep -cE '.' || true)"
  fixable="${fixable:-0}"
  (( fixable > total )) && fixable="$total"
  manual=$(( total - fixable ))

  if (( fixable > 0 )); then
    log "  ${C_YELLOW}arch-audit: ${fixable} pacote(s) com CVE já corrigível nos repos.${C_RESET}"
    log "  Remediação: sudo pacman -Syu"
    (( manual > 0 )) && log "  ${C_DIM}+ ${manual} sem versão corrigida cadastrada no tracker (requer validação upstream).${C_RESET}"
    STEP_REASON="arch-audit: ${fixable} corrigível(is), ${manual} sem versão corrigida cadastrada"
    return "$RC_WARN"
  fi

  log "  ${total} pacote(s) sinalizado(s) pelo arch-audit, sem versão corrigida cadastrada no tracker. Isso não prova ausência de correção upstream; valide a versão instalada e o advisory. Veja \`full-upgrade --audit\` para a lista."
  STEP_REASON="arch-audit: ${total} pacote(s) requerem validação; tracker sem versão corrigida cadastrada"
  return "$RC_WARN"
}




# I2 — localiza arquivos .pacnew/.pacsave nos diretórios dados (um por linha).
# Isolado p/ testes (stub). Silencioso em erros de permissão.
pacfiles_find() {
  find "$@" -type f \( -name '*.pacnew' -o -name '*.pacsave' \) 2>/dev/null
}



# I2 — reporta arquivos .pacnew/.pacsave pendentes (configs novas/antigas geradas
# pelo pacman que precisam ser mescladas manualmente). Read-only: lista e sugere
# `pacdiff`. RC_TODO se houver pendências; 0 caso contrário. Inspirado no
# arch-update. Diretórios via PACFILES_DIRS (default "/etc /boot").
doctor_pacfiles() {
  local dirs="${PACFILES_DIRS:-/etc /boot}"
  local -a pacf=()
  # shellcheck disable=SC2086  # split intencional de PACFILES_DIRS
  mapfile -t pacf < <(pacfiles_find $dirs | grep -v '^[[:space:]]*$')

  if (( ${#pacf[@]} == 0 )); then
    log "  Sem arquivos .pacnew/.pacsave pendentes."
    return 0
  fi

  if pacfiles_todo_already_reported; then
    log "  ${#pacf[@]} arquivo(s) .pacnew/.pacsave pendente(s) já reportado(s) na verificação final."
    STEP_REASON="pacfiles já reportados pela verificação final"
    return 0
  fi

  log "  ${C_YELLOW}${#pacf[@]} arquivo(s) .pacnew/.pacsave pendente(s):${C_RESET}"
  local f shown=0
  for f in "${pacf[@]}"; do
    if (( shown < 20 )); then
      log "    • ${f}"
      shown=$((shown + 1))
    fi
  done
  (( ${#pacf[@]} > 20 )) && log "    … e mais $(( ${#pacf[@]} - 20 ))."
  if has pacdiff; then
    log "  Remediação: revise/mescle com 'sudo pacdiff' (ou 'pacdiff -o' para listar)."
  else
    log "  Remediação: instale 'pacman-contrib' e rode 'sudo pacdiff'."
  fi
  STEP_REASON="${#pacf[@]} .pacnew/.pacsave pendente(s) — rode pacdiff"
  return "$RC_TODO"
}




doctor_pacman_hooks() {
  if ! has journalctl; then
    log "  journalctl não encontrado; não é possível auditar hooks ALPM."
    return 0
  fi

  local boot_id
  boot_id="$(journalctl --list-boots --no-pager 2>/dev/null | awk 'NR==1{print $2}' || true)"
  [[ -z "$boot_id" ]] && boot_id="-b"

  local failed_hooks
  failed_hooks="$(journalctl -b "${boot_id}" -p err -g 'ALPM-scriptlet|alpm-hook' --no-pager --output=short-monotonic 2>/dev/null | grep -v '^$' || true)"

  if [[ $failed_hooks != *[![:space:]]* ]]; then
    log "  Nenhum hook ALPM com falha registrado no boot atual."
    return 0
  fi

  local count
  count="$(printf '%s\n' "$failed_hooks" | grep -c '[^[:space:]]' || true)"
  log "  ${count} mensagem(ns) de erro em hooks ALPM no boot atual (mostrando até 20):"
  printf '%s\n' "$failed_hooks" | head -n 20 | log_stream
  (( count > 20 )) && log "  Saída completa registrada no log."
  STEP_REASON="${count} erro(s) em hook(s) ALPM no boot atual"
  return "$RC_TODO"
}


# ── Doctor: inventário de apps manuais ──────────────────────────────────────────
# Read-only. Mapeia programas instalados FORA de qualquer gerenciador de pacotes
# (binários e symlinks em /usr/local/bin e ~/.local/bin sem dono pacman,
# diretórios de app em /opt e em ~/.local/opt) e indica quais já possuem step de atualização dedicado no
# full-upgrade e quais não. NÃO executa binários desconhecidos (evitar abrir GUIs
# como wireshark/cava); só reporta nome, local e cobertura. Sempre rc 0.
_manual_apps_has_step() {
  # Marcadores (basename de binário OU nome de diretório /opt) cobertos por um
  # step de atualização do full-upgrade. Mantido manualmente em sincronia com os
  # steps acima e com ai.sh/self_update.sh/steps.d.
  local marker="$1"
  # Um grupo por braço, sem continuação "\": o kcov não mede padrão quebrado.
  case "$marker" in
    photocraft|photocraft-cli|vectorcraft|vectorcraft-cli|filmcraft|filmcraft-cli|lightcraft|lightcraft-cli)
      [[ -r "${ARTCRAFT_DIR:-$HOME/development/artcraft}/${marker%-cli}/installation.json" ]] ;;
    pdfcraft|pdfcraft-cli|effectcraft|effectcraft-cli|designcraft|designcraft-cli)
      [[ -r "${ARTCRAFT_DIR:-$HOME/development/artcraft}/${marker%-cli}/installation.json" ]] ;;
    droid|snyk|zap|zap.sh|zaproxy|rtk|tokensave|openclaw) return 0 ;;
    hermes|ollama|claude|claude-code|opencode|OpenCode|antigravity|antigravity-ide) return 0 ;;
    uv|copilot|kimi|gk|gitkraken|coderabbit|cr) return 0 ;;
    kiro-cli|kiro-cli-chat|kiro-cli-term) return 0 ;;
    grok|jcode|qodercli|qoderwake|kimchi|cua-driver) return 0 ;;
    kilo|mimo|pool|purple|android|android-cli|gitleaks|trufflehog|muse|muse-bin-[0-9]*|cloudflared) return 0 ;;
    vp|vpr|vpx|vite-plus|herdr-core|hc|herdr-app|qodo|ori|spawn) return 0 ;;
    cli-proxy-api|cliproxyapi) return 0 ;;
    *) return 1 ;;
  esac
}


# Puro/testável: a partir de um item de backup no formato "nome  (dir)" (dois
# espaços como separador, mesmo formato de backup_items), devolve a sugestão
# de remoção com o caminho completo. Somente sugestão — o step nunca remove
# por conta própria (o 'nome-original' pode ser rollback intencional).
backup_removal_hint() {
  local item="$1" name dir
  name="${item%%  *}"
  dir="${item##*  }"
  dir="${dir#(}"
  dir="${dir%)}"
  printf '%s' "se obsoleto: rm '${dir%/}/${name}' (confira antes com 'file')"
}


_manual_apps_kind() {
  local name="$1"
  [[ -n "$name" ]] || { printf 'ignored'; return 0; }

  if _manual_apps_has_step "$name"; then
    printf 'covered'
    return 0
  fi

  case "$name" in
    *.manual.*|*.manual-backup-*|*.manual_backup_*|*-original|*.orig|*.bak)
      printf 'backup' ;;
    sharkd|tshark)
      printf 'auxiliary' ;;
    *)
      printf 'candidate' ;;
  esac
}


# Executáveis de ~/.local/bin instalados pelo pip --user: cada dist-info lista no
# RECORD os scripts como ../../../bin/<nome>. Estes têm o step de pip --user e
# não são "apps manuais" (o ruff era marcado como candidato). Imprime nomes.
_manual_apps_pip_user_bins() {
  local record
  for record in "${HOME}"/.local/lib/python3*/site-packages/*.dist-info/RECORD; do
    [[ -r "$record" ]] || continue
    sed -nE 's#^\.\./\.\./\.\./bin/([^,/]+),.*#\1#p' "$record"
  done
  return 0
}

# 0 quando o destino resolvido ($1) de um symlink pertence a um gerenciador que
# já tem step (uv, pipx, nvm, npm, pnpm, bun, deno, cargo, go, Artcraft) ou a
# um app com step próprio cuja instalação é versionada (claude, codegraph via
# npm). Puro sobre o caminho.
_manual_apps_managed_target() {
  local t="$1" h="$HOME"
  case "$t" in
    "$h"/.local/share/uv/* | "$h"/.local/share/pipx/* | "$h"/.nvm/* | "$h"/.npm-global/*) return 0 ;;
    "$h"/.local/share/pnpm/* | "$h"/.bun/* | "$h"/.deno/* | "$h"/.cargo/* | "$h"/go/*) return 0 ;;
    "$h"/.local/share/claude/* | "${ARTCRAFT_DIR:-$h/development/artcraft}"/*) return 0 ;;
  esac
  return 1
}

doctor_manual_apps() {
  has pacman || { log "  pacman ausente; inventário de apps manuais indisponível."; return 0; }

  local total=0 covered=0 backups=0 auxiliary=0 f d name probe kind
  local -a uncovered=() backup_items=() auxiliary_items=()

  # 1) Binários reais (regular files, não symlinks) em /usr/local/bin e ~/.local/bin
  #    sem dono pacman. pacman -Qo sobre um arquivo é confiável. Filtra por tamanho
  #    mínimo (≥ 1 MiB): apps instalados à mão são binários auto-contidos grandes
  #    (Go/Rust/Node-pkg/Electron); scripts pessoais e wrappers pequenos ficam de
  #    fora para o inventário não virar ruído.
  #    Symlinks contam pelo destino resolvido (gdu baixado à mão, herdr-app,
  #    instalação própria antiga do codegraph), exceto quando o destino é de um
  #    gerenciador com step; cada destino conta uma vez. Scripts do pip --user
  #    (RECORD dos dist-info) são cobertos pelo step de pip.
  local bindir min_size=1048576 sz real
  local -A seen_target=() pip_bins=()
  while IFS= read -r name; do [[ -n "$name" ]] && pip_bins["$name"]=1; done < <(_manual_apps_pip_user_bins)
  # MANUAL_APPS_SYSTEM_BIN_DIR existe para o teste isolar o host: no runner do
  # CI o /usr/local/bin tem dezenas de binários e a lista truncada escondia o
  # candidato esperado.
  for bindir in "${MANUAL_APPS_SYSTEM_BIN_DIR:-/usr/local/bin}" "${HOME}/.local/bin"; do
    [[ -d "$bindir" ]] || continue
    for f in "$bindir"/*; do
      if [[ -L "$f" ]]; then
        real="$(readlink -f -- "$f" 2>/dev/null)" || continue
        _manual_apps_managed_target "$real" && continue
      else
        real="$f"
      fi
      [[ -f "$real" && -x "$real" ]] || continue
      [[ -z "${seen_target[$real]+x}" ]] || continue
      seen_target["$real"]=1
      sz="$(stat -c%s "$real" 2>/dev/null || echo 0)"
      (( sz >= min_size )) || continue
      pacman -Qo "$real" >/dev/null 2>&1 && continue
      name="${f##*/}"
      total=$((total + 1))
      kind="$(_manual_apps_kind "$name")"
      [[ "$kind" == candidate && -n "${pip_bins[$name]+x}" ]] && kind=covered
      if [[ "$kind" == candidate ]] && has go && declare -F go_tool_module >/dev/null && go_tool_module "$real" >/dev/null; then
        kind=covered
      fi
      case "$kind" in
        covered) covered=$((covered + 1)) ;;
        backup) backups=$((backups + 1)); backup_items+=("${name}  (${bindir})") ;;
        auxiliary) auxiliary=$((auxiliary + 1)); auxiliary_items+=("${name}  (${bindir})") ;;
        *) uncovered+=("${name}  (${bindir})") ;;
      esac
    done
  done

  # 2) Diretórios de aplicação em /opt. Convencionalmente instalação manual, mas
  #    pacotes do repo/AUR também usam /opt (google-chrome, spotify, android-studio,
  #    intel-oneapi…). Probe de propriedade: se o 1º arquivo dentro pertence a um
  #    pacote, é gerenciado e não conta. Dirs vazios também são ignorados.
  # MANUAL_APPS_OPT_DIR existe para o teste isolar o /opt do host (o runner do
  # CI tem hostedtoolcache, az… e a lista truncada escondia o candidato).
  local opt_dir="${MANUAL_APPS_OPT_DIR:-/opt}"
  if [[ -d "$opt_dir" ]]; then
    for d in "$opt_dir"/*/; do
      [[ -d "$d" ]] || continue
      [[ -L "${d%/}" ]] && continue          # ignora symlink (ex.: /opt/idea -> idea-X.Y)
      name="${d%/}"; name="${name##*/}"
      probe="$(find "$d" -maxdepth 2 -type f 2>/dev/null | head -1)"
      [[ -n "$probe" ]] || continue
      pacman -Qo "$probe" >/dev/null 2>&1 && continue
      total=$((total + 1))
      kind="$(_manual_apps_kind "$name")"
      case "$kind" in
        covered) covered=$((covered + 1)) ;;
        backup) backups=$((backups + 1)); backup_items+=("${name}  (/opt)") ;;
        auxiliary) auxiliary=$((auxiliary + 1)); auxiliary_items+=("${name}  (/opt)") ;;
        *) uncovered+=("${name}  (/opt)") ;;
      esac
    done
  fi

  # 3) Apps extraídos à mão em ~/.local/opt (AppImage/.deb/tarball: handy,
  #    recordly, Tor Browser). Cada diretório é um app.
  if [[ -d "${HOME}/.local/opt" ]]; then
    for d in "${HOME}"/.local/opt/*/; do
      [[ -d "$d" && ! -L "${d%/}" ]] || continue
      name="${d%/}"; name="${name##*/}"
      total=$((total + 1))
      kind="$(_manual_apps_kind "$name")"
      case "$kind" in
        covered) covered=$((covered + 1)) ;;
        backup) backups=$((backups + 1)); backup_items+=("${name}  (${HOME}/.local/opt)") ;;
        auxiliary) auxiliary=$((auxiliary + 1)); auxiliary_items+=("${name}  (${HOME}/.local/opt)") ;;
        *) uncovered+=("${name}  (${HOME}/.local/opt)") ;;
      esac
    done
  fi

  if (( total == 0 )); then
    log "  Nenhum app fora de gerenciador de pacotes detectado."
    return 0
  fi

  log "  Apps fora de gerenciador de pacotes: ${total} (com step: ${covered}, candidatos sem step: ${#uncovered[@]}, backups/remanescentes: ${backups}, auxiliares: ${auxiliary})."
  local u shown=0
  for u in "${uncovered[@]}"; do
    if (( shown >= 25 )); then
      log "    … e mais $(( ${#uncovered[@]} - shown )) (lista completa no log)."
      break
    fi
    log "    • ${u}"
    shown=$((shown + 1))
  done

  if (( ${#uncovered[@]} > 0 )); then
    log "  Candidatos sem step: origem e mecanismo de atualização ainda precisam ser verificados."
  fi
  if (( backups > 0 )); then
    log "  Backups/remanescentes detectados (${backups}) foram excluídos da contagem de candidatos; revise/remova manualmente quando tiver certeza."
    for u in "${backup_items[@]}"; do
      log_raw "manual-app-backup: ${u}"
      log "    ↳ $(backup_removal_hint "${u}")"
    done
  fi
  if (( auxiliary > 0 )); then
    log "  Binários auxiliares conhecidos (${auxiliary}) foram excluídos da contagem de candidatos."
    for u in "${auxiliary_items[@]}"; do log_raw "manual-app-auxiliar: ${u}"; done
  fi
  return 0
}

# ── Doctor: pacotes locais fora do AUR (U10) ────────────────────────────────────
# Pacote estrangeiro (pacman -Qm) que o AUR não conhece veio de PKGBUILD local:
# o helper AUR só imprime "pacotes não presentes no AUR" e ele nunca atualiza
# (dankcalendar-bin e dsearch-bin ficaram na 2.0.0 com 2.1.x publicadas). O
# doctor pergunta ao AUR por todos de uma vez e, para os ausentes cujo URL é do
# GitHub, compara com o último release. Read-only.

# Nomes da entrada padrão que a resposta da RPC v5 ($1) não trouxe. Puro.
aur_rpc_missing() {
  local json="$1" name
  local -A found=()
  while IFS= read -r name; do
    [[ -n "$name" ]] && found["$name"]=1
  done < <(grep -oE '"Name"[[:space:]]*:[[:space:]]*"[^"]+"' <<<"$json" | sed -E 's/.*"([^"]+)"$/\1/')
  while IFS= read -r name; do
    [[ -n "$name" && -z "${found[$name]+x}" ]] && printf '%s\n' "$name"
  done
  return 0
}

# owner/repo de um URL do GitHub (com ou sem .git e subcaminho). Puro.
github_repo_from_url() {
  [[ "$1" =~ ^https?://(www\.)?github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+) ]] || return 1
  printf '%s/%s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]%.git}"
}

# Versão upstream de uma versão pacman: tira epoch e pkgrel ("1:2.0.0-3" → 2.0.0).
pkg_upstream_version() {
  local v="${1#*:}"
  printf '%s\n' "${v%-*}"
}

doctor_foreign_pkgs_upstream() {
  has pacman || { log "  pacman ausente."; return 0; }
  local -A ver=()
  local name v
  while read -r name v; do
    [[ -n "$name" ]] && ver["$name"]="$v"
  done < <(pacman -Qm 2>/dev/null)
  if ((${#ver[@]} == 0)); then
    log "  Nenhum pacote estrangeiro instalado."
    return 0
  fi

  local -a names=() missing=() chunk=()
  mapfile -t names < <(printf '%s\n' "${!ver[@]}" | LC_ALL=C sort)
  local i json qs rc
  for ((i = 0; i < ${#names[@]}; i += 100)); do
    chunk=("${names[@]:i:100}")
    qs="$(printf 'arg[]=%s&' "${chunk[@]}" | sed 's/+/%2B/g')"
    json="$(fetch_network_text --connect-timeout 10 --max-time 30 "https://aur.archlinux.org/rpc/v5/info?${qs%&}")"
    rc=$?
    if ((rc != 0)) || [[ "$json" != *'"results"'* ]]; then
      STEP_REASON="RPC do AUR indisponível; pacotes locais não verificados"
      return "$RC_WARN"
    fi
    mapfile -t -O "${#missing[@]}" missing < <(printf '%s\n' "${chunk[@]}" | aur_rpc_missing "$json")
  done

  # Pacote -debug gerado pelo makepkg acompanha o base; não é fonte própria.
  local -a local_pkgs=()
  for name in "${missing[@]}"; do
    [[ "$name" == *-debug && -n "${ver[${name%-debug}]+x}" ]] && continue
    local_pkgs+=("$name")
  done
  if ((${#local_pkgs[@]} == 0)); then
    log "  Todos os ${#names[@]} pacote(s) estrangeiro(s) existem no AUR (o helper AUR os atualiza)."
    return 0
  fi

  log "  Pacotes locais fora do AUR (${#local_pkgs[@]}): ${local_pkgs[*]}"
  local url repo latest cur
  local -a outdated=()
  for name in "${local_pkgs[@]}"; do
    url="$(LC_ALL=C pacman -Qi "$name" 2>/dev/null | sed -n 's/^URL *: //p' | head -1)"
    cur="$(pkg_upstream_version "${ver[$name]}")"
    if ! repo="$(github_repo_from_url "$url")"; then
      log "    • ${name} ${cur}: URL fora do GitHub (${url:-sem URL}); confira a origem à mão."
      continue
    fi
    if ! latest="$(github_latest_release_version "$repo")"; then
      log "    • ${name} ${cur}: sem release semver em github.com/${repo}."
      continue
    fi
    if version_is_outdated "$cur" "$latest"; then
      log "    • ${name} ${cur} → ${latest} (github.com/${repo})"
      outdated+=("${name} ${cur}→${latest}")
    else
      log "    • ${name} ${cur}: em dia com github.com/${repo}."
    fi
  done

  if ((${#outdated[@]} > 0)); then
    remediation "reconstrua o PKGBUILD local na versão nova (pkgver + checksums) ou troque por um pacote do AUR/repo"
    STEP_REASON="pacote(s) local(is) atrás do upstream: ${outdated[*]}"
    return "$RC_TODO"
  fi
  return 0
}

doctor_artcraft() {
  local rc=0
  run_logged artcraft_run doctor || rc=$?
  if (( rc != 0 )); then
    STEP_REASON="Artcraft: instalação local incompleta; confira o log"
    return "$RC_TODO"
  fi
}
