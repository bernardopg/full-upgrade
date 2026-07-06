---
name: upgrade-step-integrator
description: Conhecimento de referência para integrar um tool (curl|sh, wget, self-download, updater nativo) como step do full-upgrade — contrato RC, catálogo, wiring em main.sh, teste bats, validação CI. Use ao implementar/integrar um novo step de atualização neste projeto, ou junto do agente upgrade-step-integrator. Complementa CLAUDE.md e .mind/plan.md com os padrões de código concretos.
---

# Integrar um step de atualização no full-upgrade

Referência de padrões. O **contrato de "pronto"** vive em `.mind/plan.md`; a **arquitetura** em `CLAUDE.md`. Aqui: os moldes de código.

## Anatomia de um step self-update (molde base)

Copie de `update_droid`/`update_kiro_cli` (self-update nativo) ou `update_snyk` (binário baixado + sha256).

```bash
# lib/steps/<domínio>.sh  OU  steps.d/NN-<nome>.sh
update_<tool>() {
    local bin="${<TOOL>_BIN:-$(command -v <tool> 2>/dev/null || true)}"
    if [[ -z "$bin" || ! -x "$bin" ]]; then
        log "  <tool> não encontrado (defina <TOOL>_BIN no config)."
        return 0                      # ausência = ok silencioso; catálogo já skipa via cmd_deps
    fi

    # Preferir check-only antes de aplicar, quando o tool oferecer:
    if "$bin" check-update --json 2>/dev/null | grep -q '"outdated":true'; then
        local output rc
        output="$(run_network_cmd "$bin" update --apply 2>&1)"; rc=$?
        log_raw "$output"
        printf '%s\n' "$output" | grep -v '^$' || true
        [[ $rc -ne 0 ]] && return "$RC_WARN"   # falha de update remoto → warn, não fail
        return 0
    fi
    log "  <tool> já na versão mais recente."
    return 0
}
```

Regras que o molde encapsula:
- Ausência do binário → `return 0` (o catálogo `cmd_deps` já produz o skip visível).
- Rede/updater falhou → `RC_WARN` (transitório). Só use fail para erro determinístico do próprio tool.
- `run_network_cmd`/`_retry` convertem erro de DNS/conectividade em `RC_WARN` automaticamente.
- Binário baixado de URL própria → validar sha256 (ver `update_snyk`); trust boundary não se simplifica.

## Linha de catálogo (`lib/catalog.sh`)

```
Atualizar <Tool>|<categoria>|<tags,vírgula>|<efeito>|<timeout>|<cmd_deps>|update_<tool>|<descrição PT-BR>
```
- `categoria` comum: `ai`, `lang`, `manual`, `security`, `doctor`, `cleanup`. `--only`/`--skip-category` casam contra `categoria`+`tags`.
- `efeito`: `mutating` (baixa/muda) → skip garantido em `--mode doctor`. `read` → inspeção.
- `timeout`: self-update com download 180–600s. `0` = sem limite (só para steps que mutam o shell pai — raro).
- `cmd_deps`: binário(s) que, ausentes, viram skip `cmd-ausente: X` (não fail).

## Wiring (`lib/main.sh` → `run_all_steps`)

```bash
if has <tool>; then
    run_step "Atualizar <Tool>" update_<tool>
else
    step_skip "Atualizar <Tool>" "cmd-ausente: <tool>"
fi
```
**O nome "Atualizar <Tool>" é a chave de junção** — byte-idêntico em catálogo, aqui, e em `--skip`/`--explain-step`. Mismatch → timeout/deps caem no default silenciosamente.

## Teste (`tests/*.bats`)

Teste **lógica pura**, nunca o efeito de rede. Ex.: um helper que decide "precisa update?" a partir de duas versões:

```bash
# tests/<tool>.bats
load test_helper
@test "compara versão: igual não atualiza" {
    run version_needs_update "1.2.3" "1.2.3"
    [ "$status" -ne 0 ]
}
```
`test_helper.bash` faz source de `globals→ui→core→catalog` (+ `tray` nos testes de tray). Nunca mutar.

## Validação (mirror do CI — verde ou não entrega)

```bash
bash -n full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh
shellcheck -S warning -x full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh
bats tests/; echo "bats rc=$?"          # validar por RC, NUNCA por | tail
./full-upgrade.sh --list-steps | grep -F "Atualizar <Tool>"
./full-upgrade.sh --explain-step "Atualizar <Tool>"
XDG_CONFIG_HOME=/tmp/nocfg ./full-upgrade.sh --dry-run --mode full >/dev/null
./build.sh && ./dist/full-upgrade-standalone.sh --list-steps | grep -F "Atualizar <Tool>"
```

## Armadilhas conhecidas (memória do projeto)

- **Validar suíte por exit code, não por `| tail`** — tail esconde falha; já quebrou o release v3.15.0.
- **steps com timeout>0 rodam em subshell** — não podem mutar estado do shell pai (lock flock, sudo keepalive). Esses usam timeout `0`.
- **Nome do step é chave de junção** — o erro nº 1 é divergência de string entre catálogo e main.sh.
- **AUR rc≠0 por 1 pacote não é fail** — classificação de falha tem nuance; siga os helpers existentes.
- **standalone build inlina tudo** — nada pode depender de caminho de arquivo separado em runtime além da resolução de root.
