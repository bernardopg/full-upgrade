# Logs e relatórios

Cada run deixa um log legível e um log estruturado, com o mesmo `run_id`.

```text
~/.cache/system-upgrade/
  full-upgrade-<run_id>.log     # log humano, sem escapes ANSI
  full-upgrade-<run_id>.jsonl   # um evento por linha
  full-upgrade-<run_id>.md      # relatório (com REPORT_ON_FINISH=1)
  latest.log   -> último log humano
  latest.jsonl -> último log estruturado
```

São mantidos os artefatos dos 20 runs mais recentes. A rotação agrupa por
`run_id`, então arquivos auxiliares de um run (como `.pkgs-before`) saem junto.

## JSONL

| Evento | Quando |
| --- | --- |
| `run_start` | Início do run. Traz versão, `scope` e `args`. |
| `step` | Um por step, com status, duração e motivo. |
| `pkg_changes` | Pacotes atualizados, instalados e removidos. |
| `summary` | Contagens, totais por grupo, steps mais lentos e reboot recomendado. |
| `run_end` | Fim do run. |

| Campo | Descrição |
| --- | --- |
| `run_id` | Identificador do run (`AAAAMMDD-HHMMSS-PID`). |
| `scope` | `completo`, `doctor`, `update`, `repair`, `filtrado`, `resume` ou `dry-run`. |
| `args` | Argumentos da linha de comando. |
| `step`, `status` | Nome do step e `ok`/`warn`/`todo`/`fail`/`skip`. |
| `reason` | Motivo de `warn`, `todo`, `fail` ou `skip`. |
| `duration_seconds`, `exit_code` | Duração e código de retorno do step. |
| `category`, `tags`, `effect`, `timeout` | Metadados do catálogo. |
| `category_totals`, `slowest_steps` | No `summary`: totais por grupo e os 3 steps mais lentos. |
| `reboot_recommendation` | No `summary`: motivo de reboot, quando houver. |
| `log_file`, `jsonl_file` | Caminhos dos artefatos do run. |

```bash
jq -c 'select(.event == "summary")' ~/.cache/system-upgrade/latest.jsonl
jq -r 'select(.event == "step" and .status != "ok") | [.status, .step, .reason] | @tsv' \
  ~/.cache/system-upgrade/latest.jsonl
```

## Relatório

```bash
full-upgrade --report                 # Markdown do último run
full-upgrade --report relatorio.md    # em um arquivo
full-upgrade --report --json          # JSON estruturado
full-upgrade --report --from RUN_ID   # de um run específico
```

O cabeçalho traz versão, início, fim, duração, resultado, escopo, linha de
comando, reboot recomendado, os 3 steps mais lentos e os caminhos do log e do
JSONL. Depois vêm os pacotes alterados, os steps por grupo, os pulados com o
motivo e as notas operacionais. `REPORT_ON_FINISH=1` grava o relatório ao fim
de todo run.

## Histórico

```bash
full-upgrade --history        # últimos 10 runs
full-upgrade --history 30
full-upgrade --history --json
```

```text
DATA              VERSÃO        ESCOPO      ok warn todo fail skip    DURAÇÃO
2026-11-17 16:15  3.55.0        doctor      30    1    2    0  119     3m 39s
2026-11-17 15:14  3.55.0        completo   135    0    0    0   17     7m 51s

Tendência de duração: 11m 55s → 7m 51s (↓ -4m 04s).
Warns/todos recorrentes (em ≥2 runs):
  2× Doctor: crashes recorrentes (coredump)
```

A tendência compara só runs do mesmo escopo: um `--mode doctor` não é medido
contra um run completo.

## Resumo no terminal

Ao final de cada run, os steps aparecem agrupados por área com o tempo de cada
grupo, seguidos dos pulados com o motivo, do total, dos 3 mais lentos, dos
pacotes alterados e dos próximos passos (para `warn`, `todo` e `fail`).

`--json` imprime também uma linha JSON com o resumo, e `NOTIFY_ON_FINISH=1`
envia uma notificação desktop.
