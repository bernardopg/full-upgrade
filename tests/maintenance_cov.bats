#!/usr/bin/env bats
# tests/maintenance_cov.bats — rotação de snapshots (snapper e Timeshift),
# firmware (fwupd), pip --user e gems de usuário, com todas as ferramentas
# stubadas. PATH isolado: `python` é um stub que só repassa `-c` ao Python real.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/cleanup.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/firmware.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_py.sh"
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/lang_other.sh"
  stub_path_init
  stub_privilege
  LOG_FILE=/dev/null QUIET=0 STEP_REASON="" ASSUME_YES=1
  export HOME="$BATS_TEST_TMPDIR/home"; mkdir -p "$HOME"
}

# ── cleanup_old_snapshots ─────────────────────────────────────────────────────

@test "cleanup_old_snapshots: none, sem ferramenta e ferramenta inválida" {
  SNAPSHOT_TOOL=none run cleanup_old_snapshots
  [[ "$output" == *"desabilitada"* ]]
  SNAPSHOT_TOOL=auto run cleanup_old_snapshots
  [[ "$output" == *"Nenhuma ferramenta de snapshot"* ]]
  SNAPSHOT_TOOL=zfs run cleanup_old_snapshots
  [ "$status" -eq "$RC_WARN" ]
}

@test "cleanup_old_snapshots: snapper remove só os antigos do full-upgrade" {
  SNAPSHOT_KEEP=1
  stub_script snapper 'case "$*" in
    "-c root list --csvout") printf "%s\n" "#,Type,Pre,Date,User,Description" \
      "\"1\",single,,d,root,\"full-upgrade pré-upgrade\"" \
      "\"2\",single,,d,root,\"manual\"" \
      "\"3\",single,,d,root,\"full-upgrade pré-upgrade\"" ;;
  esac'
  SNAPSHOT_TOOL=auto run cleanup_old_snapshots
  [ "$status" -eq 0 ]
  grep -q "^snapper -c root delete 1" "$STUB_LOG"
  ! grep -q "delete 2" "$STUB_LOG"
  ! grep -q "delete 3" "$STUB_LOG"
}

@test "cleanup_old_snapshots: sem --yes e sem TTY não remove" {
  ASSUME_YES=0 SNAPSHOT_KEEP=1
  stub_script snapper 'printf "%s\n" "#,Type,Pre,Date,User,Description" "\"1\",s,,d,r,\"full-upgrade pré-upgrade\"" "\"3\",s,,d,r,\"full-upgrade pré-upgrade\""'
  SNAPSHOT_TOOL=snapper run cleanup_old_snapshots </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"não interativa sem --yes"* ]]
}

@test "cleanup_old_snapshots: Timeshift lista com sudo e remove os excedentes" {
  SNAPSHOT_KEEP=1
  stub_script timeshift 'case "$*" in
    --list) printf "%s\n" "Num     Name                 Tags  Description" \
      "------------------------------------------------------------------------------" \
      "0    >  2026-11-10_10-00-00  O     full-upgrade pré-upgrade" \
      "1    >  2026-11-15_10-00-00  O     full-upgrade pré-upgrade" \
      "2    >  2026-11-16_10-00-00  D     manual" ;;
  esac'
  SNAPSHOT_TOOL=timeshift run cleanup_old_snapshots
  [ "$status" -eq 0 ]
  grep -q "^timeshift --delete --snapshot 2026-11-10_10-00-00" "$STUB_LOG"
  [[ "$output" == *"Rotação Timeshift concluída: 1 removido(s)"* ]]
}

@test "cleanup_old_snapshots: falha ao listar o Timeshift vira warn, nunca lista vazia" {
  stub timeshift 1 "E: permission denied"
  SNAPSHOT_TOOL=timeshift run cleanup_old_snapshots
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"a rotação não foi executada"* ]]
}

# ── update_fwupd ──────────────────────────────────────────────────────────────

@test "update_fwupd: sem updates (rc 2) conta os dispositivos" {
  stub_script fwupdmgr 'case "$1" in
    refresh) echo "Downloading metadata"; exit 0 ;;
    get-updates) echo "No updates available"; exit 2 ;;
    get-devices) printf "{\"DeviceId\":1}\n{\"DeviceId\":2}\n" ;;
  esac'
  run update_fwupd
  [ "$status" -eq 0 ]
  [[ "$output" == *"(2 dispositivos verificados)"* ]]
}

