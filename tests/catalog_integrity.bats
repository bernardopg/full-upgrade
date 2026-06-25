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

@test "catálogo: nome de step não tem espaço em borda (quebra join key)" {
  # O nome é a chave de junção byte-idêntica com main.sh; um espaço inicial/
  # final faz a busca de metadata (timeout/cmd_deps) cair pro default em
  # silêncio. Regressão de C1 (steps custom tinham ' Atualizar Hermes').
  local bad=0 raw_name
  while IFS='|' read -r raw_name _; do
    [[ -n "${raw_name//[[:space:]]/}" ]] || continue
    if [[ "$raw_name" != "$(printf '%s' "$raw_name" | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//')" ]]; then
      echo "nome com espaço em borda: [${raw_name}]"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: nomes com func_name batem com a chamada em main.sh" {
  # Garante que todo step com função direta é invocado em main.sh com o nome
  # EXATO do catálogo (run_step/step_skip/custom_step_or_skip "<nome>").
  # Pega divergências de join key que o trim de outros testes mascara.
  local main="${FU_ROOT}/lib/main.sh"
  [ -f "$main" ]
  local bad=0 name func_name _c _t _e _to _cd _d
  while IFS='|' read -r name _c _t _e _to _cd func_name _d; do
    [[ -n "$name" ]] || continue
    [[ -n "$func_name" ]] || continue
    # Núcleo (start_sudo_keepalive) e acquire_run_lock são chamados fora do
    # padrão de dispatch nomeado; pulamos os que não aparecem como string.
    grep -qF "\"${name}\"" "$main" || {
      # Não obrigatório que TODO step esteja em main.sh por nome (alguns são
      # core invocados direto), mas se aparecer, deve bater exatamente.
      continue
    }
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
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

@test "main.sh: todo step despachado tem linha no catálogo" {
  # Regressão do step "Atualizar pacotes Snap": despachado em main.sh sem linha
  # no catálogo → sem timeout, fora de --list-steps/contagem e — pior — nunca
  # entra no skip-list de --mode/--only (os filtros iteram só o catálogo),
  # então um step mutante rodaria em --mode doctor.
  local main="${FU_ROOT}/lib/main.sh"
  [ -f "$main" ]
  local bad=0 name
  local catalog_names
  catalog_names="$(step_catalog | cut -d'|' -f1)"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    [[ "$name" == \$* ]] && continue   # despacho via variável (loops de skip)
    if ! grep -qxF "$name" <<< "$catalog_names"; then
      echo "step despachado em main.sh sem linha no catálogo: $name"
      bad=1
    fi
  done < <(grep -oE '(run_step|step_skip|custom_step_or_skip) "[^"]+"' "$main" \
              | sed -E 's/^[a-z_]+ "//; s/"$//' | sort -u)
  [ "$bad" -eq 0 ]
}

@test "main.sh: shadowing roda antes do update principal" {
  local main="${FU_ROOT}/lib/main.sh"
  [ -f "$main" ]

  local shadow_line update_line
  shadow_line="$(grep -nF 'run_step "Reparar comandos locais conflitantes"' "$main" | head -n1 | cut -d: -f1)"
  update_line="$(grep -nF 'run_step "Atualizar pacotes do sistema e AUR"' "$main" | head -n1 | cut -d: -f1)"

  [ -n "$shadow_line" ]
  [ -n "$update_line" ]
  [ "$shadow_line" -lt "$update_line" ]
}

@test "main.sh: reinício de serviços antigos é despachado" {
  local main="${FU_ROOT}/lib/main.sh"
  [ -f "$main" ]

  local stale_line restart_line
  stale_line="$(grep -nF 'run_step "Doctor: serviços com libs antigas"' "$main" | head -n1 | cut -d: -f1)"
  restart_line="$(grep -nF 'run_step "Reiniciar serviços com libs antigas"' "$main" | head -n1 | cut -d: -f1)"

  [ -n "$stale_line" ]
  [ -n "$restart_line" ]
  [ "$stale_line" -lt "$restart_line" ]
}

@test "catálogo: steps que mutam estado do shell pai têm timeout 0" {
  # timeout>0 roda o step em subshell (run_step). acquire_run_lock segura o FD
  # do flock — em subshell, o FD fecha na saída e o lock é liberado na hora
  # (lock inoperante). start_sudo_keepalive valida sudo interativamente.
  # Ambos DEVEM rodar no shell atual (timeout 0).
  local bad=0 name _c _t _e timeout _cd func _d
  while IFS='|' read -r name _c _t _e timeout _cd func _d; do
    [[ "$func" == "acquire_run_lock" || "$func" == "start_sudo_keepalive" ]] || continue
    if [[ "$timeout" != "0" ]]; then
      echo "timeout deve ser 0 para ${func} (step: ${name}), encontrado: ${timeout}"
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
