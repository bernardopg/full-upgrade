#!/usr/bin/env bats
# tests/manual_apps.bats — funções puras dos steps de apps manuais
# (helpers em lib/steps/manual_apps.sh; steps por domínio em ai.sh, security.sh,
# tools.sh e o inventário em doctor/packages.sh). Não mutam nada.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/manual_apps.sh"
  source "${FU_LIB}/steps/ai.sh"
  source "${FU_LIB}/steps/security.sh"
  source "${FU_LIB}/steps/tools.sh"
  source "${FU_LIB}/steps/doctor/packages.sh"
}

@test "_manual_apps_has_step: reconhece app coberto por step (droid)" {
  run _manual_apps_has_step droid
  [ "$status" -eq 0 ]
}

@test "_manual_apps_has_step: reconhece CLIs self-download cobertas" {
  for app in grok jcode qodercli qoderwake kimchi cua-driver; do
    run _manual_apps_has_step "$app"
    [ "$status" -eq 0 ] || {
      echo "app não coberto: $app"
      return 1
    }
  done
}

@test "_manual_apps_has_step: reconhece marcador de diretório /opt (zaproxy)" {
  run _manual_apps_has_step zaproxy
  [ "$status" -eq 0 ]
}

@test "_manual_apps_has_step: app sem step retorna não-zero" {
  # 'idea' (JetBrains em /opt) é um app manual sem step de atualização dedicado.
  run _manual_apps_has_step idea
  [ "$status" -ne 0 ]
}

@test "_manual_apps_has_step: nome vazio não é coberto" {
  run _manual_apps_has_step ""
  [ "$status" -ne 0 ]
}

@test "update_grok: extrai semver e não aplica quando latest é igual" {
  _ma_silence
  local applied="$BATS_TEST_TMPDIR/grok-applied"
  has() { [[ "$1" == grok ]]; }
  grok() {
    [[ "${1:-}" == --version ]] && { printf 'grok 0.2.93 (hash) [stable]\n'; return 0; }
    return 99
  }
  run_network_cmd() {
    if [[ "$*" == "grok update --check" ]]; then
      printf 'Grok Build - v0.2.93 (latest: 0.2.93) [stable]\n'
    else
      : >"$applied"
      return 99
    fi
  }
  run update_grok
  [ "$status" -eq 0 ]
  [ ! -e "$applied" ]
}

@test "_manual_apps_kind: app coberto vira covered" {
  run _manual_apps_kind droid
  [ "$output" = "covered" ]
}

@test "_manual_apps_kind: backups manuais viram backup" {
  run _manual_apps_kind dumpcap.manual.20260628-215302
  [ "$output" = "backup" ]
  run _manual_apps_kind antigravity.manual-backup-20260628213513
  [ "$output" = "backup" ]
  run _manual_apps_kind nomacs-original
  [ "$output" = "backup" ]
}

@test "_manual_apps_kind: tshark/sharkd viram auxiliares" {
  run _manual_apps_kind tshark
  [ "$output" = "auxiliary" ]
  run _manual_apps_kind sharkd
  [ "$output" = "auxiliary" ]
}

@test "_manual_apps_kind: app real sem step vira candidate" {
  run _manual_apps_kind codexbar
  [ "$output" = "candidate" ]
  run _manual_apps_kind idea-2026.1.3
  [ "$output" = "candidate" ]
}

@test "catálogo: steps de apps manuais presentes e bem-formados" {
  run step_catalog
  [ "$status" -eq 0 ]
  [[ "$output" == *"Atualizar Factory droid|ai|"* ]]
  [[ "$output" == *"Atualizar grok (xAI CLI)|ai|"* ]]
  [[ "$output" == *"Atualizar cua-driver|tools|"* ]]
  [[ "$output" == *"Atualizar Snyk CLI|security|"* ]]
  [[ "$output" == *"Atualizar OWASP ZAP (core e add-ons)|security|"* ]]
  [[ "$output" == *"Doctor: apps manuais (fora de pacote)|doctor|"* ]]
}

@test "catálogo: categoria tools mapeia para o grupo IDEs e Apps" {
  run _group_label_for_category tools
  [ "$status" -eq 0 ]
  [ "$output" = "IDEs e Apps" ]
}

