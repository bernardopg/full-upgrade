#!/usr/bin/env bats
# tests/tui.bats — TUI de configuração: funções puras + gravação segura (R2)
#
# O TUI interativo em si (raw mode, teclado) não é testável aqui; o que é
# testado: catálogos, toggle/diff, quoting, upsert, save com backup e merge,
# recusa sem TTY e validação de valor.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/config.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/tui.sh"
  NO_COLOR=1
  COLUMNS=120
  # IMPORTANTE: config.sh REDEFINE FU_CONFIG_DIR/FU_CONFIG_FILE no source
  # (para o config real do usuário). Todo teste aponta para um isolado DEPOIS
  # do source — nunca antes.
  FU_CONFIG_FILE="${BATS_TEST_TMPDIR}/tui-config"
  export FU_CONFIG_FILE
  : >"$FU_CONFIG_FILE"
  TUI_FILTER=""
  TUI_FILTER_MODE=0
}

teardown() {
  # Rede de segurança: garante que nenhum teste mexeu no config real.
  [[ "$FU_CONFIG_FILE" == "${BATS_TEST_TMPDIR}"* ]] || {
    echo "FALHA DE ISOLAMENTO: FU_CONFIG_FILE aponta fora do tmpdir" >&2
    return 1
  }
}

# ── catálogos ─────────────────────────────────────────────────────────────────

@test "tui_param_catalog: chaves conhecidas presentes com tipo" {
  run tui_param_catalog
  [[ "$output" == *"REPORT_ON_FINISH|bool|"* ]]
  [[ "$output" == *"LANG_OVERRIDE|enum|auto,pt,en|"* ]]
  [[ "$output" == *"SNAPSHOT_KEEP|int|"* ]]
}

@test "tui_param_catalog: toda chave está em config_known_keys" {
  local bad=0 key
  while IFS='|' read -r key _rest; do
    [[ -n "$key" ]] || continue
    config_known_keys | grep -qx "$key" || { bad=1; echo "chave fora do known_keys: $key" >&2; }
  done < <(tui_param_catalog)
  [ "$bad" -eq 0 ]
}

@test "tui_build_steps: exclui core/final e cobre o resto" {
  tui_build_steps
  [ "${#TUI_NAME[@]}" -gt 0 ]
  local i
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_KIND[$i]}" == "step" ]]
  done
}

@test "tui_build_steps: estado inicial vem do ARQUIVO de config, não do ambiente" {
  printf 'FULL_UPGRADE_SKIP="Atualizar Ollama"\n' >"$FU_CONFIG_FILE"
  FULL_UPGRADE_SKIP="Atualizar Ollama,Atualizar Bun" tui_build_steps
  local i_ollama="" i_bun="" i
  for i in "${!TUI_NAME[@]}"; do
    case "${TUI_NAME[$i]}" in
      "Atualizar Ollama") i_ollama=$i ;;
      "Atualizar Bun")    i_bun=$i ;;
    esac
  done
  [ -n "$i_ollama" ] && [ -n "$i_bun" ]
  [ "${TUI_VALUE[$i_ollama]}" = "skip" ]
  # "Atualizar Bun" veio só do ambiente: o TUI NÃO o marca (edita o arquivo)
  [ "${TUI_VALUE[$i_bun]}" = "run" ]
}

# ── view / filtro ─────────────────────────────────────────────────────────────

@test "tui_rebuild_view: filtro por substring (case-insensitive)" {
  tui_build_steps
  TUI_FILTER="ollama"
  tui_rebuild_view
  [ "${#TUI_VIEW[@]}" -ge 1 ]
  [[ "${TUI_NAME[${TUI_VIEW[0]}]}" == *"Ollama"* ]]
}

@test "tui_rebuild_view: filtro vazio mostra tudo" {
  tui_build_params
  TUI_FILTER=""
  tui_rebuild_view
  [ "${#TUI_VIEW[@]}" -eq "${#TUI_NAME[@]}" ]
}

# ── toggle e diff ─────────────────────────────────────────────────────────────

