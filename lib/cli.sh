#!/usr/bin/env bash
# lib/cli.sh — usage, parse de flags, aplicação de modo
# shellcheck shell=bash
# As flags setam variáveis globais consumidas por main.sh/core.sh (cross-module).
# shellcheck disable=SC2034

usage() {
  cat <<'EOF'
Uso:
  full-upgrade.sh [opções]

Opções:
  -y, --yes        Modo não interativo (assume "sim")
  -d, --devel      Incluir pacotes AUR de desenvolvimento (-git, -svn, etc.)
  -n, --dry-run    Mostrar steps sem executar (simulação)
  -v, --verbose    Exibir função e argumentos de cada step antes de executar
  --mode MODE      Modo de execução formal:
                     update  — atualização + limpeza (sem doctor, sem repair)
                     doctor  — apenas auditorias (não mutável)
                     repair  — apenas reparos conhecidos
                     full    — update + doctor + repair (padrão)
  --doctor         Alias de --mode doctor
  --audit          Auditoria de segurança consolidada (read-only) e sair:
                   CVEs (cargo/arch-audit), HSI/fwupd, Secure Boot, units
                   falhadas, erros de auth, pip quebrado. Use com --json p/ saída
                   estruturada, ou com --report [ARQ] p/ Markdown.
  --no-repair      Não executar reparos mutáveis da máquina
  --no-cleanup     Não executar limpeza de cache, órfãos, symlinks ou journal
  --restart-services  Reiniciar serviços com libs antigas (checkservices), com confirmação salvo --yes
  --skip STEP      Pular um step pelo nome exato (pode repetir)
  --skip-category CAT
                   Pular categoria/tag de steps (ex: repair, slow, network)
  --only SPEC      Rodar só os steps que casam SPEC: categoria/tag ou nome exato
                   de step, lista por vírgula (ex: doctor | "Atualizar Ollama"
                   | "lang,Doctor: saúde de rede"). core/final sempre rodam.
  --list-steps     Listar catálogo de steps
  --explain-step STEP
                   Explicar um step pelo nome exato
  -c, --config     Mostrar caminhos, valores efetivos e exemplo de configuração
  --config-example Imprimir apenas um config de exemplo (pipe-friendly, sem cores)
  --json           Imprimir uma linha JSON de resumo ao final; com --report ou
                    --history, emite a saída estruturada em JSON (em vez de
                    Markdown/tabela).
  --report [ARQ]   Gerar relatório de um run a partir do JSONL e sair. Sem ARQ,
                    imprime no stdout; com ARQ, grava no arquivo. Markdown por
                    padrão; JSON com --json.
  --from RUN_ID    Selecionar qual run usar no --report (default: o último).
                    Aceita o run_id completo ou um prefixo (ex.: 20260613-142301).
  --history [N]    Mostrar tendência dos últimos N runs (default 10) e sair.
                    Lê os JSONL rotacionados; read-only, sem rede. Tabela por
                    padrão; JSON com --json.
  --resume         Re-rodar só os steps que não fecharam ok (warn/todo/fail) no
                    último run (lê o jsonl mais recente). core/final sempre rodam.
  --fail-fast      Abortar no 1º step com fail; os restantes viram skip
  --continue-on-fail
                   Continuar mesmo após um fail (padrão; torna explícito)
  -q, --quiet      Suprimir output interativo; manter log completo em arquivo
  -u, --update     Baixar e instalar a última versão do full-upgrade e sair
  --tray [SUB]     Systray daemon (requer 'yad'). Sem SUB, inicia o applet.
                     SUB: --enable  instalar autostart (XDG)
                          --disable remover autostart
                          --status  mostrar estado atual (sem rede)
                          --check   computar estado agora (faz rede) e sair
                          --restart reiniciar o applet (recarrega comportamento/ícones)
  --tray-launch [ARGS]
                   Executar full-upgrade num terminal (usado pelo applet).
                     ARGS são repassados (ex.: --mode doctor)
  --tray-view-log  Abrir o último log humano (usado pelo applet)
  -V, --version    Mostrar a versão instalada e sair
  -h, --help       Mostra esta ajuda

Status no resumo:
  ok       Step concluído
  warn     Problema não bloqueante; revisar quando possível
  todo     Ação manual necessária, mas update não falhou
  fail     Falha operacional; script encerra com código 2
  skip     Step não executado por opção, ambiente ou dependência ausente

Ambiente:
  FULL_UPGRADE_AUR_IGNORE  Pacotes AUR ignorados no update automático
                           (padrão: burpsuite; use vazio para atualizar tudo)
  FULL_UPGRADE_PIP_USER_IGNORE
                           Pacotes pip --user ignorados no update genérico
                           (padrão: poetry poetry-core chardet uvicorn urwid redis)
  FULL_UPGRADE_SKIP        Nomes de steps para pular, separados por vírgula
                           Ex: FULL_UPGRADE_SKIP="Atualizar ghcup,Atualizar gems"
EOF
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
            ;;
            --resume)
                DO_RESUME=1
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
            --tray-enable)   TRAY_MODE=enable ;;
            --tray-disable)  TRAY_MODE=disable ;;
            --tray-status)   TRAY_MODE=status ;;
            --tray-check)    TRAY_MODE=check ;;
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
                usage
                exit 0
            ;;
            *)
                echo "Opção inválida: $1" >&2
                usage >&2
                exit 2
            ;;
        esac
        shift
    done
}

# Saídas precoces (--version, --update, --explain-step, --list-steps) e tradução de --mode/--only.
apply_mode_and_early_exits() {
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
        start)   tray_main ;;
        restart) tray_restart ;;
        enable)
            tray_enable_autostart
            # Hyprland/sway não processam XDG autostart; a unit systemd cobre.
            tray_enable_systemd_unit || echo "systemd user indisponível; apenas autostart XDG habilitado."
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
