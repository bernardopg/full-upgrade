#!/usr/bin/env bash
# lib/cli.sh — usage, parse de flags, aplicação de modo
# shellcheck shell=bash
# As flags setam variáveis globais consumidas por main.sh/core.sh (cross-module).
# shellcheck disable=SC2034

# ── Help (R1) — sistema de ajuda com seções e tópicos ──────────────────────────
# Colunas alinhadas, quebra de descrição com hanging indent e cores TTY-aware
# (as constantes C_* de lib/ui.sh já respeitam NO_COLOR e stdout não-TTY).
# `--help [TÓPICO]` abre ajuda específica; tópico desconhecido lista os válidos.

# Largura da coluna de flags no help (espaços após o nome da opção).
USAGE_FLAG_COL=26

# Imprime uma linha de opção: flag na coluna fixa (colorida) + descrição
# quebrada no espaço restante, com continuação alinhada sob o início do texto.
usage_flag() {
  local flag="$1" desc="$2" plain_pad out
  plain_pad="$(ui_pad "$flag" "$USAGE_FLAG_COL")"
  out="$(ui_wrap_hang "$plain_pad" "$desc")"
  if [[ -n "$C_CYAN" ]]; then
    # Coloriza só a 1ª linha (a do flag); padrão sem metacaracteres de glob.
    out="${out/$plain_pad/${C_CYAN}${plain_pad}${C_RESET}}"
  fi
  printf '%s\n' "$out"
}

# Cabeçalho de seção do help.
usage_section() {
  printf '\n%s%s%s\n' "$C_BOLD" "$1" "$C_RESET"
}

# Tópicos de ajuda válidos (um por linha).
usage_topics() {
  cat <<'EOF'
modes        Modos de execução e o que cada um roda
steps        Como pular/selecionar steps (--skip, --only, --resume)
config       Configuração: arquivo, chaves, exemplo e TUI interativo
healthcheck  Inventário read-only do setup da máquina
tui          Teclas e telas do TUI de configuração
tray         Systray daemon e subcomandos
env          Variáveis de ambiente reconhecidas
EOF
}

# Ajuda de um tópico específico. Desconhecido => mensagem + exit 2.
usage_topic() {
  local topic="$1"
  case "$topic" in
    modes)
      printf '%sfull-upgrade — tópico: modos de execução%s\n\n' "$C_BOLD" "$C_RESET"
      cat <<'EOF'
O comportamento padrão (--mode full) roda tudo: pré-flight, update, limpeza,
reparos e doctor. Cada modo limita o escopo de forma previsível:

  full     (padrão) update + limpeza + reparos + doctor.
  update   Atualização e limpeza; sem reparos mutáveis, sem doctor.
  doctor   Apenas auditorias read-only; nenhum step mutável roda.
  repair   Apenas reparos conhecidos (wireshark, coredump, shadowing, ...);
           limpeza desligada.

Modos se combinam com filtros (--skip/--only) e confirmam sempre antes de
mudar estado do sistema, salvo --yes. Consulte "full-upgrade --help steps"
para restringir ainda mais a lista de steps.
EOF
      ;;
    steps)
      printf '%sfull-upgrade — tópico: filtragem de steps%s\n\n' "$C_BOLD" "$C_RESET"
      cat <<'EOF'
Nomes de step são byte-idênticos aos do catálogo
(full-upgrade --list-steps). Um nome que não existe no catálogo é erro, não
silêncio.

  --skip "Atualizar Ollama"          pula um step pelo nome exato (repetível)
  --skip-category slow               pula categoria/tag (repair, slow,
                                     network, ai, doctor, cleanup, ...)
  --only doctor                      roda SÓ steps da categoria/tag/nome;
                                     lista por vírgula; core/final sempre rodam
  --resume                           re-roda só os steps que não fecharam ok
                                     no último run
  --explain-step "Atualizar Ollama"  descreve o step sem executá-lo

Skip persistente fica no config (chave FULL_UPGRADE_SKIP, lista por vírgula)
ou no ambiente:
  FULL_UPGRADE_SKIP="Atualizar ghcup,Atualizar gems" full-upgrade