@test "tui_toggle_current: alterna step e gera diff de FULL_UPGRADE_SKIP" {
  printf 'FULL_UPGRADE_SKIP="Atualizar ghcup"\n' >"$FU_CONFIG_FILE"
  TUI_MODE="steps"
  tui_build_steps
  local i
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "Atualizar Ollama" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; }
  done
  tui_toggle_current   # chamada direta: run() executaria em subshell
  tui_collect_changes
  [ "$TUI_PENDING" -eq 1 ]
  [ "${CH_KEY[0]}" = "FULL_UPGRADE_SKIP" ]
  [[ "${CH_NEW[0]}" == *"Atualizar Ollama"* ]]
  # ghcup (já skipado no arquivo) permanece no CSV; Ollama entra
  [[ "${CH_NEW[0]}" == *"Atualizar ghcup"* ]]
  [[ "${CH_OLD[0]}" = "Atualizar ghcup" ]]
}

@test "tui_collect_changes: preserva skips fora do catálogo" {
  printf 'FULL_UPGRADE_SKIP="Step legado,Atualizar ghcup"\nREPORT_ON_FINISH=0\n' >"$FU_CONFIG_FILE"
  tui_build_steps
  TUI_MODE=steps
  tui_store_active_model
  tui_build_params
  TUI_MODE=params
  tui_store_active_model
  local i current
  for i in "${!TUI_PARAMS_NAME[@]}"; do
    [[ "${TUI_PARAMS_NAME[$i]}" == REPORT_ON_FINISH ]] && TUI_VALUE[$i]=1
  done
  TUI_SKIP_CSV_BASE="$(config_file_value FULL_UPGRADE_SKIP)"
  current="$(tui_current_skip_csv)"
  [[ "$current" == *"Step legado"* ]]
  [[ "$current" == *"Atualizar ghcup"* ]]
}

@test "tui_toggle_current: bool alterna 0/1" {
  TUI_MODE="params"
  tui_build_params
  local i
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "NOTIFY_ON_FINISH" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; }
  done
  tui_toggle_current
  [ "${TUI_VALUE[${TUI_VIEW[0]}]}" = "1" ]
  tui_toggle_current
  [ "${TUI_VALUE[${TUI_VIEW[0]}]}" = "0" ]
}

@test "tui_cycle_enum: cicla opções para os dois lados" {
  TUI_MODE="params"
  tui_build_params
  local i
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "LANG_OVERRIDE" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; }
  done
  tui_cycle_enum 1
  # auto -> pt
  [ "${TUI_VALUE[${TUI_VIEW[0]}]}" = "pt" ]
  tui_cycle_enum -1
  # volta para auto
  [ "${TUI_VALUE[${TUI_VIEW[0]}]}" = "auto" ]
}

@test "tui_cycle_enum: valor vazio entra no ciclo (primeira opção)" {
  TUI_MODE="params"
  tui_build_params
  local i
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "AUR_HELPER" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; }
  done
  TUI_VALUE[${TUI_VIEW[0]}]=""
  tui_cycle_enum 1
  [ "${TUI_VALUE[${TUI_VIEW[0]}]}" = "paru" ]
}

# ── quoting ───────────────────────────────────────────────────────────────────

@test "tui_quote_value: int/bool ficam crus; string ganha aspas" {
  [ "$(tui_quote_value int 5)" = "5" ]
  [ "$(tui_quote_value bool 1)" = "1" ]
  [ "$(tui_quote_value string 'hello world')" = '"hello world"' ]
}

@test "tui_quote_value: escapa aspas, barra e cifrão" {
  [ "$(tui_quote_value path '$HOME/x "q"')" = '"\$HOME/x \"q\""' ]
}

@test "tui_quote_value: escapa substituição de comando" {
  [ "$(tui_quote_value string 'foo`touch marker`')" = '"foo\`touch marker\`"' ]
}

@test "tui_quote/unquote: round-trip preserva o valor" {
  local v='a "b" $c \d'
  [ "$(tui_unquote_value "$(tui_quote_value string "$v")")" = "$v" ]
}

# ── upsert / save ─────────────────────────────────────────────────────────────