@test "_manual_write_prefix: destino escrevível não exige sudo (prefixo vazio)" {
  tmp="$(mktemp)"
  run _manual_write_prefix "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_manual_write_prefix: destino não escrevível + sudo disponível => imprime sudo" {
  # Diretório inexistente => não escrevível para qualquer uid (inclui root no CI)
  local tmp="$BATS_TEST_TMPDIR/nao-existe/app"
  has() { [[ "$1" == sudo ]]; }
  sudo() { [[ "$*" == "-n true" ]]; }
  run _manual_write_prefix "$tmp"
  [ "$status" -eq 0 ]
  [ "$output" = "sudo" ]
}

@test "_manual_write_prefix: destino não escrevível + sem sudo => retorna 1" {
  local tmp="$BATS_TEST_TMPDIR/nao-existe/app"
  has() { return 1; }
  run _manual_write_prefix "$tmp"
  [ "$status" -ne 0 ]
}

# ── update_* (self-updaters; mocks de comandos externos) ──────────────────────
# Helpers comuns: neutraliza I/O e rede por padrão.
_ma_silence() { log() { :; }; log_raw() { :; }; }

@test "update_droid: ausente => return 0 (skip)" {
  _ma_silence; has() { return 1; }
  run update_droid
  [ "$status" -eq 0 ]
}

@test "update_droid: já atualizado => return 0" {
  _ma_silence
  has() { [[ "$1" == droid ]]; }
  droid() { echo "droid 1.2.3"; }
  run_network_cmd() { echo "already up-to-date"; return 0; }
  run update_droid
  [ "$status" -eq 0 ]
}

@test "update_droid: falha no --check => RC_WARN" {
  _ma_silence
  has() { [[ "$1" == droid ]]; }
  droid() { echo "droid 1.2.3"; }
  run_network_cmd() { return 1; }
  run update_droid
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_droid: update real bem-sucedido => return 0" {
  _ma_silence
  has() { [[ "$1" == droid ]]; }
  droid() { echo "droid 2.0.0"; }
  run_network_cmd() { echo "downloading update"; return 0; }
  run update_droid
  [ "$status" -eq 0 ]
}

@test "update_jcode: já atualizado pelo GitHub => não chama update mutante" {
  _ma_silence
  has() { [[ "$1" == jcode || "$1" == curl ]]; }
  jcode() {
    if [[ "$1" == version ]]; then
      printf '{"semver":"1.2.3"}\n'
    elif [[ "$1" == update ]]; then
      return 99
    fi
  }
  run_network_cmd() { printf '{"tag_name":"v1.2.3"}\n'; }
  run update_jcode
  [ "$status" -eq 0 ]
}

@test "update_jcode: release mais nova chama jcode update" {
  _ma_silence
  has() { [[ "$1" == jcode || "$1" == curl ]]; }
  local updated_file="$BATS_TEST_TMPDIR/jcode-updated"
  jcode() {
    if [[ "$1" == version ]]; then
      printf '{"semver":"1.2.3"}\n'
    elif [[ "$1" == update ]]; then
      : > "$updated_file"
      return 0
    fi
  }
  run_network_cmd() {
    if [[ "$1" == curl ]]; then
      printf '{"tag_name":"v1.2.4"}\n'
    else
      "$@"
    fi
  }
  run update_jcode
  [ "$status" -eq 0 ]
  [ -e "$updated_file" ]
}

@test "update_jcode: versão local desconhecida não chama update mutante" {
  _ma_silence
  has() { [[ "$1" == jcode || "$1" == curl ]]; }
  local updated_file="$BATS_TEST_TMPDIR/jcode-updated"
  jcode() {
    if [[ "$1" == update ]]; then
      : > "$updated_file"
      return 0
    fi
    return 0
  }
  run_network_cmd() { printf '{"tag_name":"v1.2.4"}\n'; }
  run update_jcode
  [ "$status" -eq "$RC_WARN" ]
  [ ! -e "$updated_file" ]
}

@test "update_coderabbit: ausente => 0; falha => RC_WARN; sucesso => 0" {
  _ma_silence
  has() { return 1; }
  run update_coderabbit; [ "$status" -eq 0 ]

  has() { [[ "$1" == coderabbit ]]; }
  coderabbit() { echo "coderabbit 1.0"; }
  run_network_cmd() { return 1; }
  run update_coderabbit; [ "$status" -eq "$RC_WARN" ]

  run_network_cmd() { echo ok; return 0; }
  run update_coderabbit; [ "$status" -eq 0 ]
}

@test "update_kiro_cli: ausente => 0; falha => RC_WARN; sucesso => 0" {
  _ma_silence
  has() { return 1; }
  run update_kiro_cli; [ "$status" -eq 0 ]

  has() { [[ "$1" == kiro-cli ]]; }
  kiro-cli() { echo "kiro-cli 0.1"; }
  run_network_cmd() { return 1; }
  run update_kiro_cli; [ "$status" -eq "$RC_WARN" ]

  run_network_cmd() { echo ok; return 0; }
  run update_kiro_cli; [ "$status" -eq 0 ]
}

@test "update_snyk: ausente => 0" {
  _ma_silence; has() { return 1; }
  run update_snyk; [ "$status" -eq 0 ]
}

@test "update_snyk: gerenciado por npm => 0 (skip)" {
  _ma_silence
  has() { [[ "$1" == snyk || "$1" == curl ]]; }
  command() { if [[ "$1" == -v && "$2" == snyk ]]; then echo /usr/lib/node_modules/snyk/bin/snyk; else builtin command "$@"; fi; }
  readlink() { echo /usr/lib/node_modules/snyk/bin/snyk; }
  run update_snyk
  [ "$status" -eq 0 ]
}

@test "update_zap: ausente => 0 (skip)" {
  _ma_silence
  command() { if [[ "$1" == -v ]]; then return 1; else builtin command "$@"; fi; }
  run update_zap
  [ "$status" -eq 0 ]
}

@test "zap_release_asset_info: extrai versão, URL e digest do asset Linux" {
  local digest="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  local json='{"tag_name":"v2.17.0","assets":[{"name":"ZAP_2.17.0_Linux.tar.gz","browser_download_url":"https://example/ZAP.tgz","digest":"sha256:'"$digest"'"}]}'
  run zap_release_asset_info <<< "$json"
  [ "$status" -eq 0 ]
  [ "$output" = $'2.17.0\thttps://example/ZAP.tgz\t'"$digest" ]
}

@test "zap_release_asset_info: rejeita asset sem sha256 publicado" {
  run zap_release_asset_info <<< '{"tag_name":"v2.17.0","assets":[]}'
  [ "$status" -ne 0 ]
}

@test "zap_free_port: retorna porta TCP válida" {
  run zap_free_port
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+$ ]]
  [ "$output" -gt 0 ]
}