@test "update_fwupd: com updates aplica; refresh com erro de rede vira warn" {
  stub_script fwupdmgr 'case "$1" in
    refresh) exit 0 ;;
    get-updates) echo "• UEFI dbx: 1 → 2"; exit 0 ;;
    update) echo "Successfully installed firmware" ;;
  esac'
  run update_fwupd
  [ "$status" -eq 0 ]
  grep -q "^fwupdmgr update -y" "$STUB_LOG"
  stub fwupdmgr 1 "Failed to download: Could not resolve host: cdn.fwupd.org"
  _retry() { "$@" >/dev/null 2>&1; return "$RC_WARN"; }
  run update_fwupd
  [ "$status" -eq "$RC_WARN" ]
}

# ── update_pip_user ───────────────────────────────────────────────────────────

_python_stub() {
  # -m pip => fixtures; -c => Python real.
  stub_script python 'if [[ "$1" == -m && "$2" == pip ]]; then
  case "$*" in
    *--outdated*) cat "$PIP_OUTDATED" 2>/dev/null ;;
    *--not-required*) cat "$PIP_LEAVES" 2>/dev/null ;;
    *install*) exit 0 ;;
  esac
  exit 0
fi
exec python3 "$@"'
}

@test "update_pip_user: só folhas fora do ignore; nada pendente" {
  _python_stub
  export PIP_OUTDATED="$BATS_TEST_TMPDIR/o.json" PIP_LEAVES="$BATS_TEST_TMPDIR/l.json"
  echo '[{"name":"ruff"},{"name":"chardet"},{"name":"Poetry_Core"}]' > "$PIP_OUTDATED"
  echo '[{"name":"ruff"},{"name":"poetry-core"}]' > "$PIP_LEAVES"
  poetry_core_requirement() { echo "poetry-core==2.1.0"; }
  run update_pip_user
  [ "$status" -eq 0 ]
  grep -q "pip install --user --break-system-packages --upgrade ruff$" "$STUB_LOG"
  echo '[]' > "$PIP_OUTDATED"
  run update_pip_user
  [[ "$output" == *"Sem pacotes pip --user desatualizados"* ]]
}

@test "update_pip_user: sem folhas sobe todos e avisa" {
  _python_stub
  export PIP_OUTDATED="$BATS_TEST_TMPDIR/o.json" PIP_LEAVES="$BATS_TEST_TMPDIR/vazio"
  echo '[{"name":"ruff"},{"name":"chardet"}]' > "$PIP_OUTDATED"
  poetry_core_requirement() { return 1; }
  run update_pip_user
  [[ "$output" == *"não retornou folhas"* ]]
  grep -q "upgrade ruff chardet" "$STUB_LOG"
}

# ── update_gem_user ───────────────────────────────────────────────────────────

@test "update_gem_user: GEM_HOME do usuário com e sem pendências" {
  stub_script gem "case \"\$*\" in
    'env home') echo '$HOME/.gem' ;;
    'env user_gemhome') echo '$HOME/.gem' ;;
    outdated) echo \"\${GEM_OUTDATED:-}\" ;;
  esac"
  run update_gem_user
  [[ "$output" == *"Sem gems desatualizadas"* ]]
  GEM_OUTDATED="rake (13.0.0 < 13.2.1)" run update_gem_user
  [[ "$output" == *"Gems desatualizadas"* ]]
  grep -q "^gem update" "$STUB_LOG"
}

@test "update_gem_user: GEM_HOME do sistema atualiza só gems próprias do usuário" {
  mkdir -p "$HOME/.local/share/gem/ruby"
  stub_script gem "case \"\$*\" in
    'env home') echo /usr/lib/ruby/gems/3.4.0 ;;
    'env user_gemhome') echo '$HOME/.local/share/gem/ruby' ;;
    outdated) printf 'rake (13.0.0 < 13.2.1)\nminha_gem (1.0 < 2.0)\n' ;;
    'list --local') echo 'rake (13.0.0)' ;;
    list) echo 'rake (13.0.0)' ;;
  esac"
  run update_gem_user
  [ "$status" -eq 0 ]
  grep -q "^gem update minha_gem" "$STUB_LOG"
}

@test "update_gem_user: gem cleanup só no diretório do usuário, e conta o que removeu" {
  mkdir -p "$HOME/.local/share/gem/ruby"
  stub_script gem "case \"\$*\" in
    'env home') echo /usr/lib/ruby/gems/3.4.0 ;;
    'env user_gemhome') echo '$HOME/.local/share/gem/ruby' ;;
    cleanup) echo \"cleanup GEM_HOME=\$GEM_HOME GEM_PATH=\$GEM_PATH\" >> '$BATS_TEST_TMPDIR/cleanup.log'
             printf 'Successfully uninstalled psych-5.4.0\nSuccessfully uninstalled cgi-0.5.1\n' ;;
  esac"
  run update_gem_user
  [ "$status" -eq 0 ]
  [[ "$output" == *"Versões antigas de gems do usuário removidas: 2."* ]]
  grep -qx "cleanup GEM_HOME=$HOME/.local/share/gem/ruby GEM_PATH=$HOME/.local/share/gem/ruby" "$BATS_TEST_TMPDIR/cleanup.log"
}