@test "tui_upsert_into: arquivo vazio recebe só a atribuição" {
  : >"$FU_CONFIG_FILE"
  tui_upsert_into "$FU_CONFIG_FILE" 'REPORT_ON_FINISH=1'
  run cat "$FU_CONFIG_FILE"
  [ "$output" = "REPORT_ON_FINISH=1" ]
}

@test "tui_upsert_into: substitui linha existente no lugar" {
  cat >"$FU_CONFIG_FILE" <<'EOF'
# comentário do usuário
REPORT_ON_FINISH=0
OUTRA_CHAVE="mantida"
EOF
  tui_upsert_into "$FU_CONFIG_FILE" 'REPORT_ON_FINISH=1'
  run cat "$FU_CONFIG_FILE"
  [[ "$output" == *"# comentário do usuário"* ]]
  [[ "$output" == *"REPORT_ON_FINISH=1"* ]]
  [[ "$output" == *'OUTRA_CHAVE="mantida"'* ]]
  # Só UMA ocorrência da chave
  [ "$(grep -c '^REPORT_ON_FINISH=' "$FU_CONFIG_FILE")" -eq 1 ]
}

@test "tui_upsert_into: preserva export e comentário inline" {
  printf 'export REPORT_ON_FINISH=0 # comentário\n' >"$FU_CONFIG_FILE"
  tui_upsert_into "$FU_CONFIG_FILE" 'REPORT_ON_FINISH=1'
  run cat "$FU_CONFIG_FILE"
  [ "$output" = "export REPORT_ON_FINISH=1 # comentário" ]
}

@test "tui_upsert_into: preserva hash dentro do valor" {
  printf 'TRAY_TERMINAL="foo # bar"\n' >"$FU_CONFIG_FILE"
  tui_upsert_into "$FU_CONFIG_FILE" 'TRAY_TERMINAL="novo # valor"'
  run cat "$FU_CONFIG_FILE"
  [ "$output" = 'TRAY_TERMINAL="novo # valor"' ]
}

@test "tui_upsert_into: chave nova vai para a seção gerenciada" {
  printf 'EXISTENTE=1\n' >"$FU_CONFIG_FILE"
  tui_upsert_into "$FU_CONFIG_FILE" 'BACKUP_KEEP=3'
  run cat "$FU_CONFIG_FILE"
  [[ "$output" == *"EXISTENTE=1"* ]]
  [[ "$output" == *"full-upgrade TUI"* ]]
  [[ "$output" == *"BACKUP_KEEP=3"* ]]
}

@test "tui_upsert_into: consolida atribuições duplicadas para o valor salvo vencer" {
  cat >"$FU_CONFIG_FILE" <<'EOF'
REPORT_ON_FINISH=0
# comentário entre atribuições preservado
REPORT_ON_FINISH=1
EOF
  tui_upsert_into "$FU_CONFIG_FILE" 'REPORT_ON_FINISH=2'
  [ "$(grep -c '^REPORT_ON_FINISH=' "$FU_CONFIG_FILE")" -eq 1 ]
  # shellcheck source=/dev/null
  source "$FU_CONFIG_FILE"
  [ "$REPORT_ON_FINISH" = "2" ]
  grep -q '^# comentário entre atribuições preservado$' "$FU_CONFIG_FILE"
}

@test "tui_config_save_pairs: cria config novo e informe (config criado)" {
  rm -f "$FU_CONFIG_FILE"
  TUI_FLASH_BAK=""
  tui_config_save_pairs "REPORT_ON_FINISH|bool|1"   # direta: muta TUI_FLASH_BAK
  [ "$?" -eq 0 ]
  [[ "$TUI_FLASH_BAK" == *"config criado"* ]]
  run cat "$FU_CONFIG_FILE"
  [ "$output" = "REPORT_ON_FINISH=1" ]
}

