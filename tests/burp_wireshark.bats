#!/usr/bin/env bats
# tests/burp_wireshark.bats — funções puras de steps.d/51-burp-suite.sh e steps.d/50-wireshark.sh

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/51-burp-suite.sh"
  # shellcheck source=/dev/null
  source "${FU_ROOT}/steps.d/50-wireshark.sh"
  MOCKDIR="$(mktemp -d)"
  export LOG_FILE="/dev/null"
}

teardown() {
  rm -rf "$MOCKDIR"
}

# ── burpsuite_java_bin ─────────────────────────────────────────────────────────

@test "burpsuite_java_bin: retorna BURPSUITE_JAVA_BIN quando definido" {
  mkdir -p "$MOCKDIR"
  touch "$MOCKDIR/java"
  chmod +x "$MOCKDIR/java"
  BURPSUITE_JAVA_BIN="$MOCKDIR/java"
  run burpsuite_java_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$MOCKDIR/java" ]
}

@test "burpsuite_java_bin: retorna JAVA_BIN quando BURPSUITE_JAVA_BIN vazio" {
  mkdir -p "$MOCKDIR"
  touch "$MOCKDIR/java"
  chmod +x "$MOCKDIR/java"
  unset BURPSUITE_JAVA_BIN
  JAVA_BIN="$MOCKDIR/java"
  run burpsuite_java_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$MOCKDIR/java" ]
}

@test "burpsuite_java_bin: prioriza BURPSUITE_JAVA_BIN sobre JAVA_BIN" {
  mkdir -p "$MOCKDIR/pri1" "$MOCKDIR/pri2"
  touch "$MOCKDIR/pri1/java1" "$MOCKDIR/pri2/java2"
  chmod +x "$MOCKDIR/pri1/java1" "$MOCKDIR/pri2/java2"
  BURPSUITE_JAVA_BIN="$MOCKDIR/pri1/java1"
  JAVA_BIN="$MOCKDIR/pri2/java2"
  run burpsuite_java_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$MOCKDIR/pri1/java1" ]
}

@test "burpsuite_java_bin: encontra java quando BURPSUITE_JAVA_BIN vazio" {
  # Remove todos os overrides; a função deve encontrar via command -v ou paths hardcoded
  unset BURPSUITE_JAVA_BIN JAVA_BIN
  run burpsuite_java_bin
  # Pelo menos um path deve ser encontrado (command -v java ou /usr/lib/jvm/*)
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# ── repair_broken_burpsuite_desktop_entries ─────────────────────────────────────

@test "repair_broken_burpsuite_desktop: sem diretório de atalhos => return 0" {
  HOME="$MOCKDIR/nobody"
  mkdir -p "$HOME"
  run repair_broken_burpsuite_desktop_entries
  [ "$status" -eq 0 ]
}

@test "repair_broken_burpsuite_desktop: sem atalhos BurpSuite => return 0" {
  HOME="$MOCKDIR"
  mkdir -p "$HOME/.local/share/applications"
  echo "something" > "$HOME/.local/share/applications/firefox.desktop"
  run repair_broken_burpsuite_desktop_entries
  [ "$status" -eq 0 ]
}

@test "repair_broken_burpsuite_desktop: atalho com Exec existente não é movido" {
  HOME="$MOCKDIR"
  mkdir -p "$HOME/.local/share/applications"
  # bash existe no sistema
  cat >"$HOME/.local/share/applications/BurpSuite.desktop" <<EOF
[Desktop Entry]
Name=Burp Suite
Exec=/bin/bash %U
Type=Application
EOF
  run repair_broken_burpsuite_desktop_entries
  [ "$status" -eq 0 ]
  # Arquivo não deve ter sido movido
  [ -f "$HOME/.local/share/applications/BurpSuite.desktop" ]
}

@test "repair_broken_burpsuite_desktop: atalho com Exec inexistente é movido" {
  HOME="$MOCKDIR"
  mkdir -p "$HOME/.local/share/applications"
  cat >"$HOME/.local/share/applications/BurpSuite.desktop" <<EOF
[Desktop Entry]
Name=Burp Suite
Exec=/opt/nonexistent/burpsuite %U
Type=Application
EOF
  run repair_broken_burpsuite_desktop_entries
  [ "$status" -eq 0 ]
  # Arquivo original deve ter sido movido para .broken.*
  [ ! -f "$HOME/.local/share/applications/BurpSuite.desktop" ]
  ls "$HOME/.local/share/applications/BurpSuite.desktop.broken."* >/dev/null 2>&1
}

@test "repair_broken_burpsuite_desktop: múltiplos atalhos quebrados são movidos" {
  HOME="$MOCKDIR"
  mkdir -p "$HOME/.local/share/applications"
  cat >"$HOME/.local/share/applications/BurpSuite1.desktop" <<EOF
[Desktop Entry]
Name=Burp Suite 1
Exec=/opt/burp1/nonexistent
Type=Application
EOF
  cat >"$HOME/.local/share/applications/BurpSuite2.desktop" <<EOF
[Desktop Entry]
Name=Burp Suite 2
Exec=/opt/burp2/nonexistent
Type=Application
EOF
  run repair_broken_burpsuite_desktop_entries
  [ "$status" -eq 0 ]
  [ ! -f "$HOME/.local/share/applications/BurpSuite1.desktop" ]
  [ ! -f "$HOME/.local/share/applications/BurpSuite2.desktop" ]
}

# ── repair_broken_burpsuite_desktop: parsing do Exec ───────────────────────────

@test "repair_broken_burpsuite_desktop: Exec com espaços e aspas" {
  HOME="$MOCKDIR"
  mkdir -p "$HOME/.local/share/applications"
  cat >"$HOME/.local/share/applications/BurpSuite.desktop" <<EOF
[Desktop Entry]
Name=Burp Suite
Exec="/opt/nonexistent path/burpsuite" --arg %U
Type=Application
EOF
  run repair_broken_burpsuite_desktop_entries
  [ "$status" -eq 0 ]
  # O parser extrai o primeiro token após remover aspas
  [ ! -f "$HOME/.local/share/applications/BurpSuite.desktop" ]
}

# ── wireshark_install_arch_package: mock via funções ──────────────────────────

@test "wireshark_install: já na versão mais recente => return 0" {
  # Mock pacman -Q e pacman -Si
  pacman() {
    case "$*" in
      "-Q wireshark-qt") printf 'wireshark-qt 4.4.0-1\n' ;;
      "-Si wireshark-qt") printf 'Version : 4.4.0-1\n' ;;
      *) return 1 ;;
    esac
  }
  run_logged() { return 0; }
  log() { :; }

  run wireshark_install_arch_package wireshark-qt
  [ "$status" -eq 0 ]
}

