#!/usr/bin/env bash
# lib/tui.sh — TUI interativo de configuração (--config-tui).
# Sourced pelo entrypoint (depois de config/catalog/cli). Não executar direto.
#
# Contrato:
#   - Bash puro: ANSI escape + raw mode via stty. Zero dependências novas
#     (sem fzf/dialog/whiptail) — coerente com o perfil do projeto.
#   - Duas telas de edição (Steps, Parâmetros) + menu + revisão de salvamento.
#   - Gravação segura: backup automático, upsert linha a linha preservando
#     comentários, validação `bash -n` antes do mv atômico.
#   - O TUI edita SEMPRE o arquivo de config (~/.config/full-upgrade/config),
#     nunca o ambiente: skips exibidos vêm do valor do arquivo
#     (config_file_value), não da lista mesclada em load_config.
# shellcheck shell=bash
# shellcheck disable=SC2034  # globais cross-module do TUI

# ── Estado global do TUI ──────────────────────────────────────────────────────
TUI_MODE="menu"          # menu | steps | params | help
TUI_SEL=0                # item selecionado na tela atual
TUI_TOP=0                # 1º item visível (janela de scroll)
TUI_FILTER=""            # filtro vivo (/)
TUI_FILTER_MODE=0        # 1 = digitando filtro
TUI_PENDING=0            # mudanças não salvas (recomputado a cada toggle)
TUI_ROWS=0 TUI_COLS=0
TUI_STTY_SAVED=""
TUI_FLASH=""             # mensagem efêmera no rodapé
TUI_QUIT=0
TUI_REVIEW_TOP=0       # primeiro item da página de revisão

# Modelo de itens da tela atual (arrays paralelos por índice).
TUI_NAME=()   # chave de param ou nome de step
TUI_DESC=()
TUI_KIND=()   # step | bool | enum | int | string | path | list
TUI_VALUE=()  # valor atual (editável) — p/ step: "run"|"skip"
TUI_ORIG=()   # valor original — base do diff e do dirty-check
TUI_META=()   # steps: "categoria|efeito" · params: opções do enum
TUI_VIEW=()   # índices visíveis após filtro

# Cada tela tem seu próprio modelo persistente. TUI_* é só a tela ativa;
# trocar Steps ↔ Parâmetros nunca pode apagar uma alteração ainda não gravada.
TUI_STEPS_READY=0
TUI_PARAMS_READY=0
TUI_STEPS_NAME=() TUI_STEPS_DESC=() TUI_STEPS_KIND=() TUI_STEPS_VALUE=() TUI_STEPS_ORIG=() TUI_STEPS_META=()
TUI_PARAMS_NAME=() TUI_PARAMS_DESC=() TUI_PARAMS_KIND=() TUI_PARAMS_VALUE=() TUI_PARAMS_ORIG=() TUI_PARAMS_META=()
CH_KEY=() CH_OLD=() CH_NEW=() CH_KIND=() CH_SECTION=()

declare -A TUI_SKIP_BASE=()   # nome=1 p/ steps skipados no ARQUIVO de config
TUI_SKIP_CSV_BASE=""      # CSV bruto de FULL_UPGRADE_SKIP no arquivo (cache)

# ── Catálogo de parâmetros editáveis ──────────────────────────────────────────
# Formato: chave|tipo|meta|descrição (meta = opções de enum separadas por ",").
tui_param_catalog() {
  cat <<'EOF'
ENABLE_CUSTOM_TOOLS|bool||Habilita steps customizados de ~/.config/full-upgrade/steps.d
LANG_OVERRIDE|enum|auto,pt,en|Idioma das mensagens (auto = detecta de $LANG)
SNAPSHOT_TOOL|enum|auto,snapper,timeshift,none|Ferramenta de snapshot pré-upgrade
SNAPSHOT_MIN_FREE_GIB|int||Espaço mínimo livre em / para criar snapshot (GiB)
SNAPSHOT_KEEP|int||Snapshots antigos do full-upgrade a manter
MIRROR_TOOL|enum|auto,reflector,rate-mirrors,none|Ferramenta de refresh de mirrors
MIRROR_MAX_AGE_DAYS|int||Pula refresh se a mirrorlist tem menos de N dias (0 = sempre)
AUR_HELPER|enum|,paru,yay,pikaur|Helper AUR (vazio = auto-detecta; paru > yay > pikaur)
PRIV_CMD|enum|,sudo,doas,sudo-rs,run0|Elevador de privilégio (vazio = auto; sudo > doas)
MIN_FREE_GIB|int||Espaço mínimo livre em / antes de mutações (GiB)
MIN_BOOT_FREE_MIB|int||Espaço mínimo livre em /boot (MiB; ESP é pequeno)
BTRFS_SCRUB_MAX_DAYS|int||Alerta se o último scrub btrfs for mais antigo (dias)
COREDUMP_KEEP_DAYS|int||Retenção de dumps em /var/lib/systemd/coredump (dias)
BACKUP_CONFIGS|bool||Arquiva configs críticas de /etc antes do update
BACKUP_KEEP|int||Quantos tarballs privados manter (mínimo 1 quando ativo)
TIMESHIFT_CLOUD_BACKUP|bool||Réplica do snapshot Timeshift para nuvem (Restic+rclone)
TIMESHIFT_CLOUD_KEEP|int||Versões remotas mais recentes a manter
NETWORK_GATE|bool||Portão de conectividade antes dos steps de rede
NETWORK_GATE_WAIT_S|int||Espera máxima pela volta da rede no portão (s)
AUTO_FIX_RUST_CVES|bool||Oferece remediar CVEs de toolchain Rust sob --yes/confirmação
AUTO_BTRFS_SCRUB|bool||Oferece iniciar btrfs scrub vencido sob --yes/confirmação
AUTO_FIX_FINAL_PENDING|bool||Aplica pacman -Syu em pendências finais sob --yes/confirmação
AUTO_FIX_PIP_DEPS|bool||Instala deps pip --user ausentes sob --yes/confirmação
AUTO_MERGE_PACNEW|bool||Mescla sozinho .pacnew com merge 100% seguro
SECURE_BOOT_STRICT|bool||--audit classifica Secure Boot off como severidade média
REPORT_ON_FINISH|bool||Grava relatório Markdown do run ao final
NOTIFY_ON_FINISH|bool||Notificação desktop com o resumo ao fim do run
TRAY_CHECK_INTERVAL_M|int||Intervalo de checagem do systray (minutos; mín. 1)
TRAY_NOTIFICATIONS|bool||Systray emite notificações em transições de estado
TRAY_BADGE|bool||AppIndicator mostra contador de updates/todo/falhas
MCP_AUTO_UPDATE|bool||Step MCP refresca o cache uv dos servers uvx
OLLAMA_SELF_UPDATE|bool||Reexecuta o instalador oficial do Ollama
FULL_UPGRADE_UPDATE_CHANNEL|enum|release,main|Canal de auto-atualização (release = última tag)
EOF
}