@test "tui_config_save_pairs: merge preserva chaves não tocadas e comentários" {
  cat >"$FU_CONFIG_FILE" <<'EOF'
# Config pessoal do usuário (não pode sumir)
MIN_FREE_GIB=3
REPORT_ON_FINISH=0
EOF
  TUI_FLASH_BAK=""
  tui_config_save_pairs "REPORT_ON_FINISH|bool|1" "BACKUP_KEEP|int|7"
  [ "$?" -eq 0 ]
  [[ "$TUI_FLASH_BAK" == *"backup:"* ]]
  run cat "$FU_CONFIG_FILE"
  [[ "$output" == *"# Config pessoal do usuário (não pode sumir)"* ]]
  [[ "$output" == *"MIN_FREE_GIB=3"* ]]
  [[ "$output" == *"REPORT_ON_FINISH=1"* ]]
  [[ "$output" == *"BACKUP_KEEP=7"* ]]
}

@test "tui_config_save_pairs: cria backup com timestamp antes de reescrever" {
  printf 'MIN_FREE_GIB=2\n' >"$FU_CONFIG_FILE"
  tui_config_save_pairs "MIN_FREE_GIB|int|4"
  [ "$?" -eq 0 ]
  local baks
  baks="$(ls "${FU_CONFIG_FILE}".bak.* 2>/dev/null | wc -l)"
  [ "$baks" -eq 1 ]
  # Backup contém o estado ANTERIOR
  local bak
  bak="$(ls "${FU_CONFIG_FILE}".bak.* | head -1)"
  grep -q 'MIN_FREE_GIB=2' "$bak"
  grep -q 'MIN_FREE_GIB=4' "$FU_CONFIG_FILE"
}

@test "tui_config_save_pairs: resultado sempre parseia (bash -n interno)" {
  # Valor com aspas/cifrão escapados tem que sobreviver ao round-trip do source.
  tui_config_save_pairs "TIMESHIFT_CLOUD_REPOSITORY|string|rclone:onedrive:dir \$x"
  [ "$?" -eq 0 ]
  bash -n "$FU_CONFIG_FILE"
  FU_CONFIG_DIR="$(dirname "$FU_CONFIG_FILE")"
  # O config gravado é carregável e produz o valor com $ literal
  (
    # shellcheck source=/dev/null
    source "$FU_CONFIG_FILE"
    [ "$TIMESHIFT_CLOUD_REPOSITORY" = 'rclone:onedrive:dir $x' ]
  )
}

@test "tui_config_save_pairs: poda backups além de 5" {
  printf 'X=1\n' >"$FU_CONFIG_FILE"
  # Cria 7 backups falsos antigos
  local i
  for i in 1 2 3 4 5 6 7; do
    touch "${FU_CONFIG_FILE}.bak.20260101-00000$i"
  done
  tui_config_save_pairs "X|int|2"
  [ "$?" -eq 0 ]
  local baks
  baks="$(ls "${FU_CONFIG_FILE}".bak.* 2>/dev/null | wc -l)"
  [ "$baks" -le 5 ]
}

# ── fluxo de save via tui_do_save ─────────────────────────────────────────────

@test "tui_collect_changes: preserva mudanças de steps e parâmetros ao trocar de tela" {
  printf 'FULL_UPGRADE_SKIP="Atualizar ghcup"\nREPORT_ON_FINISH=0\n' >"$FU_CONFIG_FILE"
  tui_enter_screen steps
  local i
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "Atualizar Ollama" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; break; }
  done
  tui_toggle_current
  tui_enter_screen menu
  tui_enter_screen params
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "REPORT_ON_FINISH" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; break; }
  done
  tui_toggle_current
  tui_enter_screen menu
  tui_collect_changes
  [ "$TUI_PENDING" -eq 2 ]
  [[ " ${CH_KEY[*]} " == *" FULL_UPGRADE_SKIP "* ]]
  [[ " ${CH_KEY[*]} " == *" REPORT_ON_FINISH "* ]]
}

@test "tui_do_save: grava mudanças de steps e parâmetros feitas na mesma sessão" {
  printf 'FULL_UPGRADE_SKIP="Atualizar ghcup"\nREPORT_ON_FINISH=0\n' >"$FU_CONFIG_FILE"
  tui_enter_screen steps
  local i
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "Atualizar Ollama" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; break; }
  done
  tui_toggle_current
  tui_enter_screen menu
  tui_enter_screen params
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "REPORT_ON_FINISH" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; break; }
  done
  tui_toggle_current
  tui_do_save
  grep -q '^REPORT_ON_FINISH=1$' "$FU_CONFIG_FILE"
  grep -q '^FULL_UPGRADE_SKIP="Atualizar ghcup,Atualizar Ollama"$' "$FU_CONFIG_FILE"
}

