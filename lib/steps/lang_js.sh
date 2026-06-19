#!/usr/bin/env bash
# steps/lang_js.sh — npm, pnpm, corepack
# Sourced por full-upgrade.sh. Não executar direto.
# shellcheck shell=bash

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
  printf '%s\n' "$output" | grep -v '^npm warn\|^added\|^changed\|^up to date' || true
  return "$rc"
}


update_npm_globals() {
  local outdated prefix_rc
  local -a pkg_specs=()
  local -a failed=()
  local -a skipped=()
  local -a linked_pkgs=()

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
    npm outdated -g --depth=0 2>/dev/null | tee >(_strip_ansi >> "$LOG_FILE") || true
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

    if printf '%s\n' "${linked_pkgs[@]}" | grep -qx "$pkg"; then
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
    if run_logged npm install -g "$spec"; then
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
    (( ${#failed[@]} == 0 )) && return "$RC_TODO"
  fi

  if (( ${#failed[@]} > 0 )); then
    log "  Falha final em pacote(s) npm: ${failed[*]}"
    return 1
  fi

  (( prefix_rc == RC_WARN )) && return "$RC_WARN"
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
  printf '%s\n' "$output" | grep -v '^npm warn\|^added\|^changed\|^up to date' || true
  return "$rc"
}


update_pnpm_self() {
  local installed latest output rc
  installed="$(pnpm --version 2>/dev/null || true)"
  latest="$(npm view pnpm version 2>/dev/null || true)"

  if [[ -z "$latest" ]]; then
    log "  pnpm: não foi possível verificar versão mais recente."
    return 0
  fi

  output="$(pnpm self-update 2>&1)"
  rc=$?
  log_raw "$output"

  # "newer than latest" = pnpm à frente do registry — não é falha
  if printf '%s\n' "$output" | grep -q 'newer than'; then
    log "  pnpm ${installed} (à frente do registry latest=${latest}) — ok."
    return 0
  fi

  if ! version_is_outdated "$installed" "$latest"; then
    log "  pnpm ${installed} já na versão mais recente."
    return 0
  fi

  printf '%s\n' "$output" | grep -v '^$' || true
  return "$rc"
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
    || true
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
  if printf '%s\n' "$output" | grep -qiE "already on the latest|congrats|you're on the latest"; then
    log "  bun já na versão mais recente."
    return 0
  fi
  printf '%s\n' "$output" | grep -v '^$' | tail -5 || true
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
  output="$(deno upgrade 2>&1)"
  rc=$?
  log_raw "$output"
  if printf '%s\n' "$output" | grep -qiE "already.*latest|is the most recent|up to date"; then
    log "  deno já na versão mais recente."
    return 0
  fi
  printf '%s\n' "$output" | grep -v '^$' | tail -5 || true
  return "$rc"
}


