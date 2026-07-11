#!/usr/bin/env bats
# tests/packaging.bats — invariantes de empacotamento/distribuição.

load test_helper

@test "entrypoint modular: --version não duplica prefixo v da tag git" {
  run bash "${FU_TEST_ROOT}/full-upgrade.sh" --version
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]
}

@test "systray service: fonte é template sem caminho de instalação hardcoded" {
  local service="${FU_TEST_ROOT}/res/full-upgrade-tray.service"
  [ -f "$service" ]
  grep -q '^ExecStart=@FULL_UPGRADE_EXEC@ --tray$' "$service"
  ! grep -q '/usr/bin/full-upgrade' "$service"
  ! grep -q '\.local/bin/full-upgrade' "$service"
  ! grep -q 'dms.service' "$service"
  ! grep -q 'wait-for-status-notifier' "$service"
}

@test "PKGBUILD: instala binário AUR em /usr/bin e materializa unit do tray para /usr/bin" {
  local pkgbuild="${FU_TEST_ROOT}/packaging/aur/PKGBUILD"
  [ -f "$pkgbuild" ]
  grep -q 'install -Dm755 dist/full-upgrade-standalone.sh "${pkgdir}/usr/bin/full-upgrade"' "$pkgbuild"
  grep -q 's|@FULL_UPGRADE_EXEC@|/usr/bin/full-upgrade|g' "$pkgbuild"
}

@test "install.sh: materializa unit local do tray para ~/.local/bin/full-upgrade" {
  local installer="${FU_TEST_ROOT}/install.sh"
  [ -f "$installer" ]
  grep -q 's|@FULL_UPGRADE_EXEC@|${BIN_DIR}/full-upgrade|g' "$installer"
}
