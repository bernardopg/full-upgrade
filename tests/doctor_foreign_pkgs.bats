#!/usr/bin/env bats
# tests/doctor_foreign_pkgs.bats — U10: pacotes estrangeiros que o AUR não
# conhece (PKGBUILD local). pacman, RPC do AUR e API do GitHub são stubs.

load test_helper

setup() {
  load_libs
  for _p in "${FU_LIB}"/steps/doctor/*.sh; do source "$_p"; done; unset _p
  log() { printf '%s\n' "$*"; }
  log_raw() { :; }
  has() { [[ "$1" == pacman ]]; }
  pacman() {
    case "$1" in
      -Qm) printf 'dsearch-bin 2.0.0-1\ndankcalendar-bin 1:2.0.0-1\nparu 2.1.0-1\nparu-debug 2.1.0-1\npython-lockfile 0.12.2-15\nfoo-lib 1.0-1\n' ;;
      -Qi)
        case "$2" in
          dsearch-bin) echo 'URL             : https://github.com/duxlabs-dev/dux-search' ;;
          dankcalendar-bin) echo 'URL             : https://github.com/duxlabs-dev/dux-calendar.git' ;;
          python-lockfile) echo 'URL             : https://pypi.org/project/lockfile' ;;
          foo-lib) echo 'URL             : https://github.com/acme/foo' ;;
        esac ;;
    esac
  }
  # O AUR só conhece o paru.
  fetch_network_text() { echo '{"resultcount":1,"results":[{"Name":"paru","Version":"2.1.0-1"}],"type":"multiinfo","version":5}'; }
  github_latest_release_version() {
    case "$1" in
      duxlabs-dev/dux-search) echo 2.1.1 ;;
      duxlabs-dev/dux-calendar) echo 2.0.0 ;;
      *) return 1 ;;
    esac
  }
}

@test "aur_rpc_missing: devolve só os nomes que a RPC não trouxe" {
  run aur_rpc_missing '{"results":[{"Name":"paru"},{"Name": "yay"}]}' < <(printf 'paru\ndsearch-bin\nyay\n')
  [ "$output" = "dsearch-bin" ]
}

@test "github_repo_from_url: aceita .git, subcaminho e rejeita fora do GitHub" {
  run github_repo_from_url https://github.com/duxlabs-dev/dux-calendar.git
  [ "$output" = "duxlabs-dev/dux-calendar" ]
  run github_repo_from_url https://github.com/a/b/tree/main
  [ "$output" = "a/b" ]
  run github_repo_from_url https://gitlab.com/a/b
  [ "$status" -ne 0 ]
}

@test "pkg_upstream_version: tira epoch e pkgrel" {
  run pkg_upstream_version 1:2.0.0-3
  [ "$output" = "2.0.0" ]
  run pkg_upstream_version 0.12.2-15
  [ "$output" = "0.12.2" ]
}

@test "doctor_foreign_pkgs_upstream: pacote local atrás do release vira RC_TODO" {
  run doctor_foreign_pkgs_upstream
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"dsearch-bin 2.0.0 → 2.1.1 (github.com/duxlabs-dev/dux-search)"* ]]
  [[ "$output" == *"dankcalendar-bin 2.0.0: em dia"* ]]
  [[ "$output" == *"python-lockfile 0.12.2: URL fora do GitHub"* ]]
  [[ "$output" == *"foo-lib 1.0: sem release semver"* ]]
  [[ "$output" != *"paru-debug"* ]]
}

@test "doctor_foreign_pkgs_upstream: tudo no AUR => 0" {
  pacman() { [[ "$1" == -Qm ]] && echo 'paru 2.1.0-1'; }
  run doctor_foreign_pkgs_upstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"existem no AUR"* ]]
}

@test "doctor_foreign_pkgs_upstream: locais em dia => 0" {
  github_latest_release_version() { [[ "$1" == duxlabs-dev/* ]] && echo 2.0.0; }
  run doctor_foreign_pkgs_upstream
  [ "$status" -eq 0 ]
}

@test "doctor_foreign_pkgs_upstream: RPC indisponível vira RC_WARN" {
  fetch_network_text() { return "$RC_WARN"; }
  run doctor_foreign_pkgs_upstream
  [ "$status" -eq "$RC_WARN" ]
}

@test "doctor_foreign_pkgs_upstream: sem estrangeiros => 0" {
  pacman() { :; }
  run doctor_foreign_pkgs_upstream
  [ "$status" -eq 0 ]
  [[ "$output" == *"Nenhum pacote estrangeiro"* ]]
}