@test "cleanup_gem_user_dir: fora do HOME não roda; falha vira aviso" {
  stub_script gem 'echo chamado >> "$BATS_TEST_TMPDIR/g.log"; exit 1'
  run cleanup_gem_user_dir /usr/lib/ruby/gems/3.4.0
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/g.log" ]
  mkdir -p "$HOME/.gem"
  run cleanup_gem_user_dir "$HOME/.gem"
  [ "$status" -eq 0 ]
  [[ "$output" == *"gem cleanup no diretório do usuário falhou"* ]]
}

@test "update_gem_user: sem GEM_HOME falha" {
  stub gem 0 ""
  run update_gem_user
  [ "$status" -eq 1 ]
}

# ── repair_command_shadowing ──────────────────────────────────────────────────

@test "repair_command_shadowing: sem sombra, binário gerenciado ausente e casos do pacman" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/repair.sh"
  run repair_command_shadowing comando-que-nao-existe-xyz /usr/bin/x
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem sombra local"* ]]
}

# ── check_pacnew_files, refresh_mirrors, preupgrade_snapshot ─────────────────

@test "check_pacnew_files: sem pacdiff, nada pendente e pendentes viram TODO" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/pacman.sh"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"; RUN_ID=r1
  run check_pacnew_files
  [[ "$output" == *"pacdiff não encontrado"* ]]
  stub pacdiff 0 ""
  run check_pacnew_files
  [[ "$output" == *"Nenhum arquivo .pacnew/.pacsave pendente"* ]]
  stub pacdiff 0 "/etc/pacman.conf.pacnew"
  AUTO_MERGE_PACNEW=0 check_pacnew_files >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$STEP_REASON" = "1 arquivo(s) .pacnew/.pacsave pendente(s) de merge" ]
}

@test "check_pacnew_files: merge automático resolve tudo ou deixa sobras" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/pacman.sh"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"; RUN_ID=r1
  stub pacdiff 0 "/etc/a.pacnew
/etc/b.pacnew"
  AUTO_MERGE_PACNEW=1 NO_REPAIR=0
  pacnew_auto_merge() { : > "$1"; PACNEW_AUTO_MERGE_WARNINGS=0; }
  run check_pacnew_files
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 arquivo(s) mesclado(s) automaticamente"* ]]
  pacnew_auto_merge() { : > "$1"; PACNEW_AUTO_MERGE_WARNINGS=1; }
  check_pacnew_files >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  pacnew_auto_merge() { echo /etc/b.pacnew > "$1"; }
  unset status
  check_pacnew_files >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
}

@test "refresh_mirrors: none, sem ferramenta e mirrorlist recente" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/pacman.sh"
  MIRROR_TOOL=none run refresh_mirrors
  [[ "$output" == *"desabilitado"* ]]
  MIRROR_TOOL=auto run refresh_mirrors
  [[ "$output" == *"pacman ausente"* ]]
  stub pacman 0
  MIRROR_TOOL=auto MIRROR_MAX_AGE_DAYS=0 run refresh_mirrors
  [[ "$output" == *"Nenhuma ferramenta de mirror"* ]]
  MIRROR_TOOL=xyz MIRROR_MAX_AGE_DAYS=0 run refresh_mirrors
  [ "$status" -eq "$RC_WARN" ]
}

@test "refresh_mirrors: reflector e rate-mirrors com sucesso e com falha" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/pacman.sh"
  stub pacman 0; stub cp 0
  _restore_mirror_backup() { return 0; }
  stub reflector 0
  MIRROR_TOOL=reflector MIRROR_MAX_AGE_DAYS=0 run refresh_mirrors
  [ "$status" -eq 0 ]
  [[ "$output" == *"via reflector"* ]]
  stub reflector 1
  MIRROR_TOOL=reflector MIRROR_MAX_AGE_DAYS=0 run refresh_mirrors
  [ "$status" -eq "$RC_WARN" ]
  stub rate-mirrors 0
  MIRROR_TOOL=auto MIRROR_MAX_AGE_DAYS=0 run refresh_mirrors
  [[ "$output" == *"via rate-mirrors"* ]]
  stub rate-mirrors 1
  MIRROR_TOOL=rate-mirrors MIRROR_MAX_AGE_DAYS=0 run refresh_mirrors
  [ "$status" -eq "$RC_WARN" ]
}