# ── Valor de uma chave de param no ambiente (pós load_config = efetivo) ──────
tui_env_value() {
  local key="$1"
  printf '%s' "${!key:-}"
}

# ── Quoting de valores para o arquivo de config ──────────────────────────────
# int/bool => cru; demais => double-quote com \ " e $ escapados.
tui_quote_value() {
  local kind="$1" val="$2"
  if [[ "$kind" == int || "$kind" == bool ]]; then
    printf '%s' "$val"
    return 0
  fi
  val="${val//\\/\\\\}"
  val="${val//\"/\\\"}"
  val="${val//\$/\\\$}"
  val="$(printf '%s' "$val" | sed 's/`/\\`/g')"
  printf '"%s"' "$val"
}

# Desfaz o escape do tui_quote_value (p/ exibir valor de arquivo no diff).
tui_unquote_value() {
  local val="$1"
  val="${val%\"}"; val="${val#\"}"
  val="${val//\\\"/\"}"
  val="${val//\\\$/\$}"
  val="$(printf '%s' "$val" | sed 's/\\`/`/g')"
  val="${val//\\\\/\\}"
  printf '%s' "$val"
}

tui_inline_comment_suffix() {
  local value="$1" quote="" escaped=0 i ch prev
  for ((i=0; i<${#value}; i++)); do
    ch="${value:i:1}"
    if (( escaped )); then
      escaped=0
    elif [[ "$ch" == "\\" && -n "$quote" ]]; then
      escaped=1
    elif [[ -n "$quote" ]]; then
      [[ "$ch" == "$quote" ]] && quote=""
    elif [[ "$ch" == "\"" || "$ch" == "'" ]]; then
      quote="$ch"
    elif [[ "$ch" == "#" ]]; then
      prev="${value:i-1:1}"
      if [[ "$prev" == " " || "$prev" == $'\t' ]]; then
        printf '%s' "${value:i-1}"
        return 0
      fi
    fi
  done
}

# ── Gravação do fluxo de save ─────────────────────────────────────────────────
# Upsert num arquivo ARBITRÁRIO: substitui a linha existente da KEY (qualquer
# posição) ou anexa na seção gerenciada do fim. Preserva todas as outras linhas
# (comentários do usuário incluídos).
tui_upsert_into() {
  local file="$1" assignment="$2" key
  key="${assignment%%=*}"
  local tmp
  tmp="$(mktemp "${file}.upXXXXXX")" || return 1
  local replaced=0 line cur_key cur_prefix cur_value cur_suffix last_prefix="" last_suffix=""
  if [[ -s "$file" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      cur_key="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p')"
      if [[ -n "$cur_key" && "$cur_key" == "$key" ]]; then
        cur_prefix="$(printf '%s' "$line" | sed -nE "s/^([[:space:]]*(export[[:space:]]+)?${key}=).*/\\1/p")"
        cur_value="${line#*"$key="}"
        last_prefix="$cur_prefix"
        last_suffix="$(tui_inline_comment_suffix "$cur_value")"
      fi
    done <"$file"
    # Toda linha vai para $tmp (nunca stdout — o chamador não captura).
    while IFS= read -r line || [[ -n "$line" ]]; do
      cur_key="$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p')"
      if [[ -n "$cur_key" && "$cur_key" == "$key" ]]; then
        # Bash usa a última atribuição. Consolidar duplicatas garante que o
        # valor exibido como salvo seja também o efetivo após um novo source.
        if (( replaced == 0 )); then
          printf '%s%s%s\n' "$last_prefix" "${assignment#*=}" "$last_suffix" >>"$tmp"
          replaced=1
        fi
      else
        printf '%s\n' "$line" >>"$tmp"
      fi
    done <"$file"
    if (( replaced == 0 )); then
      printf '\n# ── full-upgrade TUI (gerenciado — pode editar à mão também) ──\n%s\n' "$assignment" >>"$tmp"
    fi
  else
    printf '%s\n' "$assignment" >"$tmp"
  fi
  mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
  return 0
}

# Grava os pares "KEY|kind|novo-valor" (um por argumento) no config do usuário:
# backup com timestamp, upserts, validação bash -n e mv atômico. Poda backups
# além dos 5 mais recentes. Define TUI_FLASH_BAK com a origem do arquivo.
tui_config_save_pairs() {
  local file="$FU_CONFIG_FILE" bak="" dir work ok=1 pair key kind val rest assignment
  dir="$(dirname "$file")"
  mkdir -p "$dir" || return 1
  if [[ -f "$file" ]]; then
    bak="${file}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -p "$file" "$bak" || bak=""
  fi
  work="$(mktemp "${dir}/.full-upgrade-tuiXXXXXX")" || return 1
  # CRÍTICO: o work nasce do CONTEÚDO atual do config (não vazio) — os upserts
  # editam linha a linha preservando todo o resto (comentários, chaves não
  # gerenciadas). Um work vazio substituiria o config inteiro.
  if [[ -s "$file" ]]; then
    cp -p "$file" "$work" || { rm -f "$work"; return 1; }
  else
    : >"$work"
  fi
  for pair in "$@"; do
    key="${pair%%|*}"
    rest="${pair#*|}"
    kind="${rest%%|*}"
    val="${rest#*|}"
    assignment="${key}=$(tui_quote_value "$kind" "$val")"
    tui_upsert_into "$work" "$assignment" || { ok=0; break; }
  done
  # Nunca ativar um config que não parseia: bash -n é obrigatório.
  if (( ok == 1 )); then
    bash -n "$work" 2>/dev/null || ok=0
  fi
  if (( ok == 0 )); then
    rm -f "$work"
    return 1
  fi
  mv -f "$work" "$file" || { rm -f "$work"; return 1; }
  local old_bak
  for old_bak in $(ls -1t "${file}".bak.* 2>/dev/null | tail -n +6); do
    rm -f "$old_bak"
  done
  if [[ -n "$bak" ]]; then
    TUI_FLASH_BAK=" (backup: $(basename "$bak"))"
  else
    TUI_FLASH_BAK=" (config criado)"
  fi
  return 0
}

# ── Montagem das telas ────────────────────────────────────────────────────────

tui_build_steps() {
  TUI_NAME=(); TUI_DESC=(); TUI_KIND=(); TUI_VALUE=(); TUI_ORIG=(); TUI_META=()
  local name category tags effect timeout cmd_deps func_name desc
  # Skip-list BASE = valor do ARQUIVO (não o mesclado com ambiente). O CSV
  # bruto fica em cache: tui_collect_changes roda a cada toggle e não pode
  # pagar um subshell de source por tecla.
  declare -gA TUI_SKIP_BASE=()
  local csv n
  local -a normalized=()
  TUI_SKIP_CSV_BASE="$(config_file_value FULL_UPGRADE_SKIP)"
  local -a _base_list=()
  IFS=',' read -ra _base_list <<<"$TUI_SKIP_CSV_BASE" || true
  for n in "${_base_list[@]:-}"; do
    # Trim só de bordas (espaços internos dos nomes são legítimos).
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    [[ -n "$n" ]] && { TUI_SKIP_BASE["$n"]=1; normalized+=("$n"); }
  done
  TUI_SKIP_CSV_BASE=""
  for n in "${normalized[@]}"; do
    [[ -n "$TUI_SKIP_CSV_BASE" ]] && TUI_SKIP_CSV_BASE+=","
    TUI_SKIP_CSV_BASE+="$n"
  done
  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ -n "$name" ]] || continue
    # core/final não são configuráveis pelo TUI (sempre rodam por design).
    [[ "$category" == "core" || "$category" == "final" ]] && continue
    local state="run"
    [[ -n "${TUI_SKIP_BASE[$name]:-}" ]] && state="skip"
    TUI_NAME+=("$name")
    TUI_DESC+=("$desc")
    TUI_KIND+=("step")
    TUI_VALUE+=("$state")
    TUI_ORIG+=("$state")
    TUI_META+=("$category|$effect")
  done < <(step_catalog)
}

tui_build_params() {
  TUI_NAME=(); TUI_DESC=(); TUI_KIND=(); TUI_VALUE=(); TUI_ORIG=(); TUI_META=()
  local key kind meta desc val
  while IFS='|' read -r key kind meta desc; do
    [[ -n "$key" ]] || continue
    val="$(tui_env_value "$key")"
    TUI_NAME+=("$key")
    TUI_DESC+=("$desc")
    TUI_KIND+=("$kind")
    TUI_VALUE+=("$val")
    TUI_ORIG+=("$val")
    TUI_META+=("$meta")
  done < <(tui_param_catalog)
}

# Reconstrói a visão filtrada (TUI_VIEW) a partir do filtro atual.
tui_rebuild_view() {
  TUI_VIEW=()
  local i needle="${TUI_FILTER,,}"
  for i in "${!TUI_NAME[@]}"; do
    if [[ -z "$needle" \
        || "${TUI_NAME[$i],,}" == *"$needle"* \
        || "${TUI_DESC[$i],,}" == *"$needle"* ]]; then
      TUI_VIEW+=("$i")
    fi
  done
}

# ── Cálculo de mudanças pendentes ─────────────────────────────────────────────
# TUI_* é uma visão transitória. Copie-a de volta antes de trocar de tela ou
# calcular o diff; os modelos STEPS/PARAMS são a fonte de verdade da sessão.
tui_store_active_model() {
  case "$TUI_MODE" in
    steps)
      TUI_STEPS_NAME=("${TUI_NAME[@]}"); TUI_STEPS_DESC=("${TUI_DESC[@]}")
      TUI_STEPS_KIND=("${TUI_KIND[@]}"); TUI_STEPS_VALUE=("${TUI_VALUE[@]}")
      TUI_STEPS_ORIG=("${TUI_ORIG[@]}"); TUI_STEPS_META=("${TUI_META[@]}")
      TUI_STEPS_READY=1 ;;
    params)
      TUI_PARAMS_NAME=("${TUI_NAME[@]}"); TUI_PARAMS_DESC=("${TUI_DESC[@]}")
      TUI_PARAMS_KIND=("${TUI_KIND[@]}"); TUI_PARAMS_VALUE=("${TUI_VALUE[@]}")
      TUI_PARAMS_ORIG=("${TUI_ORIG[@]}"); TUI_PARAMS_META=("${TUI_META[@]}")
      TUI_PARAMS_READY=1 ;;
  esac
}

tui_load_model() {
  local screen="$1"
  case "$screen" in
    steps)
      if (( TUI_STEPS_READY )); then
        TUI_NAME=("${TUI_STEPS_NAME[@]}"); TUI_DESC=("${TUI_STEPS_DESC[@]}")
        TUI_KIND=("${TUI_STEPS_KIND[@]}"); TUI_VALUE=("${TUI_STEPS_VALUE[@]}")
        TUI_ORIG=("${TUI_STEPS_ORIG[@]}"); TUI_META=("${TUI_STEPS_META[@]}")
      else
        tui_build_steps; tui_store_active_model
      fi ;;
    params)
      if (( TUI_PARAMS_READY )); then
        TUI_NAME=("${TUI_PARAMS_NAME[@]}"); TUI_DESC=("${TUI_PARAMS_DESC[@]}")
        TUI_KIND=("${TUI_PARAMS_KIND[@]}"); TUI_VALUE=("${TUI_PARAMS_VALUE[@]}")
        TUI_ORIG=("${TUI_PARAMS_ORIG[@]}"); TUI_META=("${TUI_PARAMS_META[@]}")
      else
        tui_build_params; tui_store_active_model
      fi ;;
  esac
}

