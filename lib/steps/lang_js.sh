#!/usr/bin/env bash
# steps/lang_js.sh — npm, pnpm, corepack
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash
# shellcheck disable=SC2034  # STEP_REASON é global cross-module (lida em core.sh)

npm_global_prefix() {
  npm config get prefix 2>/dev/null || true
}


npm_global_root() {
  npm root -g 2>/dev/null || true
}

# Verifica se prefixo npm global é seguro para update.
# Prefixo em /usr ou /usr/local = risco de conflito com pacman → RC_WARN.
# Prefixo em / = recusa (RC_FAIL).
# Retorna 0 se prefixo estiver em $HOME ou outro caminho de usuário.

npm_audit_prefix() {
  local prefix
  prefix="$(npm_global_prefix)"
  if [[ -z "$prefix" ]]; then
    log "  npm: prefixo global não detectado."
    return 0
  fi
  log "  npm: prefixo global = ${prefix}"
  case "$prefix" in
    /)
      log "  npm: prefixo global é / — risco crítico de sobrescrever sistema. Abortando update npm global."
      return 1
      ;;
    /usr|/usr/local)
      log "  npm: prefixo global em ${prefix} — pode conflitar com pacotes do pacman."
      remediation "npm config set prefix ~/.local"
      return "$RC_WARN"
      ;;
    "$HOME"*|/home/*)
      return 0
      ;;
    *)
      log "  npm: prefixo global em caminho incomum (${prefix}) — verifique se é intencional."
      return "$RC_WARN"
      ;;
  esac
}


# True (0) se o diretório de instalação global do npm é gravável pelo usuário.
# Um prefixo root-owned (ex.: /usr, do pacote npm do pacman) NÃO é gravável sem
# root: ali o npm é gerenciado pelo sistema e `npm install -g` falha com EACCES.
# Nesses casos os steps de npm devem PULAR (atualiza-se via pacman), não falhar.
# (Foi exatamente a causa de um fail quando o full-upgrade rodou num ambiente
# sem NPM_CONFIG_PREFIX, caindo no npm do pacman em /usr.)
npm_global_writable() {
  local prefix nm
  prefix="$(npm_global_prefix)"
  [[ -n "$prefix" ]] || return 0   # desconhecido: não bloqueia, deixa o npm decidir
  nm="${prefix}/lib/node_modules"
  [[ -d "$nm" ]] || nm="$prefix"
  [[ -w "$nm" ]]
}


# Extrai pacotes citados por `npm warn allow-scripts` ou `npm warn
# install-scripts`, quando o npm bloqueia scripts de install (ex.: native
# addons como better-sqlite3). O npm ≥12 emite `install-scripts`; o parser
# aceita ambos para não regredir se o formato mudar de volta. Lê stdin e emite
# um nome por linha, sem versão. Puro/testável.
npm_allow_scripts_packages() {
  awk '
    $1 == "npm" && $2 == "warn" && ($3 == "allow-scripts" || $3 == "install-scripts") && $4 ~ /^(@[^[:space:]@]+\/)?[^[:space:]@]+@[0-9]/ {
      pkg = $4
      sub(/@[0-9].*$/, "", pkg)
      if (pkg != "") print pkg
    }
  ' | sort -u
}


cleanup_npm_global_tree() {
  local prefix root
  prefix="$(npm_global_prefix)"
  root="$(npm_global_root)"

  local -a scan_paths=()
  [[ -n "$root" && -d "$root" ]] && scan_paths+=("$root")
  [[ -n "$prefix" && -d "$prefix/bin" ]] && scan_paths+=("$prefix/bin")
  [[ -n "$prefix" && -d "$prefix/share" ]] && scan_paths+=("$prefix/share")

  if (( ${#scan_paths[@]} == 0 )); then
    log "  Prefixo global do npm não encontrado para saneamento."
    return 0
  fi

  local -a links=()
  local link target abs_target
  local removed=0

  mapfile -t links < <(find "${scan_paths[@]}" -type l -print 2>/dev/null | sort -u)

  for link in "${links[@]}"; do
    [[ -n "$link" ]] || continue
    target="$(readlink "$link" 2>/dev/null || true)"
    abs_target="$(readlink -f "$link" 2>/dev/null || true)"

    if [[ -z "$abs_target" || ! -e "$abs_target" || "$target" == *".npm/_cacache/tmp/"* || "$abs_target" == *"/.npm/_cacache/tmp/"* ]]; then
      log "  Removendo link global invalido do npm: $link -> ${target:-<sem-target>}"
      rm -f -- "$link" || return 1
      ((removed++))
    fi
  done

  if (( removed == 0 )); then
    log "  Sem links invalidos no prefixo global do npm."
  else
    log "  Links invalidos removidos do prefixo global do npm: $removed"
  fi

  return 0
}


npm_manifest_has_local_file_deps() {
  local spec="$1"
  local meta

  # Checar apenas dependencies e optionalDependencies — devDependencies não são
  # instaladas em `npm install -g` e podem ter file:../ legítimos de monorepo.
  meta="$(npm view "$spec" dependencies optionalDependencies --json 2>/dev/null || true)"
  [[ -n "${meta//[[:space:]]/}" ]] || return 1

  # Skippar apenas file: com path absoluto (/...) — esses referenciam o sistema
  # local do publicador e falhariam na instalação. file:./vendor/ são vendored
  # dentro do tarball e são seguros.
  printf '%s' "$meta" | python -c '
import json, sys

def is_problematic_file_dep(value):
    if not isinstance(value, str):
        return False
    if not value.startswith("file:"):
        return False
    path = value[len("file:"):]
    return path.startswith("/")

def has_problematic_file_dep(node):
    if isinstance(node, dict):
        for value in node.values():
            if is_problematic_file_dep(value):
                return True
            if has_problematic_file_dep(value):
                return True
    elif isinstance(node, list):
        for value in node:
            if has_problematic_file_dep(value):
                return True
    return False

try:
    data = json.load(sys.stdin)
except Exception:
    raise SystemExit(1)

raise SystemExit(0 if has_problematic_file_dep(data) else 1)
'
}


npm_clean_reinstall_global_package() {
  local pkg="$1"
  local spec="$2"

  log "  Tentando reinstalacao limpa de ${pkg}..."
  run_logged npm uninstall -g "$pkg" || true
  cleanup_npm_global_tree || true
  run_logged npm cache verify || true
  run_logged npm install -g "$spec"
}


npm_get_linked_packages() {
  npm list -g --depth=0 --json 2>/dev/null | python -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
deps = data.get("dependencies", {})
for name, info in deps.items():
    resolved = info.get("resolved", "")
    if resolved.startswith("file:") or info.get("link"):
        print(name)
'
}


update_npm_self() {
  local installed latest output rc
  installed="$(npm --version 2>/dev/null || true)"
  latest="$(npm view npm version 2>/dev/null || true)"
  if [[ -z "$latest" ]]; then
    log "  npm: não foi possível verificar versão mais recente."
    return 0
  fi
  if ! version_is_outdated "$installed" "$latest"; then
    log "  npm ${installed} já na versão mais recente."
    return 0
  fi
  if ! npm_global_writable; then
    log "  npm global em $(npm_global_prefix) é gerenciado pelo sistema (root/pacman); pulando self-update — atualize via 'sudo pacman -Syu'."
    return 0
  fi
  log "  npm: ${installed} → ${latest}"
  output="$(npm install -g "npm@${latest}" 2>&1)"
  rc=$?
  log_raw "$output"
  printf '%s\n' "$output" | grep -v '^npm warn\|^added\|^changed\|^up to date' | log_out || true
  return "$rc"
}


update_npm_globals() {
  local outdated prefix_rc
  local -a pkg_specs=()
  local -a failed=()
  local -a skipped=()
  local -a linked_pkgs=()
  local -a script_blocked=()
  local todo_rc=0

  npm_audit_prefix
  prefix_rc=$?
  if (( prefix_rc == 1 )); then
    return 1
  fi

  if ! npm_global_writable; then
    log "  npm global em $(npm_global_prefix) é gerenciado pelo sistema (root/pacman); pulando updates globais — atualize via 'sudo pacman -Syu'."
    return 0
  fi

  outdated="$(npm outdated -g --depth=0 --json 2>/dev/null || true)"
  if [[ -n "${outdated//[[:space:]]/}" && "$outdated" != "{}" ]]; then
    log "  Pacotes npm globais desatualizados:"
    npm outdated -g --depth=0 2>/dev/null | log_stream || true
  else
    log "  Sem pacotes npm globais pendentes."
    (( prefix_rc == RC_WARN )) && return "$RC_WARN"
    return 0
  fi

  cleanup_npm_global_tree || return 1

  mapfile -t linked_pkgs < <(npm_get_linked_packages)

  mapfile -t pkg_specs < <(
    printf '%s' "$outdated" | python -c '
import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
for name in sorted(data.keys()):
    latest = data.get(name, {}).get("latest") or "latest"
    print(f"{name}\t{latest}")
'
  )

  if (( ${#pkg_specs[@]} == 0 )); then
    log "  Não foi possivel extrair lista de pacotes desatualizados do npm."
    return 1
  fi

  local entry pkg latest spec
  for entry in "${pkg_specs[@]}"; do
    IFS=$'\t' read -r pkg latest <<<"$entry"
    [[ -n "$pkg" ]] || continue

    if array_contains "$pkg" "${linked_pkgs[@]}"; then
      log "  Pulando pacote instalado localmente via link: ${pkg} (gerencie manualmente)"
      skipped+=("$pkg")
      continue
    fi

    spec="${pkg}@${latest:-latest}"

    if npm_manifest_has_local_file_deps "$spec"; then
      log "  Pulando pacote npm com dependencia local no registry (file:): ${spec}"
      skipped+=("$pkg")
      continue
    fi

    log "  Atualizando npm global: ${spec}"
    local _npm_out _npm_rc
    _npm_out="$(npm install -g "$spec" 2>&1)"
    _npm_rc=$?
    log_raw "$_npm_out"
    printf '%s\n' "$_npm_out" | grep -v '^$' | log_out || true
    local -a _blocked=()
    mapfile -t _blocked < <(printf '%s\n' "$_npm_out" | npm_allow_scripts_packages)
    (( ${#_blocked[@]} == 0 )) || script_blocked+=("${_blocked[@]}")
    if (( _npm_rc == 0 )); then
      continue
    fi

    if ! npm_clean_reinstall_global_package "$pkg" "$spec"; then
      failed+=("$pkg")
    fi
  done

  cleanup_npm_global_tree || true

  if (( ${#skipped[@]} > 0 )); then
    log "  Pacotes npm linkados (requerem atualização manual): ${skipped[*]}"
    remediation "npm install -g <pkg>@latest  # ou gerencie via workspace"
    todo_rc="$RC_TODO"
    STEP_REASON="${#skipped[@]} pacote(s) linkado(s) + ${#script_blocked[@]} com script bloqueado"
  fi

  if (( ${#script_blocked[@]} > 0 )); then
    log "  npm bloqueou script(s) de install em: ${script_blocked[*]}"
    remediation "npm install -g --allow-scripts=<pkg> <pkg>@latest  # revise antes; executa scripts do pacote"
    todo_rc="$RC_TODO"
    STEP_REASON="${#skipped[@]} pacote(s) linkado(s) + ${#script_blocked[@]} com script bloqueado"
  fi

  if (( ${#failed[@]} > 0 )); then
    log "  Falha final em pacote(s) npm: ${failed[*]}"
    return 1
  fi

  (( todo_rc == RC_TODO )) && return "$RC_TODO"
  (( prefix_rc == RC_WARN )) && return "$RC_WARN"
  return 0
}

# H6 — atualiza pacotes npm globais de um prefixo SECUNDÁRIO. O 'npm outdated
# -g' do step anterior só enxerga o prefixo do npm ATIVO (ex.: node do nvm);
# instalações em ~/.npm-global — o prefixo clássico de NPM_CONFIG_PREFIX, comum
# para CLIs de IA (kimi, cline, gemini, codex, qwen, 9router…) — ficavam sem
# via de update e derivavam para sempre (o 'Atualizar Kimi CLI' foi o primeiro
# caso coberto; este step generaliza). Varre esse prefixo com 'npm outdated -g
# --prefix' e atualiza cada pacote com 'npm install -g --prefix'. Sem os
# safeguards de links/file: do prefixo ativo: installs ali são installs
# normais do usuário (sem links de monorepo); scripts bloqueados pelo
# allowScripts seguem reportados como RC_TODO com remediação, igual ao step do
# prefixo ativo.
update_npm_globals_secondary() {
  local sec="${NPM_CONFIG_PREFIX:-$HOME/.npm-global}"
  if [[ ! -d "${sec}/lib/node_modules" ]]; then
    log "  Prefixo secundário ${sec} não encontrado; nada a fazer."
    return 0
  fi
  local primary
  primary="$(npm_global_prefix)"
  if [[ -n "$primary" && "$sec" == "$primary" ]]; then
    log "  ${sec} é o prefixo global ativo; já coberto por 'Atualizar npm global'."
    return 0
  fi
  if ! [[ -w "${sec}/lib/node_modules" ]]; then
    log "  Prefixo secundário ${sec} não é gravável pelo usuário; pulando."
    return 0
  fi

  local outdated
  outdated="$(npm outdated -g --prefix "$sec" --depth=0 --json 2>/dev/null || true)"
  if [[ -z "${outdated//[[:space:]]/}" || "$outdated" == "{}" ]]; then
    log "  Sem pacotes npm globais pendentes em ${sec}."
    return 0
  fi
  log "  Pacotes npm globais desatualizados em ${sec}:"
  npm outdated -g --prefix "$sec" --depth=0 2>/dev/null | log_stream || true

  local -a pkg_specs=() failed=() script_blocked=() _blocked=()
  mapfile -t pkg_specs < <(
    printf '%s' "$outdated" | python -c '
import json,sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
for name in sorted(data.keys()):
    latest = data.get(name, {}).get("latest") or "latest"
    print(f"{name}\t{latest}")
'
  )
  if (( ${#pkg_specs[@]} == 0 )); then
    log "  Não foi possível extrair a lista de pacotes desatualizados de ${sec}."
    return 1
  fi

  local entry pkg latest spec out rc
  for entry in "${pkg_specs[@]}"; do
    IFS=$'\t' read -r pkg latest <<<"$entry"
    [[ -n "$pkg" ]] || continue
    spec="${pkg}@${latest:-latest}"
    log "  Atualizando npm global [${sec}]: ${spec}"
    out="$(npm install -g --prefix "$sec" "$spec" 2>&1)"
    rc=$?
    log_raw "$out"
    printf '%s\n' "$out" | grep -v '^$' | log_out || true
    mapfile -t _blocked < <(printf '%s\n' "$out" | npm_allow_scripts_packages)
    (( ${#_blocked[@]} == 0 )) || script_blocked+=("${_blocked[@]}")
    (( rc == 0 )) || failed+=("$pkg")
  done

  if (( ${#failed[@]} > 0 )); then
    log "  Falha final em pacote(s) npm [${sec}]: ${failed[*]}"
    STEP_REASON="falha ao atualizar ${#failed[@]} pacote(s) em ${sec}"
    return 1
  fi
  if (( ${#script_blocked[@]} > 0 )); then
    log "  npm bloqueou script(s) de install em: ${script_blocked[*]}"
    remediation "npm config set allow-scripts <pkg> --location=user  # depois reinstale: npm install -g --prefix ${sec} <pkg>@latest"
    STEP_REASON="${#script_blocked[@]} pacote(s) com script de install bloqueado em ${sec}"
    return "$RC_TODO"
  fi
  log "  Prefixo secundário ${sec} atualizado."
  return 0
}


update_corepack() {
  local installed latest output rc
  installed="$(corepack --version 2>/dev/null || true)"
  latest="$(npm view corepack version 2>/dev/null || true)"
  if [[ -z "$latest" ]]; then
    log "  corepack: não foi possível verificar versão mais recente."
    return 0
  fi
  if ! version_is_outdated "$installed" "$latest"; then
    log "  corepack ${installed} já na versão mais recente."
    return 0
  fi
  if ! npm_global_writable; then
    log "  corepack: npm global em $(npm_global_prefix) é gerenciado pelo sistema (root/pacman); pulando — atualize via 'sudo pacman -Syu'."
    return 0
  fi
  log "  corepack: ${installed} → ${latest}"
  output="$(npm install -g "corepack@${latest}" 2>&1)"
  rc=$?
  log_raw "$output"
  printf '%s\n' "$output" | grep -v '^npm warn\|^added\|^changed\|^up to date' | log_out || true
  return "$rc"
}


pnpm_global_project_dir() {
  pnpm list -g --depth 0 --json 2>/dev/null | python3 -c '
import json, os, sys
try:
    data = json.load(sys.stdin)
    if isinstance(data, list):
        data = data[0] if data else {}
    path = data.get("dependencies", {}).get("pnpm", {}).get("path", "")
    if path.endswith("/node_modules/pnpm"):
        print(path[:-len("/node_modules/pnpm")])
except Exception:
    pass
'
}

update_pnpm_self() {
  local installed latest output rc fallback fallback_rc current global_project
  installed="$(pnpm --version 2>/dev/null || true)"
  latest="$(npm view pnpm version 2>/dev/null || true)"

  if [[ -z "$latest" ]]; then
    log "  pnpm: não foi possível verificar versão mais recente."
    return 0
  fi

  # Não invoque o self-updater quando já está atual. Além de poupar rede, isso
  # evita reabrir um pnpm-lock.yaml de ambiente antigo que só é necessário em
  # uma troca real de versão.
  if ! version_is_outdated "$installed" "$latest"; then
    log "  pnpm ${installed} já na versão mais recente."
    return 0
  fi

  output="$(pnpm self-update 2>&1)"
  rc=$?
  log_raw "$output"

  # pnpm gerenciado pelo corepack: o próprio pnpm recusa o self-update
  # (ERR_PNPM_CANT_SELF_UPDATE_IN_COREPACK). Não é falha do run — é uma
  # configuração legítima (corepack é o caminho oficial de versionar pnpm por
  # projeto) — mas a versão default global ainda é atualizável por aqui: a
  # forma oficial é 'corepack install -g pnpm@X' (corepack moderno; o 'corepack
  # use' NÃO serve — reescreve o package.json do cwd). Fallback 'prepare
  # --activate' cobre corepacks antigos. Best-effort: se o corepack não
  # entregar, segue pendência manual com a remediação certa em vez de fail duro.
  if grep -q 'ERR_PNPM_CANT_SELF_UPDATE_IN_COREPACK' <<<"$output"; then
    log "  pnpm ${installed} é gerenciado pelo corepack; self-update não se aplica."
    local cp_out cp_rc
    if has corepack; then
      cp_out="$(corepack install -g "pnpm@${latest}" 2>&1)"
      cp_rc=$?
      if (( cp_rc != 0 )); then
        cp_out="${cp_out}"$'\n'"$(corepack prepare "pnpm@${latest}" --activate 2>&1)"
        cp_rc=$?
      fi
      log_raw "$cp_out"
      hash -r 2>/dev/null || true
      current="$(pnpm --version 2>/dev/null || true)"
      if (( cp_rc == 0 )) && [[ -n "$current" ]] && ! version_is_outdated "$current" "$latest"; then
        log "  pnpm atualizado via corepack: ${installed} → ${current}."
        return 0
      fi
      log "  Aviso: corepack não ativou o pnpm ${latest}; ficou como pendência manual."
    fi
    remediation "atualize o pnpm default do corepack: corepack install -g pnpm@latest"
    STEP_REASON="pnpm gerenciado pelo corepack (${installed} → ${latest}); atualize via corepack"
    return "$RC_TODO"
  fi

  # "newer than latest" = pnpm à frente do registry — não é falha
  if grep -q 'newer than' <<<"$output"; then
    log "  pnpm ${installed} (à frente do registry latest=${latest}) — ok."
    return 0
  fi

  hash -r 2>/dev/null || true
  current="$(pnpm --version 2>/dev/null || true)"
  if (( rc == 0 )) && [[ -n "$current" ]] && ! version_is_outdated "$current" "$latest"; then
    log "  pnpm atualizado: ${installed} → ${current}."
    return 0
  fi

  # O self-updater do pnpm 11 pode falhar ao converter seu lockfile de ambiente
  # quando um snapshot com peers (ex.: fdir(...)) não tem a mesma chave em
  # packages. O próprio pnpm bloqueia instalar pnpm com `pnpm add -g`; portanto
  # atualizamos somente o projeto global que já contém o CLI usando npm. O shim
  # existente continua apontando para node_modules/pnpm/bin/pnpm.mjs.
  global_project="$(pnpm_global_project_dir)"
  if [[ -z "$global_project" || ! -d "$global_project" ]]; then
    log "  pnpm self-update falhou e o projeto global ativo não pôde ser localizado."
    printf '%s\n' "$output" | grep -v '^$' | tail -20 | log_out || true
    return "$rc"
  fi
  log "  pnpm self-update falhou (rc=${rc}); atualizando o projeto global via npm para pnpm@${latest}..."
  fallback="$(npm install --prefix "$global_project" --save-exact --no-package-lock --ignore-scripts "pnpm@${latest}" 2>&1)"
  fallback_rc=$?
  log_raw "$fallback"
  hash -r 2>/dev/null || true
  current="$(pnpm --version 2>/dev/null || true)"
  if (( fallback_rc == 0 )) && [[ -n "$current" ]] && ! version_is_outdated "$current" "$latest"; then
    log "  pnpm recuperado pelo fallback global: ${installed} → ${current}."
    return 0
  fi

  printf '%s\n' "$output" | grep -v '^$' | tail -20 | log_out || true
  printf '%s\n' "$fallback" | grep -v '^$' | tail -20 | log_out || true
  local _both="${output}"$'\n'"${fallback}"
  if grep -qiE "$NETWORK_TRANSIENT_RE" <<<"$_both"; then
    return "$RC_WARN"
  fi
  (( fallback_rc != 0 )) && return "$fallback_rc"
  return 1
}


update_pnpm_globals() {
  local output rc filedeps pkg

  filedeps="$(pnpm list -g --json 2>/dev/null | python -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
deps = data.get("dependencies", {})
for name, info in deps.items():
    resolved = info.get("resolved", "")
    if resolved.startswith("file:") or info.get("link"):
        print(name)
' 2>/dev/null || true)"

  if [[ -n "${filedeps//[[:space:]]/}" ]]; then
    while IFS= read -r pkg; do
      [[ -n "$pkg" ]] || continue
      log "  Removendo dep local inválida do pnpm global: ${pkg} (file:)"
      run_logged pnpm rm -g "$pkg" || true
    done <<<"$filedeps"
  fi

  output="$(_retry 2 pnpm -g update 2>&1)"
  rc=$?
  log_raw "$output"

  if (( rc == RC_WARN )); then
    log "  pnpm global: falha de rede transitória após 2 tentativas."
    return "$RC_WARN"
  fi

  if (( rc != 0 )); then
    if grep -q 'ERR_PNPM_NO_IMPORTER_MANIFEST_FOUND\|No global packages found' <<<"$output"; then
      log "  pnpm global sem pacotes."
      return 0
    fi
    if grep -q 'ENOENT.*package\.json' <<<"$output"; then
      log "  pnpm global: package.json não encontrado em dep local. Diagnóstico: pnpm list -g"
      remediation "pnpm list -g"
      return 1
    fi
    return "$rc"
  fi

  # Mostrar só linhas relevantes (não "Done in Xms" nem "No global packages found")
  printf '%s\n' "$output" \
    | grep -v -E '^(Done in|No global packages found)' \
    | grep -v '^$' \
    | log_out || true
  return 0
}


# Atualiza o runtime Bun via `bun upgrade` (auto-gerenciado em ~/.bun). Só roda
# se o binário for gravável — uma instalação via pacman (/usr/bin, read-only) é
# atualizada pelo gerenciador de pacotes, então pula com aviso em vez de falhar.
update_bun() {
  local bun_bin output rc
  bun_bin="$(command -v bun 2>/dev/null || true)"
  [[ -n "$bun_bin" ]] || { log "  bun não encontrado."; return 0; }

  if [[ ! -w "$bun_bin" ]]; then
    log "  bun em ${bun_bin} não é gravável (gerenciado pelo sistema/pacman); pulando — atualize via 'sudo pacman -Syu'."
    return 0
  fi

  log "  bun atual: $(bun --version 2>/dev/null || echo '?')"
  output="$(bun upgrade 2>&1)"
  rc=$?
  log_raw "$output"
  if grep -qiE "already on the latest|congrats|you're on the latest" <<<"$output"; then
    log "  bun já na versão mais recente."
    return 0
  fi
  printf '%s\n' "$output" | grep -v '^$' | tail -5 | log_out || true
  return "$rc"
}


# Atualiza o runtime Deno via `deno upgrade` (auto-gerenciado). Instalação via
# pacman (/usr/bin, read-only) é atualizada pelo gerenciador de pacotes → pula.
update_deno() {
  local deno_bin output rc
  deno_bin="$(command -v deno 2>/dev/null || true)"
  [[ -n "$deno_bin" ]] || { log "  deno não encontrado."; return 0; }

  if [[ ! -w "$deno_bin" ]]; then
    log "  deno em ${deno_bin} não é gravável (gerenciado pelo sistema/pacman); pulando — atualize via 'sudo pacman -Syu'."
    return 0
  fi

  log "  deno atual: $(deno --version 2>/dev/null | awk 'NR==1{print $2}' || echo '?')"
  output="$(_retry 2 deno upgrade 2>&1)"
  rc=$?
  log_raw "$output"
  if grep -qiE "already.*latest|is the most recent|up to date" <<<"$output"; then
    log "  deno já na versão mais recente."
    return 0
  fi
  printf '%s\n' "$output" | grep -v '^$' | tail -5 | log_out || true
  return "$rc"
}