@test "tui_do_save: params alterados vão para o arquivo" {
  TUI_MODE="params"
  tui_build_params
  local i
  for i in "${!TUI_NAME[@]}"; do
    [[ "${TUI_NAME[$i]}" == "COREDUMP_KEEP_DAYS" ]] && { TUI_VIEW=("$i"); TUI_SEL=0; }
  done
  TUI_VALUE[${TUI_VIEW[0]}]=14
  tui_collect_changes
  TUI_FLASH_BAK=""
  tui_do_save            # direta: run() perderia a re-sincronização de ORIG
  [ "$?" -eq 0 ]
  grep -q '^COREDUMP_KEEP_DAYS=14$' "$FU_CONFIG_FILE"
  # ORIG re-sincronizado: sem mudança pendente após gravar
  tui_collect_changes
  [ "$TUI_PENDING" -eq 0 ]
}

@test "tui_do_save: sem mudanças => nada a salvar e arquivo intocado" {
  TUI_MODE="params"
  tui_build_params
  printf 'MIN_FREE_GIB=2\n' >"$FU_CONFIG_FILE"
  run tui_do_save
  [ "$status" -eq 0 ]
  run cat "$FU_CONFIG_FILE"
  [ "$output" = "MIN_FREE_GIB=2" ]
}

# ── decodificação de teclado (navegação por setas) ────────────────────────────

@test "tui_decode_csi: setas CSI ([A..[D) mapeiam up/down/right/left" {
  TUI_KEY=""; tui_decode_csi "[A"; [ "$TUI_KEY" = "up" ]
  TUI_KEY=""; tui_decode_csi "[B"; [ "$TUI_KEY" = "down" ]
  TUI_KEY=""; tui_decode_csi "[C"; [ "$TUI_KEY" = "right" ]
  TUI_KEY=""; tui_decode_csi "[D"; [ "$TUI_KEY" = "left" ]
}

@test "tui_decode_csi: variantes SS3 (OA..OD) também mapeiam" {
  TUI_KEY=""; tui_decode_csi "OA"; [ "$TUI_KEY" = "up" ]
  TUI_KEY=""; tui_decode_csi "OB"; [ "$TUI_KEY" = "down" ]
  TUI_KEY=""; tui_decode_csi "OC"; [ "$TUI_KEY" = "right" ]
  TUI_KEY=""; tui_decode_csi "OD"; [ "$TUI_KEY" = "left" ]
}

@test "tui_decode_csi: Home/End via [H/[F e SS3" {
  TUI_KEY=""; tui_decode_csi "[H"; [ "$TUI_KEY" = "home" ]
  TUI_KEY=""; tui_decode_csi "[F"; [ "$TUI_KEY" = "end" ]
  TUI_KEY=""; tui_decode_csi "OH"; [ "$TUI_KEY" = "home" ]
  TUI_KEY=""; tui_decode_csi "OF"; [ "$TUI_KEY" = "end" ]
}

@test "tui_decode_csi: PgUp/PgDn precisam do 3º byte (~)" {
  TUI_KEY=""; tui_decode_csi "[5" "~"; [ "$TUI_KEY" = "pgup" ]
  TUI_KEY=""; tui_decode_csi "[6" "~"; [ "$TUI_KEY" = "pgdn" ]
  # Sem o ~ ainda: aguarda o 3º byte (não decide antes)
  TUI_KEY=""; tui_decode_csi "[5";  [ "$TUI_KEY" = "esc" ]
}