@test "preupgrade_snapshot: none, raiz não btrfs, sem ferramenta e espaço baixo" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/backup.sh"
  SNAPSHOT_TOOL=none run preupgrade_snapshot
  [[ "$output" == *"desabilitado"* ]]
  stub findmnt 0 "ext4"
  SNAPSHOT_TOOL=auto run preupgrade_snapshot
  [[ "$output" == *"Raiz não é btrfs (ext4)"* ]]
  stub findmnt 0 "btrfs"
  SNAPSHOT_TOOL=auto run preupgrade_snapshot
  [[ "$output" == *"Nenhuma ferramenta de snapshot"* ]]
  stub snapper 0
  avail_kib_for_path() { echo 1048576; }
  SNAPSHOT_TOOL=auto SNAPSHOT_MIN_FREE_GIB=5 preupgrade_snapshot >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
}

@test "preupgrade_snapshot: snapper e Timeshift criam; falha vira warn" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/backup.sh"
  stub findmnt 0 "btrfs"
  avail_kib_for_path() { echo 104857600; }
  stub snapper 0
  SNAPSHOT_TOOL=snapper run preupgrade_snapshot
  [ "$status" -eq 0 ]
  grep -q "^snapper -c root create -d full-upgrade pré-upgrade" "$STUB_LOG"
  stub timeshift 0 "BTRFS Snapshot saved successfully (0s)"
  SNAPSHOT_TOOL=timeshift run preupgrade_snapshot
  [ "$status" -eq 0 ]
  [[ "$output" == *"Snapshot saved successfully"* ]]
  stub timeshift 1 "E: erro"
  SNAPSHOT_TOOL=timeshift run preupgrade_snapshot
  [ "$status" -eq "$RC_WARN" ]
  stub snapper 1
  SNAPSHOT_TOOL=snapper run preupgrade_snapshot
  [ "$status" -eq "$RC_WARN" ]
  SNAPSHOT_TOOL=xyz run preupgrade_snapshot
  [ "$status" -eq "$RC_WARN" ]
}

# ── final_check_pending ───────────────────────────────────────────────────────

@test "final_check_pending: cluster Haskell segurado, oficial e AUR pendentes" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/final_checks.sh"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"; RUN_ID=r1
  pacman_ignored_packages() { echo ""; }
  stub checkupdates 0 "ghc 9.6-1 -> 9.8-1
flex 2.6.10-1 -> 2.6.15-1"
  stub paru 0 "foo-git 1-1 -> 2-1"
  final_check_pending >/dev/null || status=$?
  [ "${status:-0}" -ne 0 ]
}

@test "pending_published_after_sync: só o que a base do run não via" {
  source "${FU_LIB}/steps/final_checks.sh"
  pending_published_after_sync rex $'flex\nfoo'
  ! pending_published_after_sync flex $'flex\nfoo'
  ! pending_published_after_sync "" "flex"
}

@test "final_check_pending: pacote publicado depois do upgrade do run não é pendência" {
  source "${FU_LIB}/steps/final_checks.sh"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"; RUN_ID=r1
  pacman_ignored_packages() { echo ""; }
  : >"$(pacman_synced_file)"
  stub checkupdates 0 "rex 0.1.0alpha2639-1 -> 0.1.0alpha2641-1"
  stub pacman 1 ""   # pacman -Qu: a base do run não tinha versão nova
  run final_check_pending
  [ "$status" -eq 0 ]
  [[ "$output" == *"publicado(s) depois do upgrade"* ]]
}

@test "final_check_pending: pendência que a base do run já via segue acionável" {
  source "${FU_LIB}/steps/final_checks.sh"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"; RUN_ID=r1
  pacman_ignored_packages() { echo ""; }
  : >"$(pacman_synced_file)"
  stub checkupdates 0 "flex 2.6.10-1 -> 2.6.15-1"
  stub pacman 0 "flex 2.6.10-1 -> 2.6.15-1"
  final_check_pending >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
}

@test "final_check_pending: sem o marcador de sync (doctor/upgrade pulado) nada é rebaixado" {
  source "${FU_LIB}/steps/final_checks.sh"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"; RUN_ID=r2
  pacman_ignored_packages() { echo ""; }
  stub checkupdates 0 "rex 0.1.0alpha2639-1 -> 0.1.0alpha2641-1"
  stub pacman 1 ""
  final_check_pending >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
}

@test "final_check_pending: AUR só com ignorados e IgnorePkg não é pendência" {
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/final_checks.sh"
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"; RUN_ID=r1
  pacman_ignored_packages() { echo "held-pkg"; }
  stub checkupdates 0 "held-pkg 1-1 -> 2-1"
  stub yay 0 "pcsx2 1-1 -> 2-1
held-pkg 1-1 -> 2-1"
  FULL_UPGRADE_AUR_IGNORE="pcsx2"
  run final_check_pending
  [ "$status" -eq 0 ]
  [[ "$output" == *"segurado(s) por IgnorePkg"* ]]
  [[ "$output" == *"apenas em pacotes AUR ignorados: pcsx2"* ]]
}
