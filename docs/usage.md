# Uso

## Comandos

| Comando | Quando usar |
| --- | --- |
| `full-upgrade` | Fluxo completo: updates, reparos, limpeza, checks finais e auditorias. |
| `full-upgrade -y` | Mesmo fluxo, sem perguntas (assume as confirmações seguras). |
| `full-upgrade --dry-run` | Ver o plano sem executar nada que mute o sistema. |
| `full-upgrade --mode update` | Atualizar e limpar, sem reparos nem doctor. |
| `full-upgrade --mode doctor` | Só auditorias. Garantidamente read-only. |
| `full-upgrade --mode repair` | Só reparos conhecidos (mais os steps compartilhados). |
| `full-upgrade --resume` | Re-rodar só os steps que não fecharam `ok` no último run real. |
| `full-upgrade --list-steps` | Listar o catálogo de steps. |
| `full-upgrade --explain-step "NOME"` | Descrever um step: categoria, tags, timeout, dependências. |
| `full-upgrade --config` | Caminhos, valores efetivos e sugestão de correção para chaves com erro de digitação. |
| `full-upgrade --config-tui` | Configurar por um TUI interativo (ver [Configuração](configuration.md)). |
| `full-upgrade --config-example` | Imprimir só o config de exemplo, para redirecionar a um arquivo. |
| `full-upgrade --healthcheck [--json]` | Inventário read-only da máquina: distro, kernel, specs, gerenciadores, snapshots. |
| `full-upgrade --audit` | Auditoria de segurança consolidada, sem mutar (ver [Doctor](doctor.md)). |
| `full-upgrade --report [ARQ]` | Relatório do último run em Markdown (ou `--report --json`). |
| `full-upgrade --history [N]` | Tabela e tendência dos últimos runs (ou `--history --json`). |
| `full-upgrade --tray` | Iniciar o applet de bandeja (ver [Systray](tray.md)). |
| `full-upgrade --help [TÓPICO]` | Ajuda por tópico: `modes`, `steps`, `config`, `healthcheck`, `tui`, `tray`, `env`. |

Outras opções:

| Opção | Efeito |
| --- | --- |
| `-q`, `--quiet` | Reduz a saída no terminal; o log continua completo. |
| `-v`, `--verbose` | Mostra a função e os argumentos de cada step. |
| `--json` | Imprime uma linha JSON de resumo ao final. |
| `--fail-fast` | Aborta no primeiro `fail`; os steps restantes viram `skip`. |
| `--no-repair` / `--no-cleanup` | Desliga reparos mutáveis / limpeza. |
| `--restart-services` | Permite reiniciar serviços com bibliotecas antigas (`needrestart`/`checkservices`). |
| `-d`, `--devel` | Inclui pacotes AUR de desenvolvimento (`-git`, `-svn`…). |

## Modos

| Modo | Escopo |
| --- | --- |
| `full` | Padrão. Todo o fluxo disponível no ambiente. |
| `update` | Updates e limpeza, sem reparos opcionais e sem doctor. |
| `doctor` | Auditorias. Todo step com `efeito=mutating` é pulado, inclusive os de core e final. |
| `repair` | Reparos conhecidos, sem limpeza. |

## Filtros

```bash
full-upgrade --only doctor                       # uma categoria
full-upgrade --only ai                           # todas as CLIs de IA
full-upgrade --only "Atualizar Ollama"           # um step pelo nome exato
full-upgrade --only "lang,Doctor: saúde de rede" # lista: categoria/tag + nome
full-upgrade --skip-category slow                # pular por categoria ou tag
full-upgrade --skip "Atualizar ghcup"            # pular um step
FULL_UPGRADE_SKIP="Atualizar ghcup,Atualizar gems de usuário" full-upgrade
```

- `--only` e `--skip-category` aceitam categoria, tag ou nome exato de step.
  Token desconhecido é erro, não silêncio.
- Os steps das categorias `core` e `final` sempre rodam.
- Os filtros funcionam somando nomes à lista de skips antes do run; a lista
  completa fica no log e no JSONL.

Categorias e tags estão em [Steps e cobertura](steps.md).

## Status dos steps

| Status | Significado | Exit code |
| --- | --- | --- |
| `ok` | Step concluído. | Mantém sucesso. |
| `warn` | Problema não bloqueante ou falha transitória tratada (ex.: rede). | Mantém sucesso. |
| `todo` | Requer decisão ou ação manual; o resumo traz a remediação. | Mantém sucesso. |
| `fail` | Falha operacional real. | Encerra com exit code `2`. |
| `skip` | Pulado por filtro, dependência ausente, ambiente ou `--dry-run`. | Mantém sucesso. |

## Receitas

Antes de uma execução real:

```bash
full-upgrade --dry-run
```

Automação (cron, timer systemd) com risco mínimo:

```bash
full-upgrade --mode update --no-repair --no-cleanup --json --quiet -y
```

Investigar uma falha:

```bash
tail -n 120 ~/.cache/system-upgrade/latest.log
jq -r 'select(.event == "step" and .status == "fail")' ~/.cache/system-upgrade/latest.jsonl
full-upgrade --resume
```
