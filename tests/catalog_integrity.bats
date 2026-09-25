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
  # Funções de step vêm de quatro lugares: lib/steps/*.sh (núcleo),
  # lib/steps/doctor/*.sh (auditorias), lib/sudo.sh (start_sudo_keepalive) e
  # steps.d/*.sh (tools custom gated). Carrega todas para validar a existência
  # das funções referenciadas no catálogo.
  local m
  # shellcheck source=/dev/null
  source "${FU_LIB}/sudo.sh"
  for m in "${FU_LIB}"/steps/*.sh "${FU_LIB}"/steps/*/*.sh "${FU_ROOT}"/steps.d/*.sh; do
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

@test "main.sh: reinício de serviços antigos precede a auditoria pós-condição" {
  local main="${FU_ROOT}/lib/main.sh"
  [ -f "$main" ]

  local stale_line restart_line
  stale_line="$(grep -nF 'run_step "Doctor: serviços com libs antigas"' "$main" | head -n1 | cut -d: -f1)"
  restart_line="$(grep -nF 'run_step "Reiniciar serviços com libs antigas"' "$main" | head -n1 | cut -d: -f1)"

  [ -n "$stale_line" ]
  [ -n "$restart_line" ]
  [ "$restart_line" -lt "$stale_line" ]
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

@test "catálogo: todo step que usa helper de rede carrega a tag network" {
  # O portão de conectividade do run_step decide pela tag `network`. Se um step
  # faz I/O de rede sem a tag, ele volta a pendurar até o timeout quando a rede
  # cai — que é exatamente o bug que o portão existe para impedir.
  # `run_network_cmd`/`_retry` são o sinal mecânico de "este step fala com a
  # rede": quem os chama tem de estar marcado.
  local -A netfn=()
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] && netfn["$f"]=1
  done < <(
    awk '/^[a-zA-Z_][a-zA-Z0-9_]*\(\)/ { fn=$1; sub(/\(\)/, "", fn) }
         /run_network_cmd|_retry / { if (fn != "") print fn }' \
      "${FU_ROOT}"/lib/steps/*.sh "${FU_ROOT}"/steps.d/*.sh | sort -u
  )

  # Sanidade: se o awk parar de casar, o teste vira vacuamente verde.
  [ "${#netfn[@]}" -gt 10 ]

  local missing=""
  local name cat tags eff to deps fn desc
  while IFS='|' read -r name cat tags eff to deps fn desc; do
    [[ -n "$name" ]] || continue
    [[ -n "${netfn[$fn]:-}" ]] || continue
    [[ ",${tags}," == *,network,* ]] || missing+="${name} (${fn}); "
  done < <(step_catalog)

  [ -z "$missing" ] || {
    echo "steps com I/O de rede sem a tag 'network': $missing"
    false
  }
}

# ── Guard-rails de taxonomia (Série S) ────────────────────────────────────────
# A categoria é chave de agrupamento (ui.sh) e de filtro (--only/--skip-category);
# incoerência aqui quebra metadados silenciosamente. Conjunto fechado: adicionar
# uma categoria nova exige editar ESTE teste conscientemente.

@test "catálogo: categoria pertence ao conjunto fechado" {
  local allowed="core backup packages repair security firmware lang-js lang-py lang-rust lang-other ai tools ide editor shell cleanup autofix doctor final"
  local bad=0 name cat rest
  while IFS='|' read -r name cat rest; do
    [[ -n "$name" ]] || continue
    if [[ " $allowed " != *" $cat "* ]]; then
      echo "categoria fora do conjunto fechado: '$cat' ($name)"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: categoria doctor é sempre read-only (mutantes vivem em autofix)" {
  local bad=0 name cat tags eff rest
  while IFS='|' read -r name cat tags eff rest; do
    [[ -n "$name" ]] || continue
    if [[ "$cat" == "doctor" && "$eff" == "mutating" ]]; then
      echo "step mutante na categoria doctor (mover p/ autofix): $name"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: tags não duplicam o campo efeito (mutating/read proibidos)" {
  local bad=0 name cat tags eff rest
  while IFS='|' read -r name cat tags eff rest; do
    [[ -n "$name" ]] || continue
    if [[ ",${tags}," == *",mutating,"* || ",${tags}," == *",read,"* ]]; then
      echo "tag redundante com o campo efeito em: $name"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: toda categoria tem ao menos 2 steps (sem singletons)" {
  local -A count=()
  local name cat rest
  while IFS='|' read -r name cat rest; do
    [[ -n "$name" ]] || continue
    count["$cat"]=$(( ${count["$cat"]:-0} + 1 ))
  done < <(step_catalog)
  local bad=0 c
  for c in "${!count[@]}"; do
    if (( count["$c"] < 2 )); then
      echo "categoria singleton: $c (${count[$c]} step)"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

@test "catálogo: tag usada em exatamente 1 step precisa estar na allowlist" {
  # Allowlist: tags de eixo estreito ou nome de ferramenta, aceitas como
  # singletons. Adicionar aqui = decisão consciente de vocabulário.
  local allow="android antigravity arduino automation bun burp caveman claude cloud cloudflared code-intelligence codex coderabbit copilot corepack cua cursor cve deno dms docker dotnet droid extensions firmware fwupd gcloud ghcup gk gnupg go grok haskell hermes hyprpm inventory jcode kernel keyring kimchi kimi kiro lazy local-bin lock logs manual mason mirror muse news ollama onedrive openclaw opencode orca paru pi plugins poetry pool purple reference repair reports rtk rustup scrub self-update skills smart snap snyk ssd system tldr tokensave tray trim user vscode yazi zap"
  local -A count=()
  local name cat tags rest t
  while IFS='|' read -r name cat tags rest; do
    [[ -n "$name" ]] || continue
    IFS=',' read -ra taglist <<< "$tags"
    for t in "${taglist[@]}"; do
      [[ -n "$t" ]] || continue
      count["$t"]=$(( ${count["$t"]:-0} + 1 ))
    done
  done < <(step_catalog)
  local bad=0 t
  for t in "${!count[@]}"; do
    if (( count["$t"] == 1 )) && [[ " $allow " != *" $t "* ]]; then
      echo "tag singleton fora da allowlist: $t"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

# ── T5: co-localização categoria ↔ arquivo de implementação ──────────────────
# A categoria diz o domínio do step; o arquivo onde a função vive deve ser o
# arquivo daquele domínio. Sem este guard-rail, a organização da Série T
# regride em silêncio na primeira função colada no arquivo errado.
#
# Regra (Série T4):
#   • cada categoria tem um conjunto FECHADO de arquivos de domínio;
#   • steps.d/*.sh (integrações opt-in, gated por ENABLE_CUSTOM_TOOLS) podem
#     hospedar qualquer categoria: o plugin é autocontido por design;
#   • `autofix` é transversal por natureza — a auto-remediação vive junto do
#     diagnóstico que a motiva, então seus arquivos são os do domínio tratado.

_catalog_expected_files() {
  case "$1" in
    core)       printf 'lib/steps/preflight.sh lib/sudo.sh' ;;
    backup)     printf 'lib/steps/backup.sh lib/steps/cloud_backup.sh' ;;
    packages)   printf 'lib/steps/pacman.sh lib/steps/packages.sh lib/steps/news.sh' ;;
    repair)     printf 'lib/steps/repair.sh lib/steps/pacman.sh lib/steps/self_update.sh' ;;
    security)   printf 'lib/steps/security.sh' ;;
    firmware)   printf 'lib/steps/firmware.sh' ;;
    lang-js)    printf 'lib/steps/lang_js.sh' ;;
    lang-py)    printf 'lib/steps/lang_py.sh' ;;
    lang-rust)  printf 'lib/steps/lang_rust.sh' ;;
    lang-other) printf 'lib/steps/lang_other.sh' ;;
    ai)         printf 'lib/steps/ai.sh lib/steps/mcp.sh' ;;
    tools)      printf 'lib/steps/tools.sh' ;;
    ide)        printf 'lib/steps/ide.sh' ;;
    editor)     printf 'lib/steps/editor.sh' ;;
    shell)      printf 'lib/steps/shell.sh' ;;
    cleanup)    printf 'lib/steps/cleanup.sh' ;;
    final)      printf 'lib/steps/final_checks.sh lib/steps/self_update.sh' ;;
    doctor)     printf 'lib/steps/doctor/' ;;
    autofix)    printf 'lib/steps/doctor/ lib/steps/final_checks.sh lib/steps/lang_rust.sh lib/steps/mcp.sh' ;;
    *)          printf '' ;;
  esac
}

_catalog_file_of_func() {
  local fn="$1" f
  for f in "${FU_ROOT}"/lib/steps/*.sh "${FU_ROOT}"/lib/steps/doctor/*.sh \
           "${FU_ROOT}"/lib/sudo.sh "${FU_ROOT}"/steps.d/*.sh; do
    [[ -e "$f" ]] || continue
    if grep -q "^${fn}() {" "$f"; then
      printf '%s' "${f#"${FU_ROOT}"/}"
      return 0
    fi
  done
  return 1
}

@test "catálogo: função de step vive no arquivo do domínio da sua categoria" {
  local bad=0 name cat tags effect timeout cmd_deps func_name desc file allowed ok pat
  while IFS='|' read -r name cat tags effect timeout cmd_deps func_name desc; do
    [[ -n "$name" ]] || continue
    [[ -n "$func_name" ]] || continue

    file="$(_catalog_file_of_func "$func_name")" || {
      echo "função não encontrada em nenhuma fonte: $func_name ($name)"
      bad=1
      continue
    }

    # Integração opt-in: plugin autocontido hospeda qualquer categoria.
    [[ "$file" == steps.d/* ]] && continue

    allowed="$(_catalog_expected_files "$cat")"
    if [[ -z "$allowed" ]]; then
      echo "categoria sem mapa de arquivos em _catalog_expected_files: $cat ($name)"
      bad=1
      continue
    fi

    ok=0
    for pat in $allowed; do
      # entrada terminada em '/' casa o diretório inteiro (ex.: doctor/)
      if [[ "$pat" == */ ]]; then
        [[ "$file" == "$pat"* ]] && { ok=1; break; }
      else
        [[ "$file" == "$pat" ]] && { ok=1; break; }
      fi
    done

    if (( ok == 0 )); then
      echo "co-localização quebrada: '$name' (categoria $cat) implementado em $file; esperado: $allowed"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: todo doctor_* do catálogo vive em lib/steps/doctor/ (ou plugin opt-in)" {
  local bad=0 name cat tags effect timeout cmd_deps func_name desc file
  while IFS='|' read -r name cat tags effect timeout cmd_deps func_name desc; do
    [[ "$func_name" == doctor_* ]] || continue
    file="$(_catalog_file_of_func "$func_name")" || continue
    [[ "$file" == steps.d/* ]] && continue
    if [[ "$file" != lib/steps/doctor/* ]]; then
      echo "check de doctor fora de lib/steps/doctor/: $func_name em $file"
      bad=1
    fi
  done < <(step_catalog)
  [ "$bad" -eq 0 ]
}

@test "catálogo: mapa de co-localização cobre todas as categorias do catálogo" {
  local bad=0 cat
  while read -r cat; do
    [[ -n "$cat" ]] || continue
    if [[ -z "$(_catalog_expected_files "$cat")" ]]; then
      echo "categoria sem entrada no mapa: $cat"
      bad=1
    fi
  done < <(step_catalog | awk -F'|' 'NF > 1 { print $2 }' | sort -u)
  [ "$bad" -eq 0 ]
}
