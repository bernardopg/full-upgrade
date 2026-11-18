#!/usr/bin/env bats
# tests/pacman_misc_cov.bats — reparos em volta do update do pacman: lock stale,
# GnuPG, conflito conhecido do VLC, chaves, limpeza de fontes AUR, retry comum
# de yay/pikaur, merge de .pacnew recusado e mirrorlist recente. PATH isolado.

load test_helper
load stub_helper

setup() {
  load_libs
  source "${FU_LIB}/steps/pacman.sh"
  stub_path_init
  stub_privilege
  LOG_FILE=/dev/null QUIET=0 STEP_REASON=""
  AUR_GRADLE_USER_HOME="$BATS_TEST_TMPDIR/gradle"
  sleep() { :; }
}

# ── lock, GnuPG, conflitos e chaves ──────────────────────────────────────────

@test "lock: ausente, em uso (fuser), gerenciador rodando e stale removido" {
  export PACMAN_DB_LOCK="$BATS_TEST_TMPDIR/db.lck"
  run ensure_pacman_lock_is_clean
  [[ "$output" == *"Sem lock do pacman"* ]]
  touch "$PACMAN_DB_LOCK"
  stub fuser 0 ""
  run ensure_pacman_lock_is_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"em uso por outro processo"* ]]
  rm "$STUB_BIN/fuser"; hash -r
  stub pgrep 0 ""
  run ensure_pacman_lock_is_clean
  [ "$status" -eq 1 ]
  [[ "$output" == *"gerenciador de pacotes em execucao"* ]]
  stub pgrep 1 ""
  run ensure_pacman_lock_is_clean
  [ "$status" -eq 0 ]
  [ ! -e "$PACMAN_DB_LOCK" ]
}

@test "gnupg: home ausente e reparo com crls.d, dirmngr e gpgconf" {
  export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
  run repair_gnupg_runtime
  [[ "$output" == *"GNUPG home não encontrado"* ]]
  mkdir -p "$GNUPGHOME/crls.d"; chmod 755 "$GNUPGHOME" "$GNUPGHOME/crls.d"
  stub systemctl 0 ""; stub gpgconf 0 ""
  run repair_gnupg_runtime
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$GNUPGHOME")" = 700 ]
  [ "$(stat -c %a "$GNUPGHOME/crls.d")" = 700 ]
  [ "$(stub_calls gpgconf)" = "--kill dirmngr" ]
  [[ "$(stub_calls systemctl)" == "--user reset-failed dirmngr.service dirmngr.socket" ]]
}

@test "conflito VLC: troca o plugin AUR pelo oficial; falha aborta; sem update pendente só informa" {
  stub_script pacman 'case "$1" in -Rdd) exit "${RDD_RC:-0}" ;; esac; exit 0'
  stub checkupdates 0 "vlc 3.0.21-1 -> 3.0.22-1"
  run repair_known_pacman_conflicts_before_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Trocando para o plugin oficial"* ]]
  stub_calls pacman | grep -q -- "-Syu --needed --noconfirm vlc-plugin-lua"
  RDD_RC=1 run repair_known_pacman_conflicts_before_update
  [ "$status" -eq 1 ]
  stub checkupdates 0 "linux 7.3.4-1 -> 7.3.5-1"
  run repair_known_pacman_conflicts_before_update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem conflitos pacman conhecidos"* ]]
}

@test "chaves: refresh falho segue em frente; sucesso popula archlinux" {
  stub pacman-key 1 ""
  run refresh_pacman_keys
  [ "$status" -eq 0 ]
  [[ "$output" == *"Falha ao atualizar chaves"* ]]
  stub pacman-key 0 ""
  run refresh_pacman_keys
  [ "$status" -eq 0 ]
  stub_calls pacman-key | grep -qx -- "--populate archlinux"
}

# ── AUR ───────────────────────────────────────────────────────────────────────

@test "purge AUR: apaga downloads parciais e preserva PKGBUILD" {
  export XDG_CACHE_HOME="$BATS_TEST_TMPDIR/cache"
  run _purge_aur_partial_sources
  [ "$status" -eq 0 ]
  d="$XDG_CACHE_HOME/paru/clone/foo"; mkdir -p "$d"
  touch "$d/foo-1.0.tar.gz.part" "$d/app.AppImage" "$d/PKGBUILD"
  _purge_aur_partial_sources
  [ -e "$d/PKGBUILD" ]
  [ ! -e "$d/foo-1.0.tar.gz.part" ]
  [ ! -e "$d/app.AppImage" ]
}

