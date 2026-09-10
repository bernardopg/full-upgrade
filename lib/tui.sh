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

# Marcado por SIGWINCH (ou 1ª chamada). Evita 2 forks de `tput` por tecla —
# principal causa do lag/overshoot com auto-repeat das setas.
TUI_SIZE_DIRTY=1

tui_update_size() {
  (( ${TUI_SIZE_DIRTY:-1} == 0 )) && [[ -n "${TUI_ROWS:-}" && -n "${TUI_COLS:-}" ]] && return 0
  TUI_SIZE_DIRTY=0
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
  local c rest="" extra="" st=0
  # st > 128 ⇒ read interrompido por sinal (ex.: SIGWINCH): não é Esc.
  IFS= read -rsN1 c || st=$?
  if (( st != 0 )); then
    if (( st > 128 )); then TUI_KEY="none"; else TUI_KEY="esc"; fi
    return 0
  fi
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

# Glifos de moldura/estado do TUI (Unicode com fallback ASCII). Reaproveita a
# mesma detecção do lib/ui.sh: se SYM_ARROW virou ">" estamos em modo ASCII.
if [[ "${SYM_ARROW:-}" == "▶" ]]; then
  TUI_BOX_TL="╭"; TUI_BOX_TR="╮"; TUI_BOX_BL="╰"; TUI_BOX_BR="╯"
  TUI_BOX_H="─"; TUI_BOX_V="│"
  TUI_SEL_BAR="▌"; TUI_SB_TRACK="│"; TUI_SB_THUMB="┃"
  TUI_DOT_ON="●"; TUI_DOT_OFF="○"; TUI_DIRTY="•"
  TUI_ICON_STEPS="▶"; TUI_ICON_PARAMS="→"; TUI_ICON_HELP="?"
  TUI_ICON_SAVE="↓"; TUI_ICON_QUIT="×"
  TUI_LOGO=(
    "┏━╸╻ ╻╻  ╻    ╻ ╻┏━┓┏━╸┏━┓┏━┓╺┳┓┏━╸"
    "┣╸ ┃ ┃┃  ┃    ┃ ┃┣━┛┃╺┓┣┳┛┣━┫ ┃┃┣╸ "
    "╹  ┗━┛┗━╸┗━╸  ┗━┛╹  ┗━┛╹┗╸╹ ╹╺┻┛┗━╸"
  )
else
  TUI_BOX_TL="+"; TUI_BOX_TR="+"; TUI_BOX_BL="+"; TUI_BOX_BR="+"
  TUI_BOX_H="-"; TUI_BOX_V="|"
  TUI_SEL_BAR=">"; TUI_SB_TRACK="|"; TUI_SB_THUMB="#"
  TUI_DOT_ON="*"; TUI_DOT_OFF="-"; TUI_DIRTY="*"
  TUI_ICON_STEPS=">"; TUI_ICON_PARAMS="="; TUI_ICON_HELP="?"
  TUI_ICON_SAVE="v"; TUI_ICON_QUIT="x"
  TUI_LOGO=(
    " ___ _   _ _    _       _   _ ___  ___ ___  _   ___  ___ "
    "| __| | | | |  | |  ___| | | | _ \\/ __| _ \\/_\\ |   \\| __|"
    "|_|  \\_,_|_|__|_|__    \\___/|  _/\\__ \\   / _ \\| |) | _| "
  )
fi

TUI_HEAD_H=5           # altura do cabeçalho (logo + breadcrumb + régua)
TUI_W=76               # largura útil de conteúdo (recalculada por desenho)
TUI_ROWW=74            # largura do conteúdo de uma linha de item
TUI_MARGIN=2           # recuo à esquerda do conteúdo

tui_line() {
  # \r\n: em raw mode (stty raw) o ONLCR está desligado — \n sozinho não volta
  # à coluna 0 e o layout desandaria.
  printf '\033[K%s\r\n' "$1"
}

# Largura útil: nunca ocupa a tela inteira em monitores largos (o texto ficaria
# com as colunas da direita a metros do nome). Cap em 100 colunas.
tui_metrics() {
  TUI_W=$(( TUI_COLS - TUI_MARGIN * 2 ))
  (( TUI_W > 100 )) && TUI_W=100
  (( TUI_W < 36 )) && TUI_W=36
  # Conteúdo de uma linha de item: largura útil menos o marcador de seleção
  # (1 col à esquerda) e a barra de rolagem (1 col à direita).
  TUI_ROWW=$(( TUI_W - 2 ))
  # Cabeçalho completo só em terminais com espaço; senão versão de 2 linhas.
  if (( TUI_ROWS >= 22 && TUI_COLS >= 56 )); then TUI_HEAD_H=5; else TUI_HEAD_H=2; fi
  return 0
}

# Versões sem subshell de ui_pad/ui_pad_left/tui_trunc: escrevem em TUI_PAD.
# São o caminho quente do desenho (uma lista cheia fazia ~5 forks por linha,
# o que dominava o custo do frame). Medem em CARACTERES (${#s}), então nomes
# acentuados continuam alinhando.
tui_padv() {
  local s="$1" n=$(( $2 - ${#1} ))
  if (( n > 0 )); then printf -v TUI_PAD '%s%*s' "$s" "$n" ''; else TUI_PAD="$s"; fi
}

tui_padlv() {
  local s="$1" n=$(( $2 - ${#1} ))
  if (( n > 0 )); then printf -v TUI_PAD '%*s%s' "$n" '' "$s"; else TUI_PAD="$s"; fi
}

tui_truncv() {
  local s="$1" max="$2"
  (( ${#s} > max )) && s="${s:0:$(( max - 3 ))}..."
  TUI_PAD="$s"
}

# Trunca e preenche em uma passada (coluna de largura fixa).
tui_colv() {
  tui_truncv "$1" "$2"
  tui_padv "$TUI_PAD" "$2"
}

# Régua horizontal da largura útil.
tui_rule() {
  local w="${1:-$TUI_W}" i rule=""
  for (( i = 0; i < w; i++ )); do rule+="$TUI_BOX_H"; done
  printf '%s' "$rule"
}

# Cabeçalho: logo ASCII + trilha (breadcrumb) + badge de pendências + régua.
tui_draw_header() {
  local crumb="$1" extra="${2:-}" pad i
  pad="$(printf '%*s' "$TUI_MARGIN" '')"
  printf '\033[H'
  if (( TUI_HEAD_H == 5 )); then
    for i in 0 1 2; do
      tui_line "${pad}${C_CYAN}${TUI_LOGO[$i]}${C_RESET}"
    done
  fi
  local badge=""
  if (( TUI_PENDING > 0 )); then
    badge="  ${C_YELLOW}${TUI_DIRTY} ${TUI_PENDING} não salva(s)${C_RESET}"
  else
    badge="  ${C_GREEN}${SYM_OK} salvo${C_RESET}"
  fi
  tui_line "${pad}${C_BOLD}configuração${C_RESET} ${C_DIM}${SYM_ARROW}${C_RESET} ${C_BOLD}${crumb}${C_RESET}${badge}${extra}"
  tui_line "${pad}${C_DIM}$(tui_rule)${C_RESET}"
}

# Rodapé: régua + linha de teclas (ou flash, que tem prioridade por 1 ciclo).
tui_footer() {
  local hints="$1" pad
  pad="$(printf '%*s' "$TUI_MARGIN" '')"
  printf '\033[%d;1H\033[K%s%s%s' "$(( TUI_ROWS - 1 ))" "${pad}${C_DIM}" "$(tui_rule)" "$C_RESET"
  if [[ -n "$TUI_FLASH" ]]; then
    printf '\033[%d;1H\033[K%s%s%s\033[J' "$TUI_ROWS" "${pad}${C_BOLD}${C_YELLOW}" "$TUI_FLASH" "$C_RESET"
  else
    printf '\033[%d;1H\033[K%s%s%s\033[J' "$TUI_ROWS" "${pad}${C_DIM}" "$hints" "$C_RESET"
  fi
}

tui_visible_rows() {
  echo $(( TUI_ROWS - TUI_HEAD_H - 2 ))
}

# Versão sem subshell (usada nos caminhos quentes de desenho/navegação).
tui_visible_rows_var() {
  TUI_VIS=$(( TUI_ROWS - TUI_HEAD_H - 2 ))
  (( TUI_VIS < 1 )) && TUI_VIS=1
  return 0
}

# Rola para manter TUI_SEL visível dentro da janela [TUI_TOP, +visível).
tui_ensure_visible() {
  local vis
  tui_visible_rows_var; vis=$TUI_VIS
  local total=${#TUI_VIEW[@]}
  (( TUI_SEL >= total )) && TUI_SEL=$(( total > 0 ? total - 1 : 0 ))
  (( TUI_SEL < 0 )) && TUI_SEL=0
  if (( TUI_SEL < TUI_TOP )); then TUI_TOP=$TUI_SEL; fi
  if (( TUI_SEL >= TUI_TOP + vis )); then TUI_TOP=$(( TUI_SEL - vis + 1 )); fi
  (( TUI_TOP < 0 )) && TUI_TOP=0
}

# Imprime uma linha de item já com largura fixa: selecionada sai em vídeo
# reverso ocupando a largura TODA (sem highlight serrilhado), não selecionada
# sai com as cores por coluna. Por isso cada chamador monta duas versões:
# $2 = texto puro (para o reverso, onde qualquer C_RESET desligaria o realce)
# $3 = texto colorido.
tui_row() {
  local selected="$1" plain="$2" colored="$3" sb="${4:- }" pad
  pad="$(printf '%*s' "$TUI_MARGIN" '')"
  if (( selected == 1 )); then
    tui_padv "$plain" "$TUI_ROWW"
    printf '\033[K%s%s%s\033[7m%s\033[0m%s\r\n' \
      "$pad" "$C_CYAN" "$TUI_SEL_BAR" "$TUI_PAD" "$sb"
  else
    # $colored tem ANSI: o preenchimento sai do comprimento de $plain (mesmo
    # texto visível), senão a barra de rolagem dançaria de linha para linha.
    local fill=$(( TUI_ROWW - ${#plain} )); (( fill < 0 )) && fill=0
    printf '\033[K%s %s%*s%s\r\n' "$pad" "$colored" "$fill" '' "$sb"
  fi
}

# (embutida em tui_draw_list — ver SB_* lá)

# ── Desenho: menu ─────────────────────────────────────────────────────────────
TUI_MENU_ITEMS=("Steps (ativar/desativar)" "Parâmetros (chaves de config)" "Ajuda (teclas)" "Salvar alterações" "Sair")

tui_draw_menu() {
  local i icon hint plain colored pad
  tui_metrics
  pad="$(printf '%*s' "$TUI_MARGIN" '')"
  tui_draw_header "menu principal"
  tui_line ""
  local icons=("$TUI_ICON_STEPS" "$TUI_ICON_PARAMS" "$TUI_ICON_HELP" "$TUI_ICON_SAVE" "$TUI_ICON_QUIT")
  local hints=(
    "liga/desliga steps do catálogo"
    "bool · enum · números · caminhos"
    "teclas e navegação"
    "grava em $(basename "${FU_CONFIG_FILE:-config}")"
    "encerra (confirma se houver pendências)"
  )
  local name_w=$(( TUI_W / 2 )); (( name_w < 24 )) && name_w=24
  local hint_w=$(( TUI_W - name_w - 8 )); (( hint_w < 6 )) && hint_w=6
  for i in "${!TUI_MENU_ITEMS[@]}"; do
    icon="${icons[$i]}"; hint="$(tui_trunc "${hints[$i]}" "$hint_w")"
    plain=" $icon  $(ui_pad "$(( i + 1 )). ${TUI_MENU_ITEMS[$i]}" "$name_w")$hint"
    colored=" ${C_CYAN}${icon}${C_RESET}  ${C_BOLD}$(ui_pad "$(( i + 1 )). ${TUI_MENU_ITEMS[$i]}" "$name_w")${C_RESET}${C_DIM}${hint}${C_RESET}"
    tui_row "$(( i == TUI_SEL ? 1 : 0 ))" "$plain" "$colored"
  done
  tui_line ""
  tui_line "${pad}${C_DIM}arquivo: ${FU_CONFIG_FILE}${C_RESET}"
  # Limpa o resto da tela: sem isso, sobras da tela anterior (lista de steps,
  # ajuda) continuam visíveis abaixo do menu.
  printf '\033[J'
  tui_footer "↑/↓ navegar · 1-5 atalho · Enter selecionar · s salvar · q sair"
}

# ── Desenho: listas (steps/params) ────────────────────────────────────────────

tui_draw_list() {
  local title="$1" i idx vis row sel flag plain colored sb pad
  local sb_t="$C_CYAN$TUI_SB_THUMB$C_RESET" sb_k="$C_DIM$TUI_SB_TRACK$C_RESET"
  local rowsv sb_on=0 sb_start=0 sb_end=0 sb_thumb_n sb_maxtop
  tui_metrics
  pad="$(printf '%*s' "$TUI_MARGIN" '')"
  tui_ensure_visible
  tui_visible_rows_var; vis=$TUI_VIS

  local fdisp=""
  if (( TUI_FILTER_MODE == 1 )); then
    fdisp="  ${C_CYAN}/${TUI_FILTER}█${C_RESET}"
  elif [[ -n "$TUI_FILTER" ]]; then
    fdisp="  ${C_CYAN}/${TUI_FILTER}${C_RESET}"
  fi
  tui_draw_header "$title ${C_DIM}(${#TUI_VIEW[@]} itens)${C_RESET}" "$fdisp"

  # Larguras de coluna — fixas para a tela inteira, o que mantém todas as
  # linhas alinhadas independentemente do conteúdo de cada item.
  # avail = largura EXATA do conteúdo de cada linha (a última coluna da largura
  # útil fica com a barra de rolagem). Todas as colunas somam avail, de modo que
  # linha selecionada (vídeo reverso preenchido) e não selecionada terminam na
  # mesma coluna — é o que mantém as tags/valores alinhados.
  local avail=$TUI_ROWW
  local tag_w=18 kind_w=6 name_w value_w desc_w
  local total=${#TUI_VIEW[@]}
  local is_steps=0; [[ "$TUI_MODE" == "steps" ]] && is_steps=1
  if (( is_steps == 1 )); then
    name_w=$(( avail - tag_w - 6 )); (( name_w < 16 )) && name_w=16
    tui_line "${pad}      ${C_DIM}$(ui_pad "step" "$name_w")$(ui_pad_left "categoria" "$tag_w")${C_RESET}"
  else
    name_w=$(( avail * 34 / 100 )); (( name_w < 16 )) && name_w=16
    value_w=$(( avail * 24 / 100 )); (( value_w < 8 )) && value_w=8
    desc_w=$(( avail - name_w - value_w - kind_w - 4 )); (( desc_w < 0 )) && desc_w=0
    tui_line "${pad}   ${C_DIM}$(ui_pad "tipo" "$kind_w") $(ui_pad "chave" "$name_w")$(ui_pad "valor" "$value_w")descrição${C_RESET}"
  fi

  rowsv=$(( vis - 1 ))
  if (( total > rowsv )); then
    sb_on=1
    sb_thumb_n=$(( rowsv * rowsv / total )); (( sb_thumb_n < 1 )) && sb_thumb_n=1
    sb_maxtop=$(( total - rowsv )); (( sb_maxtop < 1 )) && sb_maxtop=1
    sb_start=$(( TUI_TOP * (rowsv - sb_thumb_n) / sb_maxtop ))
    sb_end=$(( sb_start + sb_thumb_n ))
  fi
  for (( row = 0; row < rowsv; row++ )); do
    idx=$(( TUI_TOP + row ))
    if (( sb_on == 0 )); then sb=" "
    elif (( row >= sb_start && row < sb_end )); then sb="$sb_t"
    else sb="$sb_k"; fi
    if (( idx >= total )); then
      printf '\033[K\r\n'
      continue
    fi
    i="${TUI_VIEW[$idx]}"
    sel=$(( idx == TUI_SEL ? 1 : 0 ))
    case "${TUI_KIND[$i]}" in
      step)
        local tag="${TUI_META[$i]%%|*}"
        [[ "${TUI_META[$i]##*|}" == "mutating" ]] && tag="${tag}·mut"
        local nm tg
        tui_colv "${TUI_NAME[$i]}" "$name_w"; nm="$TUI_PAD"
        tui_padlv "[$tag]" "$tag_w"; tg="$TUI_PAD"
        local mk=" "; [[ "${TUI_VALUE[$i]}" != "${TUI_ORIG[$i]}" ]] && mk="$TUI_DIRTY"
        if [[ "${TUI_VALUE[$i]}" == "run" ]]; then
          plain=" $mk $TUI_DOT_ON  $nm$tg"
          colored=" ${C_YELLOW}${mk}${C_RESET} ${C_GREEN}${TUI_DOT_ON}${C_RESET}  ${nm}${C_DIM}${tg}${C_RESET}"
        else
          plain=" $mk $TUI_DOT_OFF  $nm$tg"
          colored=" ${C_YELLOW}${mk}${C_RESET} ${C_YELLOW}${TUI_DOT_OFF}${C_RESET}  ${C_DIM}${nm}${tg}${C_RESET}"
        fi
        ;;
      bool)
        local on=0
        [[ "${TUI_VALUE[$i]}" == "1" || "${TUI_VALUE[$i],,}" == "true" ]] && on=1
        local box; (( on == 1 )) && box="[x]" || box="[ ]"
        local nm vl ds kd
        tui_padv "$box" "$kind_w"; kd="$TUI_PAD"
        tui_colv "${TUI_NAME[$i]}" "$name_w"; nm="$TUI_PAD"
        tui_padv "$( (( on == 1 )) && printf 'on' || printf 'off')" "$value_w"; vl="$TUI_PAD"
        tui_truncv "${TUI_DESC[$i]}" "$desc_w"; ds="$TUI_PAD"
        local mk=" "; [[ "${TUI_VALUE[$i]}" != "${TUI_ORIG[$i]}" ]] && mk="$TUI_DIRTY"
        plain=" $mk $kd $nm$vl$ds"
        if (( on == 1 )); then
          colored=" ${C_YELLOW}${mk}${C_RESET} ${C_GREEN}${kd}${C_RESET} ${nm}${C_GREEN}${vl}${C_RESET}${C_DIM}${ds}${C_RESET}"
        else
          colored=" ${C_YELLOW}${mk}${C_RESET} ${C_DIM}${kd}${C_RESET} ${nm}${C_DIM}${vl}${ds}${C_RESET}"
        fi
        ;;
      *)
        local kd nm vl ds
        tui_padv "${TUI_KIND[$i]:0:$kind_w}" "$kind_w"; kd="$TUI_PAD"
        tui_colv "${TUI_NAME[$i]}" "$name_w"; nm="$TUI_PAD"
        tui_colv "${TUI_VALUE[$i]:-(auto)}" "$value_w"; vl="$TUI_PAD"
        tui_truncv "${TUI_DESC[$i]}" "$desc_w"; ds="$TUI_PAD"
        local mk=" "; [[ "${TUI_VALUE[$i]}" != "${TUI_ORIG[$i]}" ]] && mk="$TUI_DIRTY"
        plain=" $mk $kd $nm$vl$ds"
        colored=" ${C_YELLOW}${mk}${C_RESET} ${C_DIM}${kd}${C_RESET} ${nm}${C_CYAN}${vl}${C_RESET}${C_DIM}${ds}${C_RESET}"
        ;;
    esac
    tui_row "$sel" "$plain" "$colored" "$sb"
  done
  if (( is_steps == 1 )); then
    tui_footer "↑/↓ · Space alterna · d detalhe · / filtro · Esc menu · s salvar · q sair"
  else
    tui_footer "↑/↓ · ←/→ enum · Space bool · Enter edita · d detalhe · / filtro · Esc menu · s salvar"
  fi
}

# ── Popup de detalhe (d) ──────────────────────────────────────────────────────

# Uma linha interna do popup, com bordas laterais.
tui_popup_line() {
  local row="$1" col="$2" w="$3" text="$4" plain="$5"
  printf '\033[%d;%dH%s%s%s %s %s%s%s' "$row" "$col" \
    "$C_CYAN" "$TUI_BOX_V" "$C_RESET" "$text" \
    "$C_CYAN" "$(ui_pad_left "$TUI_BOX_V" "$(( w - ${#plain} + 1 ))")" "$C_RESET"
}

tui_draw_detail() {
  local i="${TUI_VIEW[$TUI_SEL]}" w top col line n=0
  w=$(( TUI_W - 8 )); (( w > 72 )) && w=72; (( w < 34 )) && w=34
  col=$(( TUI_MARGIN + 3 ))
  top=$(( TUI_ROWS / 2 - 5 )); (( top < 2 )) && top=2

  # Corpo do popup (linhas já truncadas na largura útil).
  local -a body=()
  while IFS= read -r line; do body+=("$line"); done < <(ui_wrap "${TUI_DESC[$i]}" "$w" | head -3)
  body+=("")
  case "${TUI_KIND[$i]}" in
    step)
      body+=("$(tui_trunc "categoria/efeito : ${TUI_META[$i]//|/ · }" "$w")")
      body+=("$(tui_trunc "estado           : ${TUI_VALUE[$i]}" "$w")")
      body+=("$(tui_trunc "Space alterna; 'skip' entra em FULL_UPGRADE_SKIP" "$w")")
      ;;
    enum)
      body+=("$(tui_trunc "opções  : ${TUI_META[$i]:-} (←/→ cicla)" "$w")")
      body+=("$(tui_trunc "atual   : ${TUI_VALUE[$i]:-(vazio)}" "$w")")
      body+=("$(tui_trunc "original: ${TUI_ORIG[$i]:-(vazio)}" "$w")")
      ;;
    *)
      body+=("$(tui_trunc "tipo    : ${TUI_KIND[$i]}" "$w")")
      body+=("$(tui_trunc "atual   : ${TUI_VALUE[$i]:-(vazio)}" "$w")")
      body+=("$(tui_trunc "original: ${TUI_ORIG[$i]:-(vazio)}" "$w")")
      ;;
  esac

  # Moldura + título.
  local hr; hr="$(tui_rule "$(( w + 2 ))")"
  printf '\033[%d;%dH%s%s%s%s%s' "$top" "$col" "$C_CYAN" "$TUI_BOX_TL" "$hr" "$TUI_BOX_TR" "$C_RESET"
  local title; title="$(tui_trunc "${TUI_NAME[$i]}" "$w")"
  tui_popup_line "$(( top + 1 ))" "$col" "$w" "${C_BOLD}${title}${C_RESET}" "$title"
  tui_popup_line "$(( top + 2 ))" "$col" "$w" "${C_DIM}$(tui_rule "$w")${C_RESET}" "$(tui_rule "$w")"
  for (( n = 0; n < ${#body[@]}; n++ )); do
    tui_popup_line "$(( top + 3 + n ))" "$col" "$w" "${body[$n]}" "${body[$n]}"
  done
  tui_popup_line "$(( top + 3 + n ))" "$col" "$w" "${C_DIM}qualquer tecla fecha${C_RESET}" "qualquer tecla fecha"
  printf '\033[%d;%dH%s%s%s%s%s' "$(( top + 4 + n ))" "$col" "$C_CYAN" "$TUI_BOX_BL" "$hr" "$TUI_BOX_BR" "$C_RESET"
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
  local k w per_page end pad
  printf '\033[H\033[2J'
  tui_metrics
  pad="$(printf '%*s' "$TUI_MARGIN" '')"
  tui_draw_header "salvar ${SYM_ARROW} revisão"
  w=$(( TUI_W - 8 )); (( w < 12 )) && w=12
  # Cada alteração ocupa três linhas; reserva cabeçalho, contexto e rodapé.
  per_page=$(( (TUI_ROWS - TUI_HEAD_H - 4) / 3 )); (( per_page < 1 )) && per_page=1
  (( TUI_REVIEW_TOP >= TUI_PENDING )) && TUI_REVIEW_TOP=$(( TUI_PENDING - 1 ))
  (( TUI_REVIEW_TOP < 0 )) && TUI_REVIEW_TOP=0
  end=$(( TUI_REVIEW_TOP + per_page )); (( end > TUI_PENDING )) && end=$TUI_PENDING
  tui_line ""
  if (( TUI_PENDING == 0 )); then
    tui_line "${pad} ${C_DIM}Nenhuma alteração pendente.${C_RESET}"
  else
    tui_line "${pad} ${C_BOLD}$(( TUI_REVIEW_TOP + 1 ))–$end de ${TUI_PENDING}${C_RESET}${C_DIM} → ${FU_CONFIG_FILE}${C_RESET}"
    for (( k = TUI_REVIEW_TOP; k < end; k++ )); do
      tui_line ""
      tui_line "${pad} ${C_CYAN}${SYM_ARROW} ${CH_KEY[$k]}${C_RESET} ${C_DIM}[${CH_SECTION[$k]}]${C_RESET}"
      tui_line "${pad}   ${C_DIM}${TUI_BOX_V}${C_RESET} ${C_RED}- $(tui_trunc "${CH_OLD[$k]}" "$w")${C_RESET}"
      tui_line "${pad}   ${C_DIM}${TUI_BOX_V}${C_RESET} ${C_GREEN}+ $(tui_trunc "${CH_NEW[$k]}" "$w")${C_RESET}"
    done
  fi
  printf '\033[J'
  if (( TUI_PENDING > per_page )); then
    tui_footer "↑/↓ pagina · Enter aplica · Esc cancela"
  else
    tui_footer "Enter aplica · Esc cancela (volta ao menu)"
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
  local pad
  tui_metrics
  pad="$(printf '%*s' "$TUI_MARGIN" '')"
  tui_draw_header "ajuda"
  tui_line ""
  tui_help_section "Navegação" \
    "↑/↓  k/j     mover seleção" \
    "PgUp/PgDn    rolar página" \
    "Home/End     primeiro/último item" \
    "1..5         no menu, item direto"
  tui_help_section "Edição" \
    "Space  t     alterna step / bool" \
    "←/→          cicla opções de enum" \
    "Enter        edita int / texto / caminho" \
    "d            popup de detalhe do item"
  tui_help_section "Sessão" \
    "/            filtro vivo (Backspace corrige, Esc sai)" \
    "s            salvar (revisão com diff e confirmação)" \
    "Esc          volta ao menu / sai do filtro" \
    "q            sair (confirma se houver pendências)"
  tui_line ""
  tui_line "${pad}${C_DIM}${TUI_DOT_ON} run   ${TUI_DOT_OFF} skip   ${TUI_DIRTY} alterado (ainda não salvo)${C_RESET}"
  tui_line "${pad}${C_DIM}O TUI grava em ${FU_CONFIG_FILE}; skips vindos do ambiente${C_RESET}"
  tui_line "${pad}${C_DIM}(FULL_UPGRADE_SKIP na linha de comando) não aparecem aqui.${C_RESET}"
  printf '\033[J'   # remove sobras de telas mais longas (lista de steps)
  tui_footer "qualquer tecla volta"
}

# Bloco "título + linhas" da ajuda, com marcador e recuo consistentes.
tui_help_section() {
  local title="$1"; shift
  local pad line
  pad="$(printf '%*s' "$TUI_MARGIN" '')"
  tui_line "${pad} ${C_CYAN}${SYM_ARROW}${C_RESET} ${C_BOLD}${title}${C_RESET}"
  for line in "$@"; do
    tui_line "${pad}   ${C_DIM}${TUI_BOX_V}${C_RESET} ${line}"
  done
  tui_line ""
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
  tui_visible_rows_var; vis=$TUI_VIS
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
  # Só relê o tamanho do terminal quando ele realmente muda.
  trap 'TUI_SIZE_DIRTY=1' WINCH

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
    # Coalescência de auto-repeat: enquanto houver teclas já no buffer do
    # terminal, processa-as SEM redesenhar. Sem isso, cada tecla repetida
    # dispara um redesenho completo (dezenas de forks), o buffer cresce mais
    # rápido do que o desenho e a lista continua rolando depois de soltar a
    # tecla. O limite evita laço infinito caso o stdin chegue a EOF.
    local _drained=0
    while (( TUI_QUIT == 0 )) && (( ${TUI_DRAW_DETAIL:-0} == 0 )) \
          && (( _drained < 512 )) && read -t 0 2>/dev/null; do
      _drained=$(( _drained + 1 ))
      tui_read_key
      [[ "$TUI_KEY" == "none" ]] && continue
      tui_handle_key
    done
  done

  tui_close
  trap - EXIT INT TERM WINCH
  return 0
}