Para gerenciar skips visualmente: full-upgrade --config-tui
EOF
      ;;
    config)
      printf '%sfull-upgrade — tópico: configuração%s\n\n' "$C_BOLD" "$C_RESET"
      cat <<'EOF'
Arquivo do usuário:  ~/.config/full-upgrade/config  (bash sourced)
Exemplo comentado:   /usr/share/full-upgrade/config.example ou
                     full-upgrade --config-example > caminho/escolhido

Zero-config funciona: tudo tem default sensato e auto-detecção
(AUR helper, elevador de privilégio, mirrors, snapshot).

  full-upgrade --config        mostra caminhos, valores efetivos e exemplo
  full-upgrade --config-tui    TUI interativo: ativa/desativa steps e edita
                               parâmetros com gravação segura no config
                               (backup automático antes de reescrever)

Chaves mais usadas:
  SNAPSHOT_TOOL=auto|snapper|timeshift|none
  AUR_HELPER=/PRIV_CMD=          vazio = auto-detecta (paru>yay>pikaur; sudo>doas)
  AUTO_FIX_RUST_CVES=1           auto-remediação de CVEs Rust (0 = só reporta)
  AUTO_BTRFS_SCRUB=1             inicia scrub btrfs vencido (0 = só reporta)
  AUTO_MERGE_PACNEW=1            mescla .pacnew seguros (0 = só reporta)
  REPORT_ON_FINISH=1             relatório .md automático ao fim do run
  NOTIFY_ON_FINISH=1             notificação desktop ao fim do run
  FULL_UPGRADE_SKIP=...          steps pulados (CSV com nomes do catálogo)

A lista completa de chaves válidas está em --config; chaves quase-iguais
(typo) geram aviso no início de cada run.
EOF
      ;;
    healthcheck)
      printf '%sfull-upgrade — tópico: healthcheck do setup%s\n\n' "$C_BOLD" "$C_RESET"
      cat <<'EOF'
  full-upgrade --healthcheck           inventário read-only do setup da
                                       máquina, com resumo ao final
  full-upgrade --healthcheck --json    mesma coleta em JSON estruturado

O que é coletado (seções):
  1. Sistema     distro, kernel em execução vs instalado, reboot pendente,
                 uptime, arquitetura
  2. Desktop     DE/WM, tipo de sessão, TTY, terminal em uso; se o shell for
                 DankMaterialShell, resumo de plugins por estado e destaque
                 dos modificados (inventário completo em --json)
  3. Specs       CPU, RAM/swap, GPU, disco raiz (tamanho/livre/fstype)
  4. Gerenciadores  pacman, helpers AUR, flatpak, snap, npm/pnpm/bun/deno,
                 pip/uv/pipx/poetry, cargo/rustup, gem, go, dotnet, ghcup —
                 caminho + versão de cada um presente
  5. Ferramentas timeshift, snapper, restic, rclone, btrfs, fwupdmgr,
                 reflector, arch-audit, yad, fastfetch/neofetch, ...
  6. Timeshift   nº de snapshots e mais recente (pede sudo -n se necessário)
  7. Backup nuvem  ferramenta em uso (config do full-upgrade primeiro) e
                 ferramentas de backup instaladas
  8. Fetch       saída do fastfetch (ou neofetch) da máquina
  9. Resumo      caixa final com os fatos-chave e veredito do setup

Read-only: nada é instalado nem alterado; sudo só é tentado de forma não
interativa (-n) para o inventário do Timeshift.
EOF
      ;;
    tui)
      printf '%sfull-upgrade — tópico: TUI de configuração%s\n\n' "$C_BOLD" "$C_RESET"
      cat <<'EOF'
  full-upgrade --config-tui    abre o TUI interativo (precisa de TTY)

Telas: menu inicial → Steps | Parâmetros | Ajuda | Salvar | Sair.
A barra de título mostra o contador de mudanças pendentes.

