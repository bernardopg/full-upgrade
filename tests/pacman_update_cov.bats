#!/usr/bin/env bats
# tests/pacman_update_cov.bats — update_system_aur com paru/yay/pacman stubados:
# sucesso, falha isolada de build AUR (vira TODO), queda de rede do AUR com
# fallback para os repos oficiais e o caminho só-pacman. PATH isolado.

load test_helper
load stub_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/pacman.sh"
  stub_path_init
  stub_privilege
  LOG_FILE=/dev/null QUIET=1 STEP_REASON="" DEVEL_UPDATE=0
  LOG_DIR="$BATS_TEST_TMPDIR/log"; mkdir -p "$LOG_DIR"
  RUN_ID="20261117-000000-1"
  AUR_GRADLE_USER_HOME="$BATS_TEST_TMPDIR/gradle"
  repair_known_pacman_conflicts_before_update() { return 0; }
  _purge_aur_partial_sources() { :; }
  sleep() { :; }
}

@test "update_system_aur: paru com sucesso e AUR ainda desatualizado só avisa" {
  AUR_HELPER=paru DEVEL_UPDATE=1 FULL_UPGRADE_AUR_IGNORE="pcsx2"
  stub pacman 0 ""
  stub_script paru 'case "$*" in -Qu\ --aur*) echo "foo-git 1-1 -> 2-1" ;; *) echo ":: tudo certo" ;; esac'
  QUIET=0 run update_system_aur
  [ "$status" -eq 0 ]
  [[ "$output" == *"Ignorando no update automático: pcsx2"* ]]
  [[ "$output" == *"pacote(s) AUR ainda desatualizados"* ]]
  grep -q -- "--devel" "$STUB_LOG"
  grep -q -- "--ignore=pcsx2" "$STUB_LOG"
}

@test "update_system_aur: falha de build isolada no AUR vira TODO e grava o sidecar" {
  AUR_HELPER=paru
  stub pacman 0 ""
  stub_script paru 'case "$*" in -Qu*) exit 0 ;; esac
echo "error: falha ao compilar '"'"'foo-git-1.2.3-1'"'"':"
exit 1'
  update_system_aur >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [[ "$STEP_REASON" == *"pacote(s) AUR falharam build/download (sistema OK)"* ]]
  [ -s "$(aur_build_failed_file)" ]
}

@test "update_system_aur: rede do AUR fora cai para pacman e vira warn" {
  AUR_HELPER=paru
  stub pacman 0 ""
  stub_script paru 'case "$*" in -Qu*) exit 0 ;; esac
echo "error: could not resolve host: aur.archlinux.org"; exit 1'
  update_system_aur >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "AUR indisponível (rede); repos oficiais atualizados via fallback pacman" ]]
  [ "$(grep -c '^paru -Syu' "$STUB_LOG")" -eq 3 ]
  grep -q "^pacman -Syu --noconfirm" "$STUB_LOG"
}

@test "update_system_aur: fallback pacman que também falha mantém warn com motivo" {
  AUR_HELPER=paru
  stub_script pacman 'case "$*" in -Syu*) exit 1 ;; esac'
  stub_script paru 'case "$*" in -Qu*) exit 0 ;; esac
echo "error: network is unreachable"; exit 1'
  update_system_aur >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == *"fallback pacman também falhou"* ]]
}

@test "update_system_aur: erro de PKGBUILD não repete e devolve o rc do paru" {
  AUR_HELPER=paru
  stub pacman 0 ""
  stub_script paru 'case "$*" in -Qu*) exit 0 ;; esac
echo "error: failed to commit transaction (conflicting files)"; exit 1'
  update_system_aur >/dev/null || status=$?
  [ "${status:-0}" -eq 1 ]
  [ "$(grep -c '^paru -Syu' "$STUB_LOG")" -eq 1 ]
}

@test "update_system_aur: sem helper AUR usa pacman" {
  AUR_HELPER=""
  stub pacman 0 ""
  run update_system_aur
  [ "$status" -eq 0 ]
  grep -q "^pacman -Syu --noconfirm" "$STUB_LOG"
}

@test "update_system_aur: yay e pikaur passam pelo retry comum" {
  stub pacman 0 ""
  stub yay 0 ""
  AUR_HELPER=yay run update_system_aur
  [ "$status" -eq 0 ]
  grep -q "^yay -Syu --noconfirm" "$STUB_LOG"
  stub pikaur 0 ""
  AUR_HELPER=pikaur run update_system_aur
  [ "$status" -eq 0 ]
  grep -q "^pikaur -Syu --noconfirm --noedit" "$STUB_LOG"
}

@test "aur_source_gone: 404 no download da fonte, e só ele" {
  run aur_source_gone "$(printf '%s\n' 'curl: (22) The requested URL returned error: 404' '==> ERRO: Falha ao baixar https://x/orca-linux.AppImage')"
  [ "$status" -eq 0 ]
  run aur_source_gone "curl: (22) The requested URL returned error: 404"
  [ "$status" -ne 0 ]
  run aur_source_gone "==> ERROR: Failure while downloading https://x (timeout)"
  [ "$status" -ne 0 ]
}

@test "update_system_aur: fonte em 404 não repete o paru e diz no motivo" {
  # Caso real (2026-11-19): stably-orca-bin 1.4.263 com o upstream fora do ar
  # fez 3 tentativas idênticas, com limpeza de cache entre elas.
  AUR_HELPER=paru
  stub pacman 0 ""
  stub_script paru 'case "$*" in -Qu*) exit 0 ;; esac
echo "curl: (22) The requested URL returned error: 404"
echo "==> ERRO: Falha ao baixar https://github.com/x/orca-linux.AppImage"
echo "erro: falha ao baixar fontes para '"'"'stably-orca-bin-1.4.263-1'"'"': "
echo "erro: pacotes falharam ao compilar: stably-orca-bin-1.4.263-1"
exit 1'
  update_system_aur >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_TODO" ]
  [ "$(grep -c -- '-Syu' "$STUB_LOG")" -eq 1 ]
  [[ "$STEP_REASON" == *"fonte do PKGBUILD em 404"* ]]
}
