#!/usr/bin/env bats
# tests/self_update.bats — comparação de versão (função pura) do auto-update

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
  # self_update.sh não é carregado por load_libs (é um step); carrega aqui.
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/self_update.sh"
}

# ── _self_normalize_version ───────────────────────────────────────────────────

@test "normalize: remove prefixo v" {
  run _self_normalize_version "v3.0.4"
  [ "$output" = "3.0.4" ]
}

@test "normalize: corta sufixo de git describe" {
  run _self_normalize_version "3.0.3-2-gabc123"
  [ "$output" = "3.0.3" ]
}

@test "normalize: versão já limpa passa intacta" {
  run _self_normalize_version "3.0.4"
  [ "$output" = "3.0.4" ]
}

# ── parsers de release/latest ────────────────────────────────────────────────

@test "latest-json: extrai tag_name da API" {
  out="$(printf '%s\n' '{"tag_name":"v3.8.1","name":"full-upgrade v3.8.1"}' | self_extract_tag_from_release_json)"
  [ "$out" = "v3.8.1" ]
}

@test "latest-url: extrai tag do redirect /releases/latest" {
  out="$(printf '%s\n' 'https://github.com/bernardopg/full-upgrade/releases/tag/v3.8.1' | self_extract_tag_from_latest_url)"
  [ "$out" = "v3.8.1" ]
}

@test "latest-url: ignora query, fragmento e barra final" {
  out="$(printf '%s\n' 'https://github.com/bernardopg/full-upgrade/releases/tag/v3.8.1/?x=1#y' | self_extract_tag_from_latest_url)"
  [ "$out" = "v3.8.1" ]
}

@test "self_latest_version: fallback por redirect quando API falha" {
  has() { [[ "$1" == curl ]]; }
  curl() {
    local args="$*"
    if [[ "$args" == *api.github.com* ]]; then
      return 22
    fi
    if [[ "$args" == *releases/latest* ]]; then
      printf '%s' 'https://github.com/bernardopg/full-upgrade/releases/tag/v3.8.1'
      return 0
    fi
    return 1
  }
  run self_latest_version
  [ "$status" -eq 0 ]
  [ "$output" = "3.8.1" ]
}

# ── self_version_compare (0=igual, 1=a>b, 2=a<b) ──────────────────────────────

@test "compare: versões iguais retornam 0" {
  run self_version_compare "3.0.4" "3.0.4"
  [ "$output" = "0" ]
}

@test "compare: a < b (patch) retorna 2" {
  run self_version_compare "3.0.3" "3.0.4"
  [ "$output" = "2" ]
}

@test "compare: a > b (patch) retorna 1" {
  run self_version_compare "3.0.4" "3.0.3"
  [ "$output" = "1" ]
}

@test "compare: ordenação numérica (3.0.10 > 3.0.3), não lexical" {
  run self_version_compare "3.0.10" "3.0.3"
  [ "$output" = "1" ]
}

@test "compare: minor maior vence patch" {
  run self_version_compare "3.1.0" "3.0.9"
  [ "$output" = "1" ]
}

@test "compare: major maior vence tudo" {
  run self_version_compare "4.0.0" "3.9.9"
  [ "$output" = "1" ]
}

@test "compare: prefixo v é ignorado em ambos os lados" {
  run self_version_compare "v3.0.3" "3.0.4"
  [ "$output" = "2" ]
}

@test "compare: sufixo git describe é ignorado" {
  run self_version_compare "3.0.4-5-gdeadbee" "3.0.4"
  [ "$output" = "0" ]
}

@test "compare: número de campos diferente (3.0 vs 3.0.1)" {
  run self_version_compare "3.0" "3.0.1"
  [ "$output" = "2" ]
}

# ── self_update_notice ────────────────────────────────────────────────────────

@test "notice: curl ausente => 0 sem RC_TODO" {
  has() { return 1; }
  SCRIPT_VERSION="3.0.0"
  QUIET=0
  run self_update_notice
  [ "$status" -eq 0 ]
  [[ "$output" == *"curl ausente"* ]]
}