# Preenche o diff completo de TODA a sessão para revisão e gravação.
tui_current_skip_csv() {
  local entry i
  local -a base=() out=()
  local -A catalog=()
  for i in "${!TUI_STEPS_NAME[@]}"; do catalog["${TUI_STEPS_NAME[$i]}"]=1; done
  IFS=',' read -r -a base <<<"${TUI_SKIP_CSV_BASE:-}"
  for entry in "${base[@]}"; do
    entry="${entry#"${entry%%[![:space:]]*}"}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    [[ -n "$entry" ]] || continue
    [[ -n "${catalog[$entry]:-}" ]] || out+=("$entry")
  done
  for i in "${!TUI_STEPS_NAME[@]}"; do
    [[ "${TUI_STEPS_VALUE[$i]}" == "skip" ]] && out+=("${TUI_STEPS_NAME[$i]}")
  done
  local csv=""
  for entry in "${out[@]}"; do
    [[ -n "$csv" ]] && csv+=","
    csv+="$entry"
  done
  printf '%s' "$csv"
}

tui_collect_changes() {
  tui_store_active_model
  CH_KEY=(); CH_OLD=(); CH_NEW=(); CH_KIND=(); CH_SECTION=()
  local i new_csv
  for i in "${!TUI_PARAMS_NAME[@]}"; do
    [[ "${TUI_PARAMS_VALUE[$i]}" != "${TUI_PARAMS_ORIG[$i]}" ]] || continue
    CH_KEY+=("${TUI_PARAMS_NAME[$i]}"); CH_OLD+=("${TUI_PARAMS_ORIG[$i]}")
    CH_NEW+=("${TUI_PARAMS_VALUE[$i]}"); CH_KIND+=("${TUI_PARAMS_KIND[$i]}")
    CH_SECTION+=("Parâmetros")
  done
  new_csv="$(tui_current_skip_csv)"
  if [[ "$new_csv" != "${TUI_SKIP_CSV_BASE:-}" ]]; then
    CH_KEY+=("FULL_UPGRADE_SKIP"); CH_OLD+=("${TUI_SKIP_CSV_BASE:-}")
    CH_NEW+=("$new_csv"); CH_KIND+=("list"); CH_SECTION+=("Steps")
  fi
  TUI_PENDING=${#CH_KEY[@]}
}

tui_mark_models_saved() {
  # A tela ativa também precisa ter sua base atualizada antes do snapshot.
  TUI_ORIG=("${TUI_VALUE[@]}")
  tui_store_active_model
  TUI_PARAMS_ORIG=("${TUI_PARAMS_VALUE[@]}")
  TUI_STEPS_ORIG=("${TUI_STEPS_VALUE[@]}")
  local i new_csv
  declare -gA TUI_SKIP_BASE=()
  new_csv="$(tui_current_skip_csv)"
  for i in "${!TUI_STEPS_NAME[@]}"; do
    [[ "${TUI_STEPS_VALUE[$i]}" == "skip" ]] && TUI_SKIP_BASE["${TUI_STEPS_NAME[$i]}"]=1
  done
  TUI_SKIP_CSV_BASE="$new_csv"
  tui_collect_changes
}

# ── Terminal: abrir/fechar, tamanhos, teclado ─────────────────────────────────

tui_open() {
  TUI_STTY_SAVED="$(stty -g 2>/dev/null || true)"
  stty raw -echo 2>/dev/null || true
  printf '\033[?1049h\033[H\033[2J\033[?25l'
  tui_update_size
}

tui_close() {
  [[ -n "$TUI_STTY_SAVED" ]] && stty "$TUI_STTY_SAVED" 2>/dev/null
  printf '\033[?25h\033[?1049l'
}

tui_update_size() {
  TUI_ROWS="$(tput lines 2>/dev/null || printf 24)"
  TUI_COLS="$(tput cols 2>/dev/null || printf 80)"
  [[ "$TUI_ROWS" =~ ^[0-9]+$ ]] || TUI_ROWS=24
  [[ "$TUI_COLS" =~ ^[0-9]+$ ]] || TUI_COLS=80
  (( TUI_ROWS < 10 )) && TUI_ROWS=10
  (( TUI_COLS < 40 )) && TUI_COLS=40
  (( TUI_ROWS > 60 )) && TUI_ROWS=60
}

# Lê uma tecla em TUI_KEY: up|down|left|right|pgup|pgdn|home|end|enter|esc|
# space|backspace|char:<c>
#
# IMPORTANTE: usar -N (não -n)! Em terminal, o read -n trata CR e LF como
# delimitadores e retorna a variável VAZIA para o Enter — a tecla se perdia
# como "char:". -N lê exatamente N bytes, sem honrar delimitador.
tui_read_key() {
  local c rest="" extra=""
  IFS= read -rsN1 c || { TUI_KEY="esc"; return 0; }
  case "$c" in
    $'\x1b')
      # Sequência ANSI: ESC + [ + código (setas = 3 bytes) ou ESC + [ + dígito
      # + ~ (PgUp/PgDn/Home/End = 4 bytes — sem ler o 3º byte o ~ fica órfão
      # no buffer e dessincroniza as teclas seguintes).
      if IFS= read -rsN2 -t 0.1 rest; then
        case "$rest" in
          '[1'|'[2'|'[3'|'[4'|'[5'|'[6'|'[7'|'[8')
            IFS= read -rsN1 -t 0.1 extra || extra="" ;;
        esac
        tui_decode_csi "$rest" "$extra"
      else
        TUI_KEY="esc"   # ESC solto (sem sequência no timeout)
      fi
      return 0 ;;
    $'\x7f'|$'\x08') TUI_KEY="backspace"; return 0 ;;
    # raw mode desliga ISIG: Ctrl-C/Ctrl-D chegam como bytes, não sinais.
    $'\x03'|$'\x04') TUI_KEY="char:q"; return 0 ;;
    $'\n'|$'\r'|$'\x0a') TUI_KEY="enter"; return 0 ;;
    ' ') TUI_KEY="space"; return 0 ;;
  esac
  TUI_KEY="char:${c}"
}

