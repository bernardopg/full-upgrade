#!/usr/bin/env bats
# tests/pi.bats — atualização do pi (pi-coding-agent, H1). Self-update nativo
# `pi update` + refrescamento dos catálogos de modelos ("lista de IA") via
# `pi update --models`. Não executa updaters reais nem rede: tudo é stub.

load test_helper

setup() {
  load_libs
  # shellcheck source=/dev/null
  source "${FU_LIB}/steps/ai.sh"
  QUIET=0
  STEP_REASON=""
}

@test "pi: ausente retorna 0" {
  has() { return 1; }
  run update_pi
  [ "$status" -eq 0 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "pi: self-update ok + extensões ok + models ok retorna 0 e loga as três fases" {
  has() { [[ "$1" == pi ]]; }
  pi() { [[ "$1" == --version ]] && printf '0.84.1\n'; }
  run_network_cmd() {
    case "$*" in
      *"--models") printf 'Model catalogs refreshed\n'; return 0 ;;
      *"--extensions") printf 'Extensions are up to date\n'; return 0 ;;
      *) printf 'pi is already up to date (v0.84.1)\n'; return 0 ;;
    esac
  }
  run update_pi
  [ "$status" -eq 0 ]
  [[ "$output" == *"pi atual: 0.84.1"* ]]
  [[ "$output" == *"pi agora: 0.84.1"* ]]
  # Refrescamento da "lista de IA" (catálogos de modelos) foi anunciado e rodou.
  [[ "$output" == *"lista de IA"* ]]
  [[ "$output" == *"Model catalogs refreshed"* ]]
  # Extensões: `pi update` sozinho as pula ("Extensions are skipped").
  [[ "$output" == *"Extensions are up to date"* ]]
}

# Regressão: `pi update` imprime "Extensions are skipped. Run pi update
# --extensions" — sem a fase própria, as extensões nunca eram atualizadas.
@test "pi: fase de extensões é invocada explicitamente" {
  has() { [[ "$1" == pi ]]; }
  pi() { [[ "$1" == --version ]] && printf '0.84.1\n'; }
  run_network_cmd() { printf 'ARGS:%s\n' "$*"; return 0; }
  run update_pi
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGS:pi update --extensions"* ]]
  [[ "$output" == *"ARGS:pi update --models"* ]]
}

# Regressão: extensões em falha não podem abortar o refresh dos catálogos — o
# binário já foi atualizado na fase 1.
@test "pi: falha nas extensões vira RC_WARN mas não impede o refresh de models" {
  has() { [[ "$1" == pi ]]; }
  pi() { [[ "$1" == --version ]] && printf '0.84.1\n'; }
  run_network_cmd() {
    case "$*" in
      *"--extensions") printf 'boom\n'; return 1 ;;
      *"--models") printf 'Model catalogs refreshed\n'; return 0 ;;
      *) return 0 ;;
    esac
  }
  run update_pi
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha ao atualizar extensões"* ]]
  [[ "$output" == *"Model catalogs refreshed"* ]]
  [[ "$output" == *"pi agora: 0.84.1"* ]]
}

@test "pi: retry Node sem auto-seleção de família recupera timeout IPv6" {
  local calls_file="$BATS_TEST_TMPDIR/pi-network-calls"
  : > "$calls_file"
  has() { [[ "$1" == pi ]]; }
  pi() { [[ "$1" == --version ]] && printf '0.84.1\n'; }
  run_network_cmd() {
    local calls
    calls="$(wc -l < "$calls_file")"
    printf '%s\n' x >> "$calls_file"
    if (( calls == 0 )); then
      printf 'AggregateError [ETIMEDOUT]\n'
      return "$RC_WARN"
    fi
    if (( calls == 1 )); then
      [[ "${NODE_OPTIONS:-}" == *"--no-network-family-autoselection"* ]]
    fi
    printf 'ok\n'
  }

  run update_pi

  [ "$status" -eq 0 ]
  [[ "$output" == *"repetindo sem auto-seleção IPv6/IPv4"* ]]
  [ "$(wc -l < "$calls_file")" -eq 4 ]
}

@test "pi: falha de rede no self-update vira RC_WARN" {
  has() { [[ "$1" == pi ]]; }
  pi() { [[ "$1" == --version ]] && printf '0.84.1\n'; }
  run_network_cmd() { printf 'could not resolve host\n'; return "$RC_WARN"; }
  run update_pi
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha de rede ao atualizar"* ]]
  # Models não chegam a rodar: o passo aborta no self-update.
  [[ "$output" != *"lista de IA"* ]]
}

@test "pi: falha não-rede no self-update vira RC_WARN (não fatal)" {
  has() { [[ "$1" == pi ]]; }
  pi() { [[ "$1" == --version ]] && printf '0.84.1\n'; }
  run_network_cmd() { printf 'erro qualquer\n'; return 1; }
  run update_pi
  [ "$status" -eq "$RC_WARN" ]
  [[ "$output" == *"falha ao atualizar (rc="* ]]
}

@test "pi: self-update ok mas models em falha de rede vira RC_WARN" {
  has() { [[ "$1" == pi ]]; }
  pi() { [[ "$1" == --version ]] && printf '0.84.1\n'; }
  run_network_cmd() {
    case "$*" in
      *"--models") printf 'ETIMEDOUT\n'; return "$RC_WARN" ;;
      *) printf 'pi is already up to date (v0.84.1)\n'; return 0 ;;
    esac
  }
  run update_pi
  [ "$status" -eq "$RC_WARN" ]
  # Self-update rodou (anúncio da lista de IA aparece); só o models falhou.
  [[ "$output" == *"lista de IA"* ]]
  [[ "$output" == *"falha de rede ao refrescar catálogos"* ]]
}

@test "catálogo: step do pi está registrado com func própria e cmd_deps pi" {
  local line func deps
  line="$(step_catalog | awk -F'|' '$1 == "Atualizar pi (pi-coding-agent)"')"
  [ -n "$line" ]
  func="$(printf '%s' "$line" | cut -d'|' -f7)"
  deps="$(printf '%s' "$line" | cut -d'|' -f6)"
  [ "$func" == "update_pi" ]
  [[ "$deps" == *pi* ]]
}

@test "catálogo: step do pi tem tag network (faz I/O de rede)" {
  local tags
  tags="$(step_catalog | awk -F'|' '$1 == "Atualizar pi (pi-coding-agent)" {print $3}')"
  [[ "$tags" == *network* ]]
  [[ "$tags" == *update* ]]
}

# Três fases de rede (self + extensões + catálogos de 5 provedores) não cabem em
# 180s: o refresh de modelos sozinho já estoura esse orçamento em runs reais.
@test "catálogo: step do pi tem timeout p/ as três fases de rede" {
  local timeout
  timeout="$(step_catalog | awk -F'|' '$1 == "Atualizar pi (pi-coding-agent)" {print $5}')"
  [ -n "$timeout" ]
  [ "$timeout" -ge 600 ]
}

@test "catálogo: step do pi é marcado como slow (--skip slow deve cobri-lo)" {
  local tags
  tags="$(step_catalog | awk -F'|' '$1 == "Atualizar pi (pi-coding-agent)" {print $3}')"
  [[ "$tags" == *slow* ]]
}