Teclas:
  ↑/↓ ou k/j     navegar            PgUp/PgDn, Home/End  rolar
  Space ou t     alterna step/bool  ←/→                  cicla enum
  Enter          edita int/string   d                    popup de detalhe
  /              filtro vivo        Backspace            corrige filtro
  Esc            volta (menu) / sai do filtro
  s              salvar (em qualquer tela) — revisão com diff e confirmação
                 (↑/↓ pagina a revisão quando houver muitas mudanças)
  q              sair (confirma se houver mudanças não salvas)

Gravação: alterações das duas telas são preservadas na sessão; backup
config.bak.<timestamp> antes de reescrever; upsert consolida chaves duplicadas,
preserva comentários e serializa FULL_UPGRADE_SKIP com nomes byte-idênticos do
catálogo; validação bash -n antes de ativar o novo arquivo.
EOF
      ;;
    tray)
      printf '%sfull-upgrade — tópico: systray%s\n\n' "$C_BOLD" "$C_RESET"
      cat <<'EOF'
  --tray                inicia o applet (requer yad)
  --tray --enable       instala autostart (systemd --user; fallback XDG)
  --tray --disable      remove autostart
  --tray --status       mostra estado atual (sem rede)
  --tray --check        computa estado agora (faz rede) e sai
  --tray --restart      reinicia o applet
  --tray-launch ARGS    roda o full-upgrade num terminal (uso do applet)
  --tray-view-log       abre o último log humano (uso do applet)

Formas equivalentes: --tray=enable, --tray-enable etc.
Ícone, badge e notificações são configuráveis (TRAY_* no config).
EOF
      ;;
    env)
      printf '%sfull-upgrade — tópico: variáveis de ambiente%s\n\n' "$C_BOLD" "$C_RESET"
      cat <<'EOF'
  FULL_UPGRADE_SKIP=NOME[,NOME]    steps a pular (mesclados com o config)
  FULL_UPGRADE_AUR_IGNORE=...      pacotes AUR ignorados no update
                                   (padrão: burpsuite; vazio = atualizar tudo)
  FULL_UPGRADE_PIP_USER_IGNORE=... pacotes pip --user ignorados
                                   (padrão: poetry poetry-core chardet uvicorn
                                   urwid redis)
  STALE_SERVICES_IGNORE=...        units saciadas da auditoria de libs antigas
                                   (globs permitidos)
  NO_COLOR=1 / NO_UNICODE=1        desliga cores / símbolos Unicode
  COLUMNS=N                        largura alvo do layout (default: detecta)

Ambiente vence quando não existe no config; se a mesma chave estiver nos dois,
o valor do config e o do ambiente são unidos (listas) ou o ambiente prevalece
(para FULL_UPGRADE_SKIP a união garante que o skip da linha de comando nunca é
apagado pelo config).
EOF
      ;;
    *)
      printf '%sTópico de ajuda desconhecido: %s%s\n\n' "$C_YELLOW" "$topic" "$C_RESET" >&2
      printf 'Tópicos válidos:\n%s\n' "$(usage_topics)" >&2
      return 2
      ;;
  esac
  return 0
}