# Decodifica a sequência recebida após ESC (pura; testável).
# $1 = os 2 bytes seguintes (ex.: "[A"), $2 = 3º byte quando a sequência
# termina em ~ (ex.: "~" para PgUp). Formas CSI ([A) e SS3 (OA) são aceitas —
# terminais variam entre elas conforme o modo do cursor.
tui_decode_csi() {
  local rest="$1" extra="${2:-}"
  case "$rest" in
    '[A'|OA) TUI_KEY="up" ;;
    '[B'|OB) TUI_KEY="down" ;;
    '[C'|OC) TUI_KEY="right" ;;
    '[D'|OD) TUI_KEY="left" ;;
    '[H'|OH) TUI_KEY="home" ;;
    '[F'|OF) TUI_KEY="end" ;;
    '[Z')    TUI_KEY="esc" ;;          # Shift-Tab
    '[1'|'[2'|'[3'|'[4'|'[5'|'[6'|'[7'|'[8')
      case "${rest}${extra}" in
        '[5~')        TUI_KEY="pgup" ;;
        '[6~')        TUI_KEY="pgdn" ;;
        '[1~'|'[7~')  TUI_KEY="home" ;;
        '[4~'|'[8~')  TUI_KEY="end" ;;
        *)            TUI_KEY="esc" ;;
      esac ;;
    *) TUI_KEY="esc" ;;
  esac
}