@test "notice: versão nova disponível => RC_TODO" {
  has() { [[ "$1" == curl ]]; }
  self_latest_version() { printf '3.1.0'; }
  SCRIPT_VERSION="3.0.0"
  STEP_REASON=""
  QUIET=0
  run self_update_notice
  [ "$status" -eq "$RC_TODO" ]
  [[ "$output" == *"Nova versão disponível"* ]]
  [[ "$output" == *"3.0.0"* ]]
  [[ "$output" == *"3.1.0"* ]]
}

@test "notice: já está na versão mais recente => 0" {
  has() { [[ "$1" == curl ]]; }
  self_latest_version() { printf '3.0.0'; }
  SCRIPT_VERSION="3.0.0"
  QUIET=0
  run self_update_notice
  [ "$status" -eq 0 ]
  [[ "$output" == *"atualizado"* ]]
}

@test "notice: versão local mais nova que latest => 0 (pré-release)" {
  has() { [[ "$1" == curl ]]; }
  self_latest_version() { printf '3.0.0'; }
  SCRIPT_VERSION="3.1.0"
  QUIET=0
  run self_update_notice
  [ "$status" -eq 0 ]
}

@test "notice: API indisponível (latest vazio) => 0 sem RC_TODO" {
  has() { [[ "$1" == curl ]]; }
  self_latest_version() { return 1; }
  SCRIPT_VERSION="3.0.0"
  QUIET=0
  run self_update_notice
  [ "$status" -eq 0 ]
  [[ "$output" == *"possível consultar"* ]]
}

@test "notice: canal main => 0 sem RC_TODO" {
  has() { [[ "$1" == curl ]]; }
  self_latest_version() { printf 'main'; }
  SCRIPT_VERSION="3.0.0"
  QUIET=0
  run self_update_notice
  [ "$status" -eq 0 ]
  [[ "$output" == *"Canal 'main'"* ]]
}

# ── self_pacman_managed_bin ───────────────────────────────────────────────────
# Cobra que o auto-update do --update não crie sombra sobre uma instalação AUR.
# /usr/bin/full-upgrade pertencente ao pacman => ecoa o caminho; caso contrário rc 1.

@test "self_pacman_managed_bin: pacman ausente => rc 1" {
  has() { return 1; }
  run self_pacman_managed_bin
  [ "$status" -eq 1 ]
}

@test "self_pacman_managed_bin: pacman presente, /usr/bin/full-upgrade inexistente => rc 1" {
  has() { [[ "$1" == pacman ]]; }
  # [[ -e ]] curto-circuita antes de pacman -Qo: o caminho fixo não existe.
  [ -e /usr/bin/full-upgrade ] && skip "ambiente tem /usr/bin/full-upgrade; teste só válido sem ele"
  run self_pacman_managed_bin
  [ "$status" -eq 1 ]
}

@test "self_pacman_managed_bin: existe mas não é owned => rc 1" {
  has() { [[ "$1" == pacman ]]; }
  local sysbin="/usr/bin/full-upgrade"
  [ -e "$sysbin" ] || skip "teste requer /usr/bin/full-upgrade neste ambiente"
  pacman() { return 1; }   # -Qo nega a propriedade
  run self_pacman_managed_bin
  [ "$status" -eq 1 ]
}

@test "self_pacman_managed_bin: owned pelo pacman => ecoa /usr/bin/full-upgrade" {
  has() { [[ "$1" == pacman ]]; }
  pacman() { return 0; }   # simula -Qo sucesso
  local sysbin="/usr/bin/full-upgrade"
  [ -e "$sysbin" ] || skip "teste requer /usr/bin/full-upgrade neste ambiente"
  run self_pacman_managed_bin
  [ "$status" -eq 0 ]
  [ "$output" = "$sysbin" ]
}

# ── self_local_shadow_kind (none | dev | self) ────────────────────────────────

@test "shadow_kind: arquivo inexistente => none" {
  run self_local_shadow_kind "/tmp/fu-shadow-nao-existe-$$"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
}