# Help principal: seções agrupadas, colunas alinhadas.
usage() {
  printf '%sfull-upgrade%s %s— orquestrador modular de upgrade para Arch Linux (v%s)%s\n' \
    "$C_BOLD" "$C_RESET" "$C_DIM" "${SCRIPT_VERSION:-?}" "$C_RESET"
  cat <<'EOF'

Uso:
  full-upgrade [opções]
  full-upgrade --help [TÓPICO]
EOF

  usage_section "AJUDA"
  usage_flag "-h, --help [TÓPICO]" \
    "ajuda geral; com TÓPICO, ajuda específica. Tópicos: modes, steps, config, healthcheck, tui, tray, env"

  usage_section "MODOS DE EXECUÇÃO"
  usage_flag "-y, --yes" "modo não interativo (assume \"sim\")"
  usage_flag "-d, --devel" "incluir pacotes AUR de desenvolvimento (-git, -svn, etc.)"
  usage_flag "-n, --dry-run" "mostrar steps sem executar (simulação)"
  usage_flag "--mode MODE" "update | doctor | repair | full (padrão)"
  usage_flag "--doctor" "alias de --mode doctor"
  usage_flag "--fail-fast" "abortar no 1º step com fail; os restantes viram skip"
  usage_flag "--continue-on-fail" "continuar mesmo após um fail (padrão; torna explícito)"
  usage_flag "--no-repair" "não executar reparos mutáveis da máquina"
  usage_flag "--no-cleanup" "não executar limpeza de cache, órfãos, symlinks ou journal"
  usage_flag "--restart-services" \
    "reiniciar serviços com libs antigas (checkservices), com confirmação salvo --yes"

  usage_section "FILTROS DE STEPS"
  usage_flag "--skip STEP" "pular um step pelo nome exato (repetível)"
  usage_flag "--skip-category CAT" "pular categoria/tag de steps (ex.: repair, slow, network)"
  usage_flag "--only SPEC" \
    "rodar só steps que casam SPEC: categoria/tag ou nome exato, lista por vírgula (ex.: doctor | \"Atualizar Ollama\" | \"lang,Doctor: saúde de rede\"); core/final sempre rodam"
  usage_flag "--resume" \
    "re-rodar só os steps que não fecharam ok (warn/todo/fail) no último run; core/final sempre rodam"
  usage_flag "--list-steps" "listar catálogo de steps"
  usage_flag "--explain-step STEP" "explicar um step pelo nome exato"

  usage_section "CONFIGURAÇÃO"
  usage_flag "-c, --config" "mostrar caminhos, valores efetivos e exemplo de configuração"
  usage_flag "--config-example" "imprimir apenas um config de exemplo (pipe-friendly, sem cores)"
  usage_flag "--config-tui" \
    "abrir o TUI interativo de configuração: ativa/desativa steps, edita parâmetros, grava com backup (ver: --help tui)"

  usage_section "DIAGNÓSTICO E RELATÓRIOS"
  usage_flag "--healthcheck" \
    "inventário read-only do setup da máquina (distro, kernel, DE, specs, gerenciadores, timeshift, backup em nuvem) com resumo final; --json para JSON"
  usage_flag "--audit" \
    "auditoria de segurança consolidada (read-only) e sair: CVEs (cargo/arch-audit), HSI/fwupd, Secure Boot, units falhadas, erros de auth, pip quebrado. Use com --json p/ saída estruturada, ou com --report [ARQ] p/ Markdown"
  usage_flag "--report [ARQ]" \
    "gerar relatório de um run a partir do JSONL e sair. Sem ARQ, imprime no stdout; com ARQ, grava no arquivo. Markdown por padrão; JSON com --json"
  usage_flag "--from RUN_ID" \
    "selecionar qual run usar no --report (default: o último). Aceita o run_id completo ou um prefixo"
  usage_flag "--history [N]" \
    "mostrar tendência dos últimos N runs (default 10) e sair. Tabela por padrão; JSON com --json"
  usage_flag "--doctor-ack-journal" \
    "listar assinaturas \"unknown\" do journal do boot atual e, com confirmação (salvo --yes), gravá-las em ~/.config/full-upgrade/journal-noise.txt"

  usage_section "SAÍDA"
  usage_flag "--json" \
    "imprimir uma linha JSON de resumo ao final; com --report ou --history, emite a saída estruturada em JSON"
  usage_flag "-q, --quiet" "suprimir output interativo; manter log completo em arquivo"
  usage_flag "-v, --verbose" "exibir função e argumentos de cada step antes de executar"

  usage_section "SYSTRAY (requer yad)"
  usage_flag "--tray [SUB]" \
    "systray daemon. Sem SUB, inicia o applet. SUB: --enable (autostart), --disable, --status (sem rede), --check (faz rede), --restart"
  usage_flag "--tray-launch [ARGS]" \
    "executar full-upgrade num terminal (usado pelo applet); ARGS são repassados (ex.: --mode doctor)"
  usage_flag "--tray-view-log" "abrir o último log humano (usado pelo applet)"

  usage_section "ATUALIZAÇÃO E VERSÃO"
  usage_flag "-u, --update" "baixar e instalar a última versão do full-upgrade e sair"
  usage_flag "-V, --version" "mostrar a versão instalada e sair"

  usage_section "STATUS NO RESUMO"
  usage_flag "ok" "step concluído"
  usage_flag "warn" "problema não bloqueante; revisar quando possível"
  usage_flag "todo" "ação manual necessária, mas update não falhou"
  usage_flag "fail" "falha operacional; script encerra com código 2"
  usage_flag "skip" "step não executado por opção, ambiente ou dependência ausente"

  usage_section "AMBIENTE"
  usage_flag "FULL_UPGRADE_SKIP" \
    "nomes de steps para pular, separados por vírgula (mesclados com o config). Ex: FULL_UPGRADE_SKIP=\"Atualizar ghcup,Atualizar gems\""
  usage_flag "FULL_UPGRADE_AUR_IGNORE" \
    "pacotes AUR ignorados no update automático (padrão: burpsuite; use vazio para atualizar tudo)"
  usage_flag "FULL_UPGRADE_PIP_USER_IGNORE" \
    "pacotes pip --user ignorados no update genérico (padrão: poetry poetry-core chardet uvicorn urwid redis)"
  usage_flag "STALE_SERVICES_IGNORE" \
    "units saciadas da auditoria de libs antigas (needrestart/checkservices): sem TODO/reinício. Ex: STALE_SERVICES_IGNORE=\"NetworkManager.service\""

  printf '\n%sDica:%s full-upgrade --help config mostra como gerenciar tudo pelo TUI.\n' \
    "$C_BOLD" "$C_RESET"
  return 0
}


parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            -y|--yes)       ASSUME_YES=1 ;;
            -d|--devel)     DEVEL_UPDATE=1 ;;
            -n|--dry-run)   DRY_RUN=1 ;;
            -q|--quiet)     QUIET=1 ;;
            -v|--verbose)   VERBOSE=1 ;;
            --doctor)       MODE=doctor ;;
            --audit)        DO_AUDIT=1 ;;
            --healthcheck)  DO_HEALTHCHECK=1 ;;
            --config-tui)   DO_CONFIG_TUI=1 ;;
            --mode)
                shift
                case "${1:-}" in
                    update|doctor|repair|full) MODE="$1" ;;
                    "")
                        echo "Opção --mode requer um valor: update, doctor, repair ou full." >&2
                    usage >&2; exit 2 ;;
                    *)
                        echo "Modo inválido: $1. Use: update, doctor, repair ou full." >&2
                    usage >&2; exit 2 ;;
                esac
            ;;
            --mode=update|--mode=doctor|--mode=repair|--mode=full)
                MODE="${1#--mode=}"
            ;;
            --no-repair)    NO_REPAIR=1 ;;
            --no-cleanup)   NO_CLEANUP=1 ;;
            --restart-services) RESTART_SERVICES=1 ;;
            --skip)
                shift
                if (( $# == 0 )) || [[ "$1" == -* ]]; then
                    echo "Opção --skip requer o nome exato de um step." >&2
                    usage >&2
                    exit 2
                fi
                add_skip_step "$1"
            ;;
            --skip=*)
                [[ -n "${1#--skip=}" ]] || { echo "Opção --skip requer o nome exato de um step." >&2; usage >&2; exit 2; }
                add_skip_step "${1#--skip=}"
            ;;
            --skip-category)
                shift
                if (( $# == 0 )) || [[ "$1" == -* ]]; then
                    echo "Opção --skip-category requer uma categoria/tag." >&2
                    usage >&2
                    exit 2
                fi
                if ! add_skip_category "$1"; then
                    echo "Categoria/tag desconhecida para --skip-category: $1" >&2
                    usage >&2
                    exit 2
                fi
            ;;
            --skip-category=*)
                if ! add_skip_category "${1#--skip-category=}"; then
                    echo "Categoria/tag desconhecida para --skip-category: ${1#--skip-category=}" >&2
                    usage >&2
                    exit 2
                fi
            ;;
            --only)
                shift
                case "${1:-}" in
                    doctor) MODE=doctor ;;
                    "")
                        echo "Opção --only requer uma categoria." >&2
                        usage >&2
                        exit 2
                    ;;
                    *) ONLY_CATEGORY="$1" ;;
                esac
            ;;
            --only=doctor) MODE=doctor ;;
            --only=*)
                ONLY_CATEGORY="${1#--only=}"
                [[ -n "$ONLY_CATEGORY" ]] || { echo "Opção --only requer uma categoria, tag ou step." >&2; usage >&2; exit 2; }
            ;;
            --list-steps)
                LIST_STEPS=1
            ;;
            -c|--config)
                SHOW_CONFIG=1
            ;;
            --config-example)
                SHOW_CONFIG=2
            ;;
            --json)
                JSON_SUMMARY=1
            ;;
            --report)
                DO_REPORT=1
                if (( $# >= 2 )) && [[ "$2" != -* ]]; then
                    REPORT_FILE="$2"
                    shift
                fi
            ;;
            --report=*)
                DO_REPORT=1
                REPORT_FILE="${1#--report=}"
                [[ -n "$REPORT_FILE" ]] || { echo "Use --report sem '=' para imprimir no terminal, ou informe um arquivo." >&2; usage >&2; exit 2; }
            ;;
            --from)
                shift
                if (( $# == 0 )) || [[ "$1" == -* ]]; then
                    echo "Opção --from requer um run_id." >&2
                    usage >&2
                    exit 2
                fi
                REPORT_FROM="$1"
            ;;
            --from=*)
                REPORT_FROM="${1#--from=}"
                [[ -n "$REPORT_FROM" ]] || { echo "Opção --from requer um run_id." >&2; usage >&2; exit 2; }
            ;;
            --history)
                DO_HISTORY=1
                if (( $# >= 2 )) && [[ "$2" =~ ^[0-9]+$ ]]; then
                    HISTORY_N="$2"
                    shift
                fi
            ;;
            --history=*)
                DO_HISTORY=1
                HISTORY_N="${1#--history=}"
                [[ "$HISTORY_N" =~ ^[1-9][0-9]*$ ]] || { echo "Opção --history requer um inteiro positivo." >&2; usage >&2; exit 2; }
            ;;
            --resume)
                DO_RESUME=1
            ;;
            --doctor-ack-journal)
                DO_DOCTOR_ACK_JOURNAL=1
            ;;
            --fail-fast)
                FAIL_FAST=1
            ;;
            --continue-on-fail)
                FAIL_FAST=0
            ;;
            --explain-step)
                shift
                if (( $# == 0 )) || [[ "$1" == -* ]]; then
                    echo "Opção --explain-step requer o nome exato de um step." >&2
                    usage >&2
                    exit 2
                fi
                EXPLAIN_STEP="$1"
            ;;
            --explain-step=*)
                EXPLAIN_STEP="${1#--explain-step=}"
                [[ -n "$EXPLAIN_STEP" ]] || { echo "Opção --explain-step requer o nome exato de um step." >&2; usage >&2; exit 2; }
            ;;
            -V|--version)
                SHOW_VERSION=1
            ;;
            -u|--update)
                DO_SELF_UPDATE=1
            ;;
            --tray)
                case "${2:-}" in
                    --enable|--disable|--status|--check|--restart|enable|disable|status|check|restart)
                        case "$2" in --*) TRAY_MODE="${2#--}" ;; *) TRAY_MODE="$2" ;; esac
                        shift
                    ;;
                    *) TRAY_MODE=start ;;
                esac
            ;;
            --tray=start|--tray=enable|--tray=disable|--tray=status|--tray=check|--tray=restart)
                TRAY_MODE="${1#--tray=}"
            ;;
            --tray-enable)   TRAY_MODE=enable ;;
            --tray-disable)  TRAY_MODE=disable ;;
            --tray-status)   TRAY_MODE=status ;;
            --tray-check)    TRAY_MODE=check ;;
            --tray-restart)  TRAY_MODE=restart ;;
            --tray-launch)
                TRAY_LAUNCH=1
                shift
                TRAY_LAUNCH_ARGS=("$@")
                break
            ;;
            --tray-view-log)
                TRAY_VIEW_LOG=1
            ;;
            -h|--help)
                # "--help TÓPICO" agenda a ajuda do tópico (aplicada no early
                # exit, depois do load); sem tópico imprime a ajuda geral já aqui.
                if [[ -n "${2:-}" && "$2" != -* ]]; then
                    HELP_TOPIC="$2"
                    shift
                else
                    usage
                    exit 0
                fi
            ;;
            *)
                echo "Opção inválida: $1" >&2
                usage >&2
                exit 2
            ;;
        esac
        shift
    done

    if [[ -n "$REPORT_FROM" ]] && (( DO_REPORT == 0 )); then
        echo "Opção --from só pode ser usada com --report." >&2
        usage >&2
        exit 2
    fi
    if (( DO_HISTORY == 1 )) && [[ ! "$HISTORY_N" =~ ^[1-9][0-9]*$ ]]; then
        echo "Opção --history requer um inteiro positivo." >&2
        usage >&2
        exit 2
    fi
    if (( DO_HISTORY == 1 && (DO_REPORT == 1 || DO_AUDIT == 1) )); then
        echo "Use apenas uma ação: --history, --report ou --audit." >&2
        usage >&2
        exit 2
    fi
    # R3/R4 — ações exclusivas: healthcheck e config-tui são modos de "entrar,
    # fazer uma coisa, sair"; não combinam entre si nem com report/audit/history.
    local _exclusive=0
    (( DO_HEALTHCHECK )) && _exclusive=$(( _exclusive + 1 ))
    (( DO_CONFIG_TUI   )) && _exclusive=$(( _exclusive + 1 ))
    (( DO_REPORT       )) && _exclusive=$(( _exclusive + 1 ))
    (( DO_AUDIT        )) && _exclusive=$(( _exclusive + 1 ))
    (( DO_HISTORY      )) && _exclusive=$(( _exclusive + 1 ))
    if (( _exclusive > 1 )); then
        echo "Use apenas uma ação por invocação: --healthcheck, --config-tui, --report, --audit ou --history." >&2
        usage >&2
        exit 2
    fi
    if [[ -n "${HELP_TOPIC:-}" ]] && { (( DO_HEALTHCHECK )) || (( DO_CONFIG_TUI )); }; then
        echo "--help TÓPICO não se combina com ações (--healthcheck/--config-tui)." >&2
        usage >&2
        exit 2
    fi
}