@test "update_gk: ausente => 0; sem curl/unzip => 0" {
  _ma_silence
  has() { return 1; }
  run update_gk; [ "$status" -eq 0 ]

  has() { [[ "$1" == gk ]]; }   # gk existe mas curl/unzip não
  run update_gk; [ "$status" -eq 0 ]
}

@test "_selfupdate_direct: update ok retorna 0" {
  has() { return 0; }
  run_network_cmd() { printf 'pool is already at v1.0.16.\n'; return 0; }
  run _selfupdate_direct "pool (Poolside)" pool
  [ "$status" -eq 0 ]
}

@test "_selfupdate_direct: falha vira RC_WARN com motivo" {
  has() { return 0; }
  run_network_cmd() { printf 'checksum mismatch\n'; return 1; }
  STEP_REASON=""
  _selfupdate_direct "purple" purple || status=$?
  [ "${status:-0}" -eq "$RC_WARN" ]
  [[ "$STEP_REASON" == "purple update falhou (rc=1)" ]]
}

@test "_selfupdate_direct: ausente é no-op" {
  has() { return 1; }
  run_network_cmd() { echo "não devia rodar"; return 1; }
  run _selfupdate_direct "purple" purple
  [ "$status" -eq 0 ]
}

# Release falso do GitHub: tag v2.0.0 com tar.gz + checksums goreleaser.
_fake_github_release() {
  local rel="$BATS_TEST_TMPDIR/rel" sum="${1:-good}"
  mkdir -p "$rel" "$HOME/.local/bin"
  printf '#!/bin/sh\necho "gitleaks version 2.0.0"\n' >"$rel/gitleaks"
  chmod +x "$rel/gitleaks"
  tar -czf "$rel/gitleaks_2.0.0_linux_x64.tar.gz" -C "$rel" gitleaks
  if [[ "$sum" == good ]]; then
    (cd "$rel" && sha256sum gitleaks_2.0.0_linux_x64.tar.gz >gitleaks_2.0.0_checksums.txt)
  else
    printf '%064d  gitleaks_2.0.0_linux_x64.tar.gz\n' 0 >"$rel/gitleaks_2.0.0_checksums.txt"
  fi
  printf '#!/bin/sh\necho "gitleaks version 1.0.0"\n' >"$HOME/.local/bin/gitleaks"
  chmod +x "$HOME/.local/bin/gitleaks"
  PATH="$HOME/.local/bin:$PATH"
  uname() { echo x86_64; }
  curl() {
    local out="" url="" a
    while (($#)); do
      case "$1" in -o) out="$2"; shift ;; -w) printf 'https://github.com/gitleaks/gitleaks/releases/tag/v2.0.0'; return 0 ;; http*) url="$1" ;; esac
      shift
    done
    cp "$BATS_TEST_TMPDIR/rel/${url##*/}" "$out"
  }
}

