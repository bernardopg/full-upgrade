#!/usr/bin/env bats
# tests/pacnew_merge.bats — merge automático seguro de .pacnew (lib/steps/pacman.sh)

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/pacman.sh"
  CUR="${BATS_TEST_TMPDIR}/atual"
  NEW="${BATS_TEST_TMPDIR}/atual.pacnew"
}

@test "pacnew_safe_merge: reativa no pacnew a linha que o usuário descomentou" {
  cat >"$CUR" <<'EOF'
# comentário antigo
#en_US.UTF-8 UTF-8
pt_BR.UTF-8 UTF-8
EOF
  cat >"$NEW" <<'EOF'
# comentário novo do pacote
#en_US.UTF-8 UTF-8
#en_SE.UTF-8 UTF-8
#pt_BR.UTF-8 UTF-8
EOF
  run pacnew_safe_merge "$CUR" "$NEW"
  [ "$status" -eq 0 ]
  # comentário novo e opção nova entram; a linha ativa do usuário continua ativa
  [[ "$output" == *"# comentário novo do pacote"* ]]
  [[ "$output" == *"#en_SE.UTF-8 UTF-8"* ]]
  [[ "$output" == *$'\npt_BR.UTF-8 UTF-8'* ]]
  # nenhuma outra linha ficou ativa
  [ "$(printf '%s\n' "$output" | grep -cvE '^[[:space:]]*(#|$)')" -eq 1 ]
}

@test "pacnew_safe_merge: preserva os bytes exatos da linha ativa do usuário" {
  printf 'pt_BR.UTF-8 UTF-8  \n' >"$CUR"
  printf '#pt_BR.UTF-8 UTF-8\n' >"$NEW"
  run pacnew_safe_merge "$CUR" "$NEW"
  [ "$status" -eq 0 ]
  [ "$output" = 'pt_BR.UTF-8 UTF-8  ' ]
}

@test "pacnew_safe_merge: recusa quando o usuário mudou o valor de uma diretiva" {
  printf 'Color = always\n' >"$CUR"
  printf '#Color\nParallelDownloads = 5\n' >"$NEW"
  run pacnew_safe_merge "$CUR" "$NEW"
  [ "$status" -ne 0 ]
}

@test "pacnew_safe_merge: recusa quando o pacnew ativa um default novo" {
  printf '#Color\n' >"$CUR"
  printf 'ParallelDownloads = 5\n' >"$NEW"
  run pacnew_safe_merge "$CUR" "$NEW"
  [ "$status" -ne 0 ]
}

@test "pacnew_safe_merge: recusa quando uma diretiva ativa sumiu do pacnew" {
  printf 'IgnorePkg = linux\n' >"$CUR"
  printf '# nada aqui\n' >"$NEW"
  run pacnew_safe_merge "$CUR" "$NEW"
  [ "$status" -ne 0 ]
}

@test "pacnew_safe_merge: só comentários mudando gera merge idêntico ao pacnew" {
  printf '# velho\n' >"$CUR"
  printf '# novo\n# mais novo\n' >"$NEW"
  run pacnew_safe_merge "$CUR" "$NEW"
  [ "$status" -eq 0 ]
  [ "$output" = "$(cat "$NEW")" ]
}

@test "pacnew_safe_merge: linhas ativas repetidas casam uma a uma" {
  printf 'Server = a\nServer = b\n' >"$CUR"
  printf '#Server = a\n#Server = b\n#Server = c\n' >"$NEW"
  run pacnew_safe_merge "$CUR" "$NEW"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -cvE '^[[:space:]]*(#|$)')" -eq 2 ]
  [[ "$output" == *"#Server = c"* ]]
}

@test "pacnew_safe_merge: arquivo ilegível falha em vez de gerar merge vazio" {
  run pacnew_safe_merge "${BATS_TEST_TMPDIR}/nao-existe" "${BATS_TEST_TMPDIR}/tambem-nao"
  [ "$status" -ne 0 ]
}

@test "PACNEW_NEVER_AUTO_RE: cobre os arquivos que trancam a máquina" {
  local f
  for f in /etc/sudoers /etc/passwd /etc/shadow /etc/group /etc/gshadow /etc/fstab /etc/crypttab; do
    [[ "$f" =~ $PACNEW_NEVER_AUTO_RE ]] || {
      echo "não bloqueado: $f"
      return 1
    }
  done
  [[ "/etc/locale.gen" =~ $PACNEW_NEVER_AUTO_RE ]] && return 1
  [[ "/etc/sudoers.d/wheel" =~ $PACNEW_NEVER_AUTO_RE ]] && return 1
  return 0
}

@test "pacnew_post_merge_cmd: locale.gen recompila, demais não têm hook" {
  run pacnew_post_merge_cmd /etc/locale.gen
  [ "$output" = "locale-gen" ]
  run pacnew_post_merge_cmd /etc/pacman.conf
  [ -z "$output" ]
}

@test "pacnew_auto_merge: cria backup, aplica merge e remove o pacnew" {
  printf 'Ativa = sim\n' >"$CUR"
  printf '#Ativa = sim\n#Nova = nao\n' >"$NEW"
  sudo() { command "$@"; }
  export -f sudo

  local left="${BATS_TEST_TMPDIR}/left"
  run pacnew_auto_merge "$left" "$NEW"
  [ "$status" -eq 0 ]
  [ ! -e "$NEW" ]
  [ ! -s "$left" ]
  grep -qx 'Ativa = sim' "$CUR"
  [ "$(find "$BATS_TEST_TMPDIR" -name 'atual.full-upgrade.bak.*' | wc -l)" -eq 1 ]
}

@test "pacnew_auto_merge: mantém pendência se não conseguir remover o pacnew" {
  printf 'Ativa = sim\n' >"$CUR"
  printf '#Ativa = sim\n' >"$NEW"
  sudo() {
    [[ "$1" == "rm" ]] && return 1
    command "$@"
  }
  export -f sudo

  local left="${BATS_TEST_TMPDIR}/left"
  run pacnew_auto_merge "$left" "$NEW"
  [ "$status" -eq 0 ]
  [ -e "$NEW" ]
  grep -Fxq "$NEW" "$left"
}

@test "pacnew_auto_merge: contabiliza falha do hook pós-merge" {
  printf 'Ativa = sim\n' >"$CUR"
  printf '#Ativa = sim\n' >"$NEW"
  sudo() { command "$@"; }
  pacnew_post_merge_cmd() { printf 'hook-falso'; }
  has() { return 0; }
  run_logged() { return 1; }

  local left="${BATS_TEST_TMPDIR}/left"
  pacnew_auto_merge "$left" "$NEW"
  [ "$PACNEW_AUTO_MERGE_WARNINGS" -eq 1 ]
  [ ! -e "$NEW" ]
  [ ! -s "$left" ]
}