@test "shadow_kind: symlink para checkout git => dev (preservar)" {
  local repo
  repo=$(mktemp -d)
  git -C "$repo" init -q
  printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/full-upgrade.sh"
  local link="/tmp/fu-shadow-dev-$$"
  ln -sf "$repo/full-upgrade.sh" "$link"
  run self_local_shadow_kind "$link"
  local rc="$status"
  rm -f "$link"; rm -rf "$repo"
  [ "$rc" -eq 0 ]
  [ "$output" = "dev" ]
}

@test "shadow_kind: arquivo comum (não symlink) => self" {
  local plain
  plain=$(mktemp)
  run self_local_shadow_kind "$plain"
  local rc="$status"
  rm -f "$plain"
  [ "$rc" -eq 0 ]
  [ "$output" = "self" ]
}

@test "shadow_kind: symlink para fora de git => self" {
  local target link
  target=$(mktemp)
  link="/tmp/fu-shadow-nogit-$$"
  ln -sf "$target" "$link"
  run self_local_shadow_kind "$link"
  local rc="$status"
  rm -f "$link" "$target"
  [ "$rc" -eq 0 ]
  [ "$output" = "self" ]
}

# ── repair_full_upgrade_shadow ────────────────────────────────────────────────
# Reparo real: remove ~/.local/bin/full-upgrade (e ~/.local/share/full-upgrade)
# quando a instalação é pacman-managed, preservando o symlink de desenvolvimento.

@test "repair_shadow: não-pacman => rc 0, mensagem 'nada a reparar'" {
  QUIET=0 LOG_FILE=/dev/null     # log() deve ir para stdout (capturado pelo run)
  self_pacman_managed_bin() { return 1; }   # não gerenciado
  run repair_full_upgrade_shadow
  [ "$status" -eq 0 ]
  [[ "$output" == *"nada a reparar"* ]]
}

@test "repair_shadow: pacman-managed, sem cópia local => rc 0, 'sem cópia'" {
  QUIET=0 LOG_FILE=/dev/null
  self_pacman_managed_bin() { printf '/usr/bin/full-upgrade\n'; }
  self_local_shadow_kind() { printf 'none'; }
  run repair_full_upgrade_shadow
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sem cópia local"* ]]
}

@test "repair_shadow: pacman-managed, symlink dev => rc 0, mantém" {
  QUIET=0 LOG_FILE=/dev/null
  self_pacman_managed_bin() { printf '/usr/bin/full-upgrade\n'; }
  self_local_shadow_kind() { printf 'dev'; }
  run repair_full_upgrade_shadow
  [ "$status" -eq 0 ]
  [[ "$output" == *"mantendo"* ]]
}

@test "repair_shadow: pacman-managed, sombra self => remove bin, .bak e share" {
  QUIET=0 LOG_FILE=/dev/null
  local fake_home
  fake_home=$(mktemp -d)
  mkdir -p "$fake_home/.local/bin" "$fake_home/.local/share/full-upgrade"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$fake_home/.local/bin/full-upgrade"
  printf 'old\n' > "$fake_home/.local/bin/full-upgrade.bak"
  printf 'standalone\n' > "$fake_home/.local/share/full-upgrade/full-upgrade.sh"

  self_pacman_managed_bin() { printf '/usr/bin/full-upgrade\n'; }
  pacman() { printf 'full-upgrade 3.22.0-1\n'; }
  self_local_shadow_kind() { printf 'self'; }
  HOME="$fake_home" run repair_full_upgrade_shadow

  local rc="$status"
  [ "$rc" -eq 0 ]
  [[ "$output" == *"Removendo sombra local obsoleta"* ]]
  # O binário sombra e o .bak foram removidos.
  [ ! -e "$fake_home/.local/bin/full-upgrade" ]
  [ ! -e "$fake_home/.local/bin/full-upgrade.bak" ]
  # A instalação standalone antiga sob .local/share também sumiu.
  [ ! -e "$fake_home/.local/share/full-upgrade/full-upgrade.sh" ]
  [[ "$output" == *"resolve para /usr/bin/full-upgrade"* ]]
  rm -rf "$fake_home"
}