@test "retry comum: sucesso, erro não-rede e rede fora com fallback ok/falho" {
  stub yay 0 "ok"
  run _aur_syu_with_retry_and_fallback yay -Syu
  [ "$status" -eq 0 ]
  stub yay 3 "error: PKGBUILD inválido"
  run _aur_syu_with_retry_and_fallback yay -Syu
  [ "$status" -eq 3 ]
  [ "$(stub_calls yay | wc -l)" -eq 2 ]
  stub yay 1 "error: could not resolve host aur.archlinux.org"
  stub pacman 0 ""
  _aur_syu_with_retry_and_fallback yay -Syu >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "AUR indisponível (rede); repos oficiais atualizados via fallback pacman" ]
  stub pacman 1 ""
  unset status
  _aur_syu_with_retry_and_fallback yay -Syu >/dev/null || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [ "$STEP_REASON" = "AUR indisponível (rede); fallback pacman também falhou" ]
}

@test "update_system_aur: sem nenhum gerenciador Arch falha" {
  run update_system_aur
  [ "$status" -eq 1 ]
  [[ "$output" == *"Nenhum gerenciador de pacotes Arch encontrado"* ]]
}

# ── .pacnew e mirrorlist ─────────────────────────────────────────────────────

@test "pacnew_auto_merge: blocklist, merge recusado, cópia falha e mktemp falho ficam pendentes" {
  stub_script sudo 'case "$1" in test) shift; [ "$@" ];; cp) [[ -n "${CP_FAIL:-}" ]] && exit 1; exec "$@";; *) exec "$@";; esac'
  local cur="$BATS_TEST_TMPDIR/app.conf" left="$BATS_TEST_TMPDIR/left"
  printf 'A = 1\n' > "$cur"
  printf 'A = 2\n' > "$cur.pacnew"
  run pacnew_auto_merge "$left" /etc/sudoers.pacnew "$cur.pacnew"
  [[ "$output" == *"/etc/sudoers: merge automático desabilitado"* ]]
  [[ "$output" == *"diferença de configuração ativa; merge manual"* ]]
  [ "$(wc -l < "$left")" -eq 2 ]
  printf '#A = 1\n' > "$cur.pacnew"
  CP_FAIL=1 run pacnew_auto_merge "$left" "$cur.pacnew"
  [[ "$output" == *"falha ao gravar o merge; segue pendente"* ]]
  grep -qxF "$cur.pacnew" "$left"
  mktemp() { return 1; }
  pacnew_auto_merge "$left" "$cur.pacnew"
  grep -qxF "$cur.pacnew" "$left"
}

@test "pacnew_auto_merge: falha ao ler os arquivos via sudo deixa pendente" {
  stub_script sudo 'case "$1" in test) exit 0;; cat) exit 1;; *) exec "$@";; esac'
  local cur="$BATS_TEST_TMPDIR/app.conf" left="$BATS_TEST_TMPDIR/left"
  printf 'A = 1\n' > "$cur"; printf '#A = 1\n' > "$cur.pacnew"
  pacnew_auto_merge "$left" "$cur.pacnew"
  grep -qxF "$cur.pacnew" "$left"
}

@test "mirrors: backup inválido não é restaurado; mirrorlist recente pula o refresh" {
  printf '# vazio\n' > "$BATS_TEST_TMPDIR/bak"
  run _restore_mirror_backup "$BATS_TEST_TMPDIR/bak" "$BATS_TEST_TMPDIR/ml"
  [ "$status" -eq 1 ]
  [[ "$output" == *"backup do mirrorlist inválido/vazio"* ]]
  stub pacman 0 ""
  export PACMAN_MIRRORLIST="$BATS_TEST_TMPDIR/ml"
  printf 'Server = https://m/$repo/os/$arch\n' > "$PACMAN_MIRRORLIST"
  MIRROR_TOOL=auto MIRROR_MAX_AGE_DAYS=7 run refresh_mirrors
  [ "$status" -eq 0 ]
  [[ "$output" == *"pulando refresh (MIRROR_MAX_AGE_DAYS=7)"* ]]
}

@test "release_stale_lock: sudo -n recusado orienta a remoção manual" {
  export PACMAN_CONF_DB="$BATS_TEST_TMPDIR/db/"; mkdir -p "$PACMAN_CONF_DB"; touch "$PACMAN_CONF_DB/db.lck"
  stub_script pacman-conf 'echo "$PACMAN_CONF_DB"'
  stub pgrep 1 ""
  stub sudo 1 ""
  run pacman_release_stale_lock
  [[ "$output" == *"remova com: sudo rm"* ]]
}

@test "paru_failed_aur_pkgs: extrai nomes sem versão e ignora saída sem falha" {
  run paru_failed_aur_pkgs "error: falha ao compilar 'foo-git-1.2.3-1':
error: falha ao baixar fontes de 'bar-bin-2.0-3'
error: falha ao compilar 'foo-git-1.2.3-1':"
  [ "$output" = $'bar-bin\nfoo-git' ]
  run paru_failed_aur_pkgs "tudo certo"
  [ -z "$output" ]
}