# Saídas precoces (--version, --update, --explain-step, --list-steps) e tradução de --mode/--only.
apply_mode_and_early_exits() {
    # Ajuda por tópico (--help healthcheck etc.). Depois do parse, antes de tudo.
    if [[ -n "${HELP_TOPIC:-}" ]]; then
        usage_topic "$HELP_TOPIC"
        exit $?
    fi

    if (( SHOW_VERSION )); then
        printf '%s\n' "${SCRIPT_VERSION}"
        exit 0
    fi

    if (( DO_SELF_UPDATE )); then
        self_perform_update
        local _rc=$?
        # RC_WARN (rede/erro) vira exit 1; sucesso/cancelado vira 0.
        (( _rc == 0 )) && exit 0
        exit 1
    fi

    # Systray daemon e ações relacionadas (todas saem sem rodar o fluxo).
    if (( TRAY_LAUNCH )); then
        tray_launch_full_upgrade "${TRAY_LAUNCH_ARGS[@]}"
        exit 0
    fi
    if (( TRAY_VIEW_LOG )); then
        tray_view_log
        exit 0
    fi
    case "$TRAY_MODE" in
        start)   tray_main; exit $? ;;
        restart) tray_restart; exit $? ;;
        enable)
            # Um único mecanismo evita corrida/daemon duplicado no login.
            # Hyprland/sway precisam da unit; XDG fica como fallback portátil.
            if tray_enable_systemd_unit; then
                tray_remove_autostart_quiet
            else
                tray_enable_autostart
                echo "systemd user indisponível; autostart XDG habilitado."
            fi
            exit 0 ;;
        disable)
            tray_disable_autostart
            tray_disable_systemd_unit
            exit 0 ;;
        status)  tray_print_status; exit 0 ;;
        check)   tray_check_and_print; exit 0 ;;
    esac

    if [[ -n "$EXPLAIN_STEP" ]]; then
        explain_step "$EXPLAIN_STEP"
        exit $?
    fi

    if (( LIST_STEPS )); then
        print_step_catalog
        exit 0
    fi

    # --healthcheck: inventário read-only do setup e sair (antes de --audit).
    if (( DO_HEALTHCHECK )); then
        healthcheck_main
        exit $?
    fi

    # --config-tui: TUI interativo de configuração e sair.
    if (( DO_CONFIG_TUI )); then
        config_tui_main
        exit $?
    fi

    # --audit precede --report: "--audit --report" persiste a auditoria em
    # Markdown (run_audit_mode lê DO_REPORT/REPORT_FILE), em vez do relatório de run.
    if (( DO_AUDIT )); then
        run_audit_mode
        exit $?
    fi

    if (( DO_REPORT )); then
        generate_report "$REPORT_FROM" "$REPORT_FILE"
        exit $?
    fi

    if (( DO_HISTORY )); then
        report_history "$HISTORY_N"
        exit $?
    fi

    if (( DO_DOCTOR_ACK_JOURNAL )); then
        doctor_ack_journal_interactive
        exit $?
    fi

    if (( SHOW_CONFIG == 2 )); then
        print_config_example
        exit 0
    fi
    if (( SHOW_CONFIG == 1 )); then
        show_config
        exit 0
    fi
    
    # --resume: re-roda só os steps que não fecharam ok (warn/todo/fail) no
    # último run (lê o jsonl mais recente, antes de setup_logging repontar o
    # latest). Mantém core/final. Sem pendências => sai 0 sem rodar.
    if (( DO_RESUME )); then
        local -a _pend=() _keep=()
        mapfile -t _pend < <(resume_pending_steps)
        if (( ${#_pend[@]} == 0 )); then
            echo "Nada a retomar: o último run não deixou steps em warn/todo/fail (ou não há jsonl)." >&2
            exit 0
        fi
        local _n
        for _n in "${_pend[@]}"; do
            catalog_has_step_name "$_n" && _keep+=("$_n")
        done
        if (( ${#_keep[@]} == 0 )); then
            echo "Nada a retomar: os steps pendentes do último run não existem mais no catálogo." >&2
            exit 0
        fi
        apply_only_names "${_keep[@]}"
        RESUME_STEPS="${_keep[*]}"
        return 0
    fi

    # traduzir --mode para flags canônicas
    case "$MODE" in
        doctor)
            if ! apply_only_category doctor; then
                echo "Categoria 'doctor' não encontrada no catálogo." >&2; exit 2
            fi
            # "doctor — apenas auditorias (não mutável)": pula também os steps
            # mutantes core/final que sobreviveriam ao filtro por categoria
            # (keyring via pacman -Sy, backup de /etc).
            add_skip_mutating_steps
        ;;
        repair)
            # apenas categoria repair (+ core implícito)
            if ! apply_only_category repair; then
                echo "Categoria 'repair' não encontrada no catálogo." >&2; exit 2
            fi
            NO_CLEANUP=1
        ;;
        update)
            # update + limpeza; sem repair, sem doctor
            NO_REPAIR=1
            add_skip_category doctor || true
        ;;
        full|"")
            # comportamento padrão: tudo
        ;;
    esac
    
    if [[ -n "$ONLY_CATEGORY" ]]; then
        if ! apply_only_filter "$ONLY_CATEGORY"; then
            echo "Token desconhecido para --only (não é categoria/tag nem nome de step): $ONLY_CATEGORY" >&2
            usage >&2
            exit 2
        fi
    fi
}