# ── Primitivas de desenho ─────────────────────────────────────────────────────

tui_line() {
  # \r\n: em raw mode (stty raw) o ONLCR está desligado — \n sozinho não volta
  # à coluna 0 e o layout desandaria.
  printf '\033[K%s\r\n' "$1"
}

tui_title_bar() {
  local title="$1" pending=""
  (( TUI_PENDING > 0 )) && pending="  ${C_YELLOW}● ${TUI_PENDING} alteração(ões) não salva(s)${C_RESET}"
  local bar="${C_BOLD} full-upgrade · configuração${C_RESET} ${C_DIM}| ${title}${pending}${C_RESET}"
  printf '\033[H\033[K%s' "$bar"
}

tui_footer() {
  local hints="$1"
  printf '\033[%d;1H\033[K%s%s\033[J' "$TUI_ROWS" "$C_DIM" "$hints"
  if [[ -n "$TUI_FLASH" ]]; then
    printf '\033[%d;1H\033[K%s%s%s' "$TUI_ROWS" "$C_BOLD" "$TUI_FLASH" "$C_RESET"
  fi
}

tui_visible_rows() {
  echo $(( TUI_ROWS - 4 ))
}

# Rola para manter TUI_SEL visível dentro da janela [TUI_TOP, +visível).
tui_ensure_visible() {
  local vis
  vis="$(tui_visible_rows)"
  (( vis < 1 )) && vis=1
  local total=${#TUI_VIEW[@]}
  (( TUI_SEL >= total )) && TUI_SEL=$(( total > 0 ? total - 1 : 0 ))
  (( TUI_SEL < 0 )) && TUI_SEL=0
  if (( TUI_SEL < TUI_TOP )); then TUI_TOP=$TUI_SEL; fi
  if (( TUI_SEL >= TUI_TOP + vis )); then TUI_TOP=$(( TUI_SEL - vis + 1 )); fi
  (( TUI_TOP < 0 )) && TUI_TOP=0
}

# ── Desenho: menu ─────────────────────────────────────────────────────────────
TUI_MENU_ITEMS=("Steps (ativar/desativar)" "Parâmetros (chaves de config)" "Ajuda (teclas)" "Salvar alterações" "Sair")

tui_draw_menu() {
  local i sel_mark
  tui_title_bar "menu principal"
  printf '\r\n'
  for i in "${!TUI_MENU_ITEMS[@]}"; do
    if (( i == TUI_SEL )); then sel_mark="${C_CYAN}${SYM_ARROW} ${C_RESET}${C_BOLD}"; else sel_mark="  "; fi
    tui_line " ${sel_mark}$(ui_pad "$(( i + 1 )). ${TUI_MENU_ITEMS[$i]}" $(( TUI_COLS - 6 )))${C_RESET}"
  done
  tui_footer " ↑/↓ navegar · Enter selecionar · s salvar · q sair${TUI_FILTER:+ · filtro: }${TUI_FILTER}"
}

# ── Desenho: listas (steps/params) ────────────────────────────────────────────

tui_draw_list() {
  local title="$1" i idx vis row sel flag value_disp effect_col name_w value_w desc_w
  tui_ensure_visible
  vis="$(tui_visible_rows)"

  local fdisp=""
  (( TUI_FILTER_MODE == 1 )) && fdisp="${C_CYAN}  filtro: ${TUI_FILTER}█${C_RESET}"
  tui_title_bar "$title (${#TUI_VIEW[@]} itens)$fdisp"
  printf '\r\n'

  row=0
  for (( row = 0; row < vis; row++ )); do
    idx=$(( TUI_TOP + row ))
    if (( idx >= ${#TUI_VIEW[@]} )); then
      tui_line ""
      continue
    fi
    i="${TUI_VIEW[$idx]}"
    if (( idx == TUI_SEL )); then printf '\033[7m'; fi
    case "${TUI_KIND[$i]}" in
      step)
        if [[ "${TUI_VALUE[$i]}" == "run" ]]; then
          flag="${C_GREEN}${SYM_OK}${C_RESET}"
        else
          flag="${C_YELLOW}${SYM_SKIP}${C_RESET}"
        fi
        effect_col="${TUI_META[$i]%%|*}"
        [[ "${TUI_META[$i]##*|}" == "mutating" ]] && effect_col="${effect_col}·mut"
        name_w=$(( TUI_COLS - ${#effect_col} - 8 )); (( name_w < 12 )) && name_w=12
        tui_line " $flag $(ui_pad "$(tui_trunc "${TUI_NAME[$i]}" "$name_w")" "$name_w")${C_DIM}[$effect_col]${C_RESET}"
        ;;
      bool)
        if [[ "${TUI_VALUE[$i]}" == "1" || "${TUI_VALUE[$i],,}" == "true" ]]; then
          flag="${C_GREEN}[x]${C_RESET}"
        else
          flag="${C_DIM}[ ]${C_RESET}"
        fi
        if (( TUI_COLS >= 70 )); then
          desc_w=24; name_w=$(( TUI_COLS - desc_w - 8 ))
          tui_line " $flag $(ui_pad "$(tui_trunc "${TUI_NAME[$i]}" "$name_w")" "$name_w")${C_DIM}$(tui_trunc "${TUI_DESC[$i]}" "$desc_w")${C_RESET}"
        else
          name_w=$(( TUI_COLS - 7 )); (( name_w < 12 )) && name_w=12
          tui_line " $flag $(tui_trunc "${TUI_NAME[$i]}" "$name_w")"
        fi
        ;;
      *)
        value_disp="${TUI_VALUE[$i]:-(vazio=auto)}"
        local dirty=""
        [[ "${TUI_VALUE[$i]}" != "${TUI_ORIG[$i]}" ]] && dirty="${C_YELLOW} *${C_RESET}"
        name_w=$(( TUI_COLS >= 70 ? 30 : TUI_COLS / 2 )); (( name_w < 12 )) && name_w=12
        value_w=$(( TUI_COLS - name_w - 5 )); (( value_w < 8 )) && value_w=8
        tui_line "   $(ui_pad "$(tui_trunc "${TUI_NAME[$i]}" "$name_w")" "$name_w")$(tui_trunc "$value_disp" "$value_w")${dirty}"
        ;;
    esac
    printf '\033[0m'
  done
  tui_footer " ↑/↓ · Space/t alterna · ←→ enum · Enter edita · d detalhe · / filtro · Esc menu · s salvar · q sair"
}

# ── Popup de detalhe (d) ──────────────────────────────────────────────────────

tui_draw_detail() {
  local i="${TUI_VIEW[$TUI_SEL]}" w top
  w=$(( TUI_COLS - 8 ))
  (( w < 40 )) && w=40
  top=$(( TUI_ROWS / 2 - 4 ))
  printf '\033[%d;4H\033[7m %s \033[0m' "$top" "$(ui_pad "${TUI_NAME[$i]}" "$w")"
  printf '\033[%d;4H' $(( top + 1 ))
  tui_line " $(ui_wrap "${TUI_DESC[$i]}" "$w" | head -3)"
  case "${TUI_KIND[$i]}" in
    step)
      printf '\033[%d;4H' $(( top + 4 ))
      tui_line " categoria/efeito: ${TUI_META[$i]}"
      printf '\033[%d;4H' $(( top + 5 ))
      tui_line " estado: ${TUI_VALUE[$i]}  (Space alterna; skip vai para FULL_UPGRADE_SKIP no config)"
      ;;
    enum)
      printf '\033[%d;4H' $(( top + 4 ))
      tui_line " opções: ${TUI_META[$i]:-}   ←/→ cicla"
      printf '\033[%d;4H' $(( top + 5 ))
      tui_line " valor atual: ${TUI_VALUE[$i]:-(vazio)}"
      ;;
    *)
      printf '\033[%d;4H' $(( top + 4 ))
      tui_line " tipo: ${TUI_KIND[$i]}   valor atual: ${TUI_VALUE[$i]:-(vazio)}"
      ;;
  esac
  printf '\033[%d;4H' $(( top + 6 ))
  tui_line " ${C_DIM}qualquer tecla fecha${C_RESET}"
}

# ── Ações ─────────────────────────────────────────────────────────────────────

# Alterna o item selecionado (steps e bools). Devolve 0 se mudou algo.
tui_toggle_current() {
  local i="${TUI_VIEW[$TUI_SEL]:-}"
  [[ -n "$i" ]] || return 1
  case "${TUI_KIND[$i]}" in
    step)
      [[ "${TUI_VALUE[$i]}" == "run" ]] && TUI_VALUE[$i]="skip" || TUI_VALUE[$i]="run"
      tui_collect_changes
      return 0 ;;
    bool)
      [[ "${TUI_VALUE[$i]}" == "1" || "${TUI_VALUE[$i],,}" == "true" ]] && TUI_VALUE[$i]=0 || TUI_VALUE[$i]=1
      tui_collect_changes
      return 0 ;;
  esac
  return 1
}