@test "tui_decode_csi: Home/End alternativos terminados em ~" {
  TUI_KEY=""; tui_decode_csi "[1" "~"; [ "$TUI_KEY" = "home" ]
  TUI_KEY=""; tui_decode_csi "[7" "~"; [ "$TUI_KEY" = "home" ]
  TUI_KEY=""; tui_decode_csi "[4" "~"; [ "$TUI_KEY" = "end" ]
  TUI_KEY=""; tui_decode_csi "[8" "~"; [ "$TUI_KEY" = "end" ]
}

@test "tui_decode_csi: sequência desconhecida e Shift-Tab => esc" {
  TUI_KEY=""; tui_decode_csi "[Z"; [ "$TUI_KEY" = "esc" ]
  TUI_KEY=""; tui_decode_csi "[Q"; [ "$TUI_KEY" = "esc" ]
  TUI_KEY=""; tui_decode_csi "ZZ"; [ "$TUI_KEY" = "esc" ]
}

@test "tui_read_key: decoda setas de um stream de bytes real" {
  TUI_KEY=""; tui_read_key < <(printf '\033[A'); [ "$TUI_KEY" = "up" ]
  TUI_KEY=""; tui_read_key < <(printf '\033[B'); [ "$TUI_KEY" = "down" ]
  TUI_KEY=""; tui_read_key < <(printf '\033[C'); [ "$TUI_KEY" = "right" ]
  TUI_KEY=""; tui_read_key < <(printf '\033[D'); [ "$TUI_KEY" = "left" ]
}

@test "tui_read_key: decoda PgUp/PgDn de stream (4 bytes, sem sobrar ~) " {
  TUI_KEY=""; tui_read_key < <(printf '\033[5~'); [ "$TUI_KEY" = "pgup" ]
  TUI_KEY=""; tui_read_key < <(printf '\033[6~'); [ "$TUI_KEY" = "pgdn" ]
}

@test "tui_read_key: teclas simples continuam mapeando" {
  TUI_KEY=""; tui_read_key < <(printf 'j');   [ "$TUI_KEY" = "char:j" ]
  TUI_KEY=""; tui_read_key < <(printf 'k');   [ "$TUI_KEY" = "char:k" ]
  TUI_KEY=""; tui_read_key < <(printf ' ');   [ "$TUI_KEY" = "space" ]
  TUI_KEY=""; tui_read_key < <(printf '\x7f'); [ "$TUI_KEY" = "backspace" ]
  TUI_KEY=""; tui_read_key < <(printf '\r');  [ "$TUI_KEY" = "enter" ]
}

@test "tui_read_key: ESC solto vira esc (sem sequência no timeout)" {
  TUI_KEY=""
  tui_read_key < <(printf '\033')
  [ "$TUI_KEY" = "esc" ]
}

@test "tui_dispatch_nav: menu navega mesmo com TUI_VIEW vazio" {
  TUI_MODE="menu"
  TUI_VIEW=()
  TUI_SEL=0
  TUI_KEY="down"; tui_dispatch_nav
  [ "$TUI_SEL" -eq 1 ]
  TUI_KEY="down"; tui_dispatch_nav
  [ "$TUI_SEL" -eq 2 ]
  TUI_KEY="up"; tui_dispatch_nav
  [ "$TUI_SEL" -eq 1 ]
  TUI_KEY="end"; tui_dispatch_nav
  [ "$TUI_SEL" -eq 4 ]
  TUI_KEY="home"; tui_dispatch_nav
  [ "$TUI_SEL" -eq 0 ]
}

@test "tui_dispatch_nav: lista respeita o total da visão filtrada" {
  TUI_MODE="steps"
  tui_build_steps
  TUI_FILTER="ollama"
  tui_rebuild_view
  [ "${#TUI_VIEW[@]}" -ge 1 ]
  TUI_SEL=0
  TUI_KEY="down"; tui_dispatch_nav
  # filtro com 1 resultado não deixa passar do fim
  [ "$TUI_SEL" -eq 0 ]
}

# ── guardas ───────────────────────────────────────────────────────────────────

@test "config_tui_main: sem TTY => rc 2 e mensagem com alternativas" {
  run config_tui_main
  [ "$status" -eq 2 ]
  [[ "$output" == *"terminal interativo"* ]]
  [[ "$output" == *"--config"* ]]
}