@test "_github_release_bin_update: troca o binário quando o sha256 confere" {
  export HOME="$BATS_TEST_TMPDIR/home"
  _fake_github_release good
  _github_release_bin_update gitleaks gitleaks gitleaks/gitleaks x64 arm64
  run "$HOME/.local/bin/gitleaks" --version
  [[ "$output" == *"2.0.0"* ]]
}

@test "_github_release_bin_update: checksum divergente mantém o binário" {
  export HOME="$BATS_TEST_TMPDIR/home"
  _fake_github_release bad
  _github_release_bin_update gitleaks gitleaks gitleaks/gitleaks x64 arm64 || status=$?
  [ "${status:-0}" -eq 1 ]
  run "$HOME/.local/bin/gitleaks" --version
  [[ "$output" == *"1.0.0"* ]]
}

@test "_github_release_bin_update: já na última versão não baixa nada" {
  export HOME="$BATS_TEST_TMPDIR/home"
  _fake_github_release good
  printf '#!/bin/sh\necho "gitleaks version 2.0.0"\n' >"$HOME/.local/bin/gitleaks"
  rm "$BATS_TEST_TMPDIR/rel/"*.tar.gz
  # Sem tar.gz no release falso: qualquer tentativa de download falharia.
  run _github_release_bin_update gitleaks gitleaks gitleaks/gitleaks x64 arm64
  [ "$status" -eq 0 ]
}

@test "update_cloudflared: rc 11 do upstream (atualizado) é sucesso" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.9router/bin"
  printf '#!/bin/sh\n[ "$1" = update ] && exit 11\necho "cloudflared version 2026.9.3"\n' >"$HOME/.9router/bin/cloudflared"
  chmod +x "$HOME/.9router/bin/cloudflared"
  run update_cloudflared
  [ "$status" -eq 0 ]
}

@test "update_cloudflared: rc diferente de 0/11 vira RC_WARN" {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.local/bin"
  printf '#!/bin/sh\n[ "$1" = update ] && exit 1\n' >"$HOME/.local/bin/cloudflared"
  chmod +x "$HOME/.local/bin/cloudflared"
  run update_cloudflared
  [ "$status" -eq "$RC_WARN" ]
}

@test "update_muse: usa o modo instalador do launcher" {
  has() { [[ "$1" == muse ]]; }
  muse() { echo "Muse Code 1.4.0"; }
  run_network_cmd() { [[ "${MUSE_LAUNCHER_INSTALL:-}" == 1 ]] || return 1; }
  run update_muse
  [ "$status" -eq 0 ]
}