# Cicla enum para a direita (+1) ou esquerda (-1).
tui_cycle_enum() {
  local dir="$1" i="${TUI_VIEW[$TUI_SEL]:-}"
  [[ -n "$i" ]] || return 1
  [[ "${TUI_KIND[$i]}" == "enum" ]] || return 1
  local -a opts=()
  IFS=',' read -ra opts <<<"${TUI_META[$i]}"
  local n=${#opts[@]}
  (( n > 0 )) || return 1
  local cur="${TUI_VALUE[$i]}" pos=-1 k
  for (( k = 0; k < n; k++ )); do
    [[ "${opts[$k]}" == "$cur" ]] && { pos=$k; break; }
  done
  (( dir > 0 )) && pos=$(( (pos + 1) % n )) || pos=$(( (pos - 1 + n * 2) % n ))
  TUI_VALUE[$i]="${opts[$pos]}"
  tui_collect_changes
  return 0
}

# Prompt inline (modo cooked) para int/string/path/list. Escrita direta no
# shell (sem command substitution) para não perder o estado do TUI.
tui_prompt_value() {
  local i="${TUI_VIEW[$TUI_SEL]:-}"
  [[ -n "$i" ]] || return 1
  local kind="${TUI_KIND[$i]}" newval=""
  # Volta ao modo cooked para o read com echo/line-editing.
  [[ -n "$TUI_STTY_SAVED" ]] && stty "$TUI_STTY_SAVED" 2>/dev/null
  printf '\033[%d;1H\033[K%sNovo valor para %s [%s] (vazio cancela): %s' \
    "$TUI_ROWS" "$C_CYAN" "${TUI_NAME[$i]}" "${TUI_VALUE[$i]:-vazio}" "$C_RESET"
  if read -r -e -p "" newval; then
    if [[ "$kind" == "int" && -n "$newval" && ! "$newval" =~ ^[0-9]+$ ]]; then
      TUI_FLASH="${C_RED}valor inválido (inteiro esperado); mantido o anterior${C_RESET}"
    elif [[ -n "$newval" ]]; then
      TUI_VALUE[$i]="$newval"
      tui_collect_changes
    fi
  fi
  stty raw -echo 2>/dev/null
  return 0
}

# ── Revisão e salvamento ──────────────────────────────────────────────────────

tui_draw_review() {
  local k w per_page end
  printf '\033[H\033[2J'
  tui_title_bar "salvar — revisão"
  w=$(( TUI_COLS - 8 )); (( w < 12 )) && w=12
  # Cada alteração ocupa três linhas; reserva título, contexto e rodapé.
  per_page=$(( (TUI_ROWS - 5) / 3 )); (( per_page < 1 )) && per_page=1
  (( TUI_REVIEW_TOP >= TUI_PENDING )) && TUI_REVIEW_TOP=$(( TUI_PENDING - 1 ))
  (( TUI_REVIEW_TOP < 0 )) && TUI_REVIEW_TOP=0
  end=$(( TUI_REVIEW_TOP + per_page )); (( end > TUI_PENDING )) && end=$TUI_PENDING
  if (( TUI_PENDING == 0 )); then
    printf '\r\n'; tui_line " ${C_DIM}Nenhuma alteração pendente.${C_RESET}"
  else
    printf '\r\n'
    tui_line " ${C_BOLD}Alterações $(( TUI_REVIEW_TOP + 1 ))–$end de ${TUI_PENDING} em ${FU_CONFIG_FILE}:${C_RESET}"
    for (( k = TUI_REVIEW_TOP; k < end; k++ )); do
      printf '\r\n'
      tui_line " ${C_CYAN}[${CH_SECTION[$k]}] ${CH_KEY[$k]}${C_RESET}"
      tui_line "   ${C_RED}- $(tui_trunc "${CH_OLD[$k]}" "$w")${C_RESET}"
      tui_line "   ${C_GREEN}+ $(tui_trunc "${CH_NEW[$k]}" "$w")${C_RESET}"
    done
  fi
  if (( TUI_PENDING > per_page )); then
    tui_footer " ↑/↓ pagina · Enter aplica · Esc cancela"
  else
    tui_footer " Enter aplica · Esc cancela (volta ao menu)"
  fi
}

tui_trunc() {
  local s="$1" max="$2"
  (( ${#s} > max )) && s="${s:0:$(( max - 3 ))}..."
  printf '%s' "$s"
}

tui_do_save() {
  tui_collect_changes
  if (( TUI_PENDING == 0 )); then
    TUI_FLASH="nada a salvar"
    return 0
  fi
  # Monta pares de TODAS as telas; CH_KIND preserva o tipo do catálogo.
  local -a pairs=()
  local k
  for k in "${!CH_KEY[@]}"; do
    pairs+=("${CH_KEY[$k]}|${CH_KIND[$k]}|${CH_NEW[$k]}")
  done
  if tui_config_save_pairs "${pairs[@]}"; then
    TUI_FLASH="${C_GREEN}config gravado${C_RESET}"
    tui_mark_models_saved
    tui_rebuild_view
    return 0
  fi
  TUI_FLASH="${C_RED}falha ao gravar config (ver permissões)${C_RESET}"
  return 1
}


# ── Tela de ajuda do TUI ──────────────────────────────────────────────────────

tui_draw_help() {
  tui_title_bar "ajuda"
  printf '\r\n'
  tui_line " ${C_BOLD}Navegação${C_RESET}"
  tui_line "   ↑/↓ ou k/j  mover seleção        PgUp/PgDn  rolar página"
  tui_line "   Home/End    primeiro/último      1..5       menu: item direto"
  printf '\r\n'
  tui_line " ${C_BOLD}Edição${C_RESET}"
  tui_line "   Space ou t  alterna step/bool    ←/→        cicla opções de enum"
  tui_line "   Enter       edita int/string     d          popup de detalhe"
  printf '\r\n'
  tui_line " ${C_BOLD}Sessão${C_RESET}"
  tui_line "   /           filtro vivo (Backspace corrige, Esc sai do filtro)"
  tui_line "   s           salvar (revisão com diff e confirmação)"
  tui_line "   Esc         volta ao menu / sai do filtro"
  tui_line "   q           sair (confirma se houver mudanças não salvas)"
  printf '\r\n'
  tui_line " ${C_DIM}O TUI grava em ${FU_CONFIG_FILE}. Skips vindos do ambiente (FULL_UPGRADE_SKIP)${C_RESET}"
  tui_line " ${C_DIM}na linha de comando) não aparecem aqui — o TUI edita o arquivo.${C_RESET}"
  tui_footer " qualquer tecla volta"
}

# ── Confirmação (descartar mudanças?) ─────────────────────────────────────────

tui_confirm_discard() {
  local ans
  printf '\033[%d;1H\033[K%sDescartar %d alteração(ões) não salva(s)? (y/N)%s' \
    "$TUI_ROWS" "$C_YELLOW" "$TUI_PENDING" "$C_RESET"
  IFS= read -rsN1 ans
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# Única passagem de gravação: teclado global e item "Salvar" do menu precisam
# exibir a mesma revisão antes de tocar no arquivo.
tui_review_and_save() {
  tui_collect_changes
  if (( TUI_PENDING == 0 )); then
    TUI_FLASH="nada a salvar"
    return 0
  fi
  TUI_REVIEW_TOP=0
  tui_draw_review
  while :; do
    tui_read_key
    case "$TUI_KEY" in
      enter)
        tui_do_save
        TUI_FLASH="${TUI_FLASH}${TUI_FLASH_BAK:-}"
        TUI_FLASH_BAK=""
        return 0 ;;
      up|char:k|pgup)
        (( TUI_REVIEW_TOP > 0 )) && (( --TUI_REVIEW_TOP ))
        tui_draw_review ;;
      down|char:j|pgdn)
        (( TUI_REVIEW_TOP < TUI_PENDING - 1 )) && (( ++TUI_REVIEW_TOP ))
        tui_draw_review ;;
      esc) return 0 ;;
      char:q) TUI_QUIT=1; return 0 ;;
    esac
  done
}

