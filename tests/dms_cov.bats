#!/usr/bin/env bats
# tests/dms_cov.bats — todos os desfechos de update_dms_plugins (plugin solto e
# monorepo .repos/) com os helpers git de lib/core.sh trocados por funções que
# devolvem o cenário pedido: pull que deixa conflito, recuperação falha/limpa/
# restaurada/local/conflito, fixados, conflito pendente e fetch sem rede.
# Nada de git real: o git do PATH isolado só responde "1 commit atrás".

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_ROOT}/steps.d/40-dms.sh"
  stub_path_init
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  export DMS_PLUGINS_DIR="$BATS_TEST_TMPDIR/plugins"
  stub_script git 'case "$*" in *rev-list*) echo 1 ;; *remote\ get-url*) echo https://x/r ;; esac'
  git_tracking_ref() { echo origin/main; }
  git_fetch_full() { [[ "$1" == *"${FETCH_FAIL:-nada}"* ]] && { echo "${FETCH_ERR:-}"; return 1; }; return 0; }
  git_remote_gone() { return 1; }
  git_pull_ff_only() { [[ "$1" == *"${PULL_OK:-nada}"* ]] && touch "$1/.pulled"; }
  # Conflito pendente só para quem está em UNMERGED; o pull bem-sucedido marca
  # o diretório com .pulled (cinto de segurança do step).
  git_has_unmerged() {
    [[ "$1" == *"${UNMERGED:-nada}"* ]] && return 0
    [[ -e "$1/.pulled" ]]
  }
  git_recover_plugin_repo() {
    local name="${2##*/}" status
    status="$(eval "echo \${REC_${name//[^a-zA-Z0-9]/_}:-clean}")"
    [[ "$status" == fail ]] && return 1
    echo "$status origin/main"
  }
}

_plugin() { mkdir -p "$DMS_PLUGINS_DIR/$1/.git"; }
_repo() { mkdir -p "$DMS_PLUGINS_DIR/.repos/$1/.git"; }

@test "plugins: pull que deixa conflito é restaurado; recuperações de todos os tipos" {
  _plugin conflito; _plugin falha; _plugin limpo; _plugin restaurado; _plugin local; _plugin stashpop
  PULL_OK=conflito REC_falha=fail REC_limpo=clean REC_restaurado=restored REC_local=local REC_stashpop=conflict \
    run update_dms_plugins
  [ "$status" -eq 1 ]
  [[ "$output" == *"conflito: pull retornou sucesso mas deixou conflito"* ]]
  [[ "$output" == *"falha — recuperação de divergência falhou"* ]]
  [[ "$output" == *"limpo: divergência sem mudanças locais"* ]]
  [[ "$output" == *"restaurado: reset para origin/main + mudanças locais restauradas"* ]]
  [[ "$output" == *"local: 1 commit(s) atrás, mas há trabalho local"* ]]
  [[ "$output" == *"stashpop: resetado para origin/main; o stash pop conflitou"* ]]
}

@test "monorepos: fixado, conflito pendente, fetch sem rede vira warn" {
  _repo fixo; _repo travado; _repo semrede
  FULL_UPGRADE_DMS_PLUGINS_IGNORE="fixo" UNMERGED=travado FETCH_FAIL=semrede \
    FETCH_ERR="fatal: unable to access: Could not resolve host: github.com" \
    update_dms_plugins >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "rede indisponível ao buscar plugins DMS (1 afetados)" ]
  FULL_UPGRADE_DMS_PLUGINS_IGNORE="fixo" UNMERGED=travado FETCH_FAIL=semrede FETCH_ERR="x" \
    run update_dms_plugins
  [[ "$output" == *"fixados por FULL_UPGRADE_DMS_PLUGINS_IGNORE"*".repos/fixo"* ]]
  [[ "$output" == *"monorepo travado: conflito pendente"* ]]
  [[ "$output" == *"fetch falhou para monorepo DMS semrede"* ]]
}

@test "monorepos: pull com conflito e todas as recuperações" {
  _repo conflito; _repo falha; _repo limpo; _repo restaurado; _repo local; _repo stashpop
  PULL_OK=conflito REC_falha=fail REC_limpo=clean REC_restaurado=restored REC_local=local REC_stashpop=conflict \
    run update_dms_plugins
  [ "$status" -eq 1 ]
  [[ "$output" == *"monorepo conflito: pull retornou sucesso mas deixou conflito"* ]]
  [[ "$output" == *"pull falhou para monorepo DMS falha (stash/reset falhou)"* ]]
  [[ "$output" == *"monorepo limpo: divergência sem mudanças locais"* ]]
  [[ "$output" == *"monorepo restaurado: reset para origin/main + mudanças locais restauradas"* ]]
  [[ "$output" == *"monorepo local: trabalho local em andamento"* ]]
  [[ "$output" == *"monorepo stashpop: resetado para origin/main; o stash pop conflitou"* ]]
}

# ── pós-update: lockfile e aviso de restart do shell ──────────────────────────

@test "pós-update: plugin atualizado regrava o lock do dir gerenciado e pede restart do shell" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg"
  export DMS_PLUGINS_DIR="$XDG_CONFIG_HOME/dms/plugins"
  _plugin novo
  export PULL_OK=novo
  git_has_unmerged() { return 1; }
  stub dms 0 "locked"
  stub_script systemctl 'case "$*" in *is-active*dms.service*) exit 0 ;; esac; exit 1'
  run update_dms_plugins
  [ "$status" -eq 0 ]
  grep -q "^dms plugins lock" "$STUB_LOG"
  [[ "$output" == *"Lockfile dos plugins regravado"* ]]
  [[ "$output" == *"só entram em vigor quando o shell reinicia: novo"* ]]
  [[ "$output" == *"systemctl --user restart dms.service"* ]]
}

@test "pós-update: DMS_PLUGINS_DIR fora do dir do dms não regrava o lock" {
  _plugin novo
  export PULL_OK=novo
  git_has_unmerged() { return 1; }
  stub dms 0 ""
  stub_script systemctl 'exit 3'
  run update_dms_plugins
  [ "$status" -eq 0 ]
  ! grep -q "^dms " "$STUB_LOG"
  [[ "$output" != *"shell reinicia"* ]]
}

@test "pós-update: lock falhando só avisa; nada atualizado não chama nada" {
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR/cfg"
  export DMS_PLUGINS_DIR="$XDG_CONFIG_HOME/dms/plugins"
  _plugin novo
  export PULL_OK=novo
  git_has_unmerged() { return 1; }
  stub dms 1 "boom"
  stub_script systemctl 'exit 3'
  run update_dms_plugins
  [ "$status" -eq 0 ]
  [[ "$output" == *"'dms plugins lock' falhou"* ]]
  : > "$STUB_LOG"
  run dms_plugins_post_update "$DMS_PLUGINS_DIR"
  [ "$status" -eq 0 ]
  [ ! -s "$STUB_LOG" ]
}
