#!/usr/bin/env bats
# tests/catalog_integrity.bats — invariantes do heredoc step_catalog().
# O nome do step é a chave de junção entre catálogo, main.sh e os filtros CLI;
# um catálogo malformado quebra metadados silenciosamente.

setup() {
  load "${BATS_TEST_DIRNAME}/test_helper"
  load_libs
}

@test "catálogo: toda linha tem exatamente 8 campos (7 pipes)" {
  local bad=0 line pipes
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    pipes="${line//[^|]/}"
    if [[ "${#pipes}" -ne 7 ]]; then
      echo "linha com ${#pipes} pipes (esperado 7): $line"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: timeout é inteiro não-negativo" {
  local bad=0 name category tags effect timeout rest
  while IFS='|' read -r name category tags effect timeout rest; do
    [[ -n "$name" ]] || continue
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
      echo "timeout inválido '$timeout' em: $name"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: efeito é 'read' ou 'mutating'" {
  local bad=0 name category tags effect rest
  while IFS='|' read -r name category tags effect rest; do
    [[ -n "$name" ]] || continue
    if [[ "$effect" != "read" && "$effect" != "mutating" ]]; then
      echo "efeito inválido '$effect' em: $name"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: nomes de step são únicos (chave de junção)" {
  local dups
  dups="$(step_catalog | cut -d'|' -f1 | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' | sort | uniq -d)"
  if [[ -n "$dups" ]]; then
    echo "nomes duplicados:"
    echo "$dups"
  fi
  [ -z "$dups" ]
}

@test "catálogo: todo func_name referenciado existe em alguma fonte" {
  # Funções de step vêm de três lugares: lib/steps/*.sh (núcleo),
  # lib/sudo.sh (start_sudo_keepalive) e steps.d/*.sh (tools custom gated).
  # Carrega todas para validar a existência das funções referenciadas no catálogo.
  local m
  # shellcheck source=/dev/null
  source "${FU_LIB}/sudo.sh"
  for m in "${FU_LIB}"/steps/*.sh "${FU_ROOT}"/steps.d/*.sh; do
    [[ -e "$m" ]] || continue
    # shellcheck source=/dev/null
    source "$m"
  done

  local bad=0 name category tags effect timeout cmd_deps func_name desc
  while IFS='|' read -r name category tags effect timeout cmd_deps func_name desc; do
    [[ -n "$name" ]] || continue
    [[ -n "$func_name" ]] || continue   # func_name vazio é permitido
    if ! declare -F "$func_name" >/dev/null 2>&1; then
      echo "func ausente '$func_name' para o step: $name"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: cada cmd_dep parece um nome de comando plausível" {
  local bad=0 name category tags effect timeout cmd_deps rest dep
  while IFS='|' read -r name category tags effect timeout cmd_deps rest; do
    [[ -n "$name" ]] || continue
    [[ -n "$cmd_deps" ]] || continue
    IFS=',' read -ra _deps <<< "$cmd_deps"
    for dep in "${_deps[@]}"; do
      dep="${dep//[[:space:]]/}"
      [[ -z "$dep" ]] && continue
      if ! [[ "$dep" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        echo "cmd_dep suspeito '$dep' em: $name"
        bad=1
      fi
    done
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}