# ── Loop principal ────────────────────────────────────────────────────────────

tui_enter_screen() {
  # Guarde a tela de saída antes de mudar TUI_MODE.
  tui_store_active_model
  case "$1" in
    steps)  TUI_MODE="steps";  tui_load_model steps;  TUI_SEL=0; TUI_TOP=0 ;;
    params) TUI_MODE="params"; tui_load_model params; TUI_SEL=0; TUI_TOP=0 ;;
    menu)   TUI_MODE="menu";   TUI_SEL=0; TUI_TOP=0 ;;
    help)   TUI_MODE="help" ;;
  esac
  tui_rebuild_view
  tui_collect_changes
}

# Total de itens navegáveis da tela atual: o MENU navega sobre TUI_MENU_ITEMS
# (TUI_VIEW está vazio nele); as listas navegam sobre a visão filtrada.
tui_item_count() {
  if [[ "$TUI_MODE" == "menu" ]]; then
    printf '%s' "${#TUI_MENU_ITEMS[@]}"
  else
    printf '%s' "${#TUI_VIEW[@]}"
  fi
}

tui_dispatch_nav() {
  local vis total
  vis="$(tui_visible_rows)"
  total="$(tui_item_count)"
  case "$TUI_KEY" in
    # Pré-incremento: (( x++ )) retorna o valor ANTIGO e falha (status 1)
    # quando x=0 — quebra sob errexit (bats). (( ++x )) retorna o novo.
    up|char:k)   (( TUI_SEL > 0 )) && (( --TUI_SEL )) ;;
    down|char:j) (( TUI_SEL < total - 1 )) && (( ++TUI_SEL )) ;;
    pgup) TUI_SEL=$(( TUI_SEL - vis )); (( TUI_SEL < 0 )) && TUI_SEL=0 ;;
    pgdn) TUI_SEL=$(( TUI_SEL + vis )); (( TUI_SEL >= total )) && TUI_SEL=$(( total > 0 ? total - 1 : 0 )) ;;
    home) TUI_SEL=0 ;;
    end)  TUI_SEL=$(( total > 0 ? total - 1 : 0 )) ;;
    *) return 1 ;;
  esac
  return 0
}