@test "wireshark_install: versão desatualizada invoca install" {
  pacman() {
    case "$*" in
      "-Q wireshark-qt") printf 'wireshark-qt 4.3.0-1\n' ;;
      "-Si wireshark-qt") printf 'Version : 4.4.0-1\n' ;;
      *) return 1 ;;
    esac
  }
  marker="${BATS_TEST_TMPDIR}/install_called"
  run_logged() { : > "$marker"; return 0; }
  log() { :; }

  run wireshark_install_arch_package wireshark-qt
  [ "$status" -eq 0 ]
  [ -f "$marker" ]
}

@test "wireshark_install: pacote não instalado invoca install" {
  pacman() {
    case "$*" in
      "-Q wireshark-qt") return 1 ;;
      *) return 1 ;;
    esac
  }
  marker="${BATS_TEST_TMPDIR}/install_called"
  run_logged() { : > "$marker"; return 0; }
  log() { :; }

  run wireshark_install_arch_package wireshark-qt
  [ "$status" -eq 0 ]
  [ -f "$marker" ]
}

# ── repair_wireshark_capture_permissions: precondições ─────────────────────────

@test "repair_wireshark_permissions: dumpcap ausente => return 1" {
  # Mock: remove /usr/bin/dumpcap do path
  has() {
    case "$1" in
      wireshark) return 1 ;;
      setcap) return 1 ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  # Override para que /usr/bin/dumpcap pareça ausente
  # Como não podemos remover o arquivo real, testamos a lógica indiretamente
  # Se dumpcap não existe no sistema, deve retornar 1
  if [[ ! -e /usr/bin/dumpcap ]]; then
    run repair_wireshark_capture_permissions
    [ "$status" -eq 1 ]
  else
    # Se dumpcap existe, este teste não se aplica — skip
    skip "dumpcap instalado no sistema"
  fi
}

@test "repair_wireshark_permissions: grupo wireshark ausente => return 1" {
  if [[ ! -e /usr/bin/dumpcap ]]; then
    skip "dumpcap não instalado"
  fi
  # Mock getent para retornar falha
  getent() { return 1; }
  has() {
    case "$1" in
      setcap) return 1 ;;
      *) command -v "$1" >/dev/null 2>&1 ;;
    esac
  }
  run repair_wireshark_capture_permissions
  [ "$status" -eq 1 ]
}