tui_filter_key() {
  case "$TUI_KEY" in
    backspace)
      TUI_FILTER="${TUI_FILTER%?}"
      tui_rebuild_view; TUI_SEL=0; TUI_TOP=0
      return 0 ;;
    esc)
      TUI_FILTER_MODE=0
      return 0 ;;
    enter)
      TUI_FILTER_MODE=0
      return 0 ;;
    space) TUI_FILTER+=" " ;;
    char:*) TUI_FILTER+="${TUI_KEY#char:}" ;;
    *) return 1 ;;
  esac
  tui_rebuild_view; TUI_SEL=0; TUI_TOP=0
  return 0
}

tui_handle_key() {
  # Filtro vivo tem precedência na tela de listas.
  if (( TUI_FILTER_MODE == 1 )) && [[ "$TUI_MODE" != "menu" ]]; then
    tui_filter_key
    return 0
  fi

  # Globais
  case "$TUI_KEY" in
    char:s) tui_review_and_save; return 0 ;;
    char:q)
      if (( TUI_PENDING > 0 )); then
        tui_confirm_discard && TUI_QUIT=1
      else
        TUI_QUIT=1
      fi
      return 0 ;;
    char:/)
      if [[ "$TUI_MODE" == "steps" || "$TUI_MODE" == "params" ]]; then
        TUI_FILTER_MODE=1
      fi
      return 0 ;;
    esc)
      if [[ -n "$TUI_FILTER" && "$TUI_MODE" != "menu" ]]; then
        TUI_FILTER=""; tui_rebuild_view; TUI_SEL=0; TUI_TOP=0
      elif [[ "$TUI_MODE" != "menu" ]]; then
        tui_enter_screen menu
      fi
      return 0 ;;
  esac

  case "$TUI_MODE" in
    menu)
      case "$TUI_KEY" in
        char:1) tui_enter_screen steps ;;
        char:2) tui_enter_screen params ;;
        char:3) TUI_MODE="help" ;;
        char:4) tui_review_and_save ;;
        char:5)
          if (( TUI_PENDING > 0 )); then
            tui_confirm_discard && TUI_QUIT=1
          else
            TUI_QUIT=1
          fi
          ;;
        enter)
          case "$TUI_SEL" in
            0) tui_enter_screen steps ;;
            1) tui_enter_screen params ;;
            2) TUI_MODE="help" ;;
            3) tui_review_and_save ;;
            4)
              if (( TUI_PENDING > 0 )); then
                tui_confirm_discard && TUI_QUIT=1
              else
                TUI_QUIT=1
              fi
              ;;
          esac
          ;;
        up|down|char:k|char:j|pgup|pgdn|home|end) tui_dispatch_nav ;;
      esac
      ;;
    steps|params)
      case "$TUI_KEY" in
        up|down|char:k|char:j|pgup|pgdn|home|end) tui_dispatch_nav ;;
        space|char:t) tui_toggle_current || true ;;
        left)  tui_cycle_enum -1 || true ;;
        right) tui_cycle_enum  1 || true ;;
        char:d) TUI_DRAW_DETAIL=1 ;;
        enter)
          case "${TUI_KIND[${TUI_VIEW[$TUI_SEL]:-0}]:-}" in
            bool|step) tui_toggle_current || true ;;
            enum)      tui_cycle_enum 1 || true ;;
            int|string|path|list) tui_prompt_value || true ;;
          esac
          ;;
      esac
      ;;
    help)
      TUI_MODE="menu"
      ;;
  esac
  return 0
}

# ── Entry point do --config-tui ───────────────────────────────────────────────

config_tui_main() {
  # TUI precisa de terminal interativo real (stdin E stdout TTYs).
  if [[ ! -t 0 || ! -t 1 ]]; then
    printf '%sO TUI de configuração precisa de um terminal interativo.%s\n' \
      "$C_YELLOW" "$C_RESET" >&2
    printf 'Alternativas não interativas:\n' >&2
    printf '  full-upgrade --config          valores efetivos + exemplo\n' >&2
    printf '  full-upgrade --config-example  exemplo comentado (pipe-friendly)\n' >&2
    printf 'Ou edite direto: %s\n' "$FU_CONFIG_FILE" >&2
    return 2
  fi

  TUI_QUIT=0
  TUI_FLASH=""
  TUI_FLASH_BAK=""
  TUI_DRAW_DETAIL=0
  tui_enter_screen menu
  tui_open
  # Garante restauração do terminal em QUALQUER saída (Ctrl-C incluso).
  trap 'tui_close' EXIT INT TERM

  local first_draw=1
  while (( TUI_QUIT == 0 )); do
    tui_update_size
    case "$TUI_MODE" in
      menu)   tui_draw_menu ;;
      steps)  tui_draw_list "steps" ;;
      params) tui_draw_list "parâmetros" ;;
      help)   tui_draw_help ;;
    esac
    if (( ${TUI_DRAW_DETAIL:-0} == 1 )); then
      tui_draw_detail
      TUI_DRAW_DETAIL=0
      tui_read_key   # qualquer tecla fecha o popup
    fi
    TUI_FLASH=""   # flash dura um ciclo de desenho
    tui_read_key
    tui_handle_key
  done

  tui_close
  trap - EXIT INT TERM
  return 0
}
