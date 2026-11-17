# Arquitetura

Bash puro (4.3+), sem artefatos compilados. Saída e comentários em PT-BR.

## Estrutura

```text
.
├── full-upgrade.sh      # entrypoint: resolve o root, carrega as libs e inicia o fluxo
├── install.sh           # instalação em ~/.local/share + symlink no PATH
├── build.sh             # gera dist/full-upgrade-standalone.sh (arquivo único)
├── config.example       # template de configuração
├── lib/
│   ├── globals.sh       # estado global, paths e flags
│   ├── ui.sh            # cores, símbolos, banner e resumo
│   ├── core.sh          # run_step, status, timeouts, portão de rede, helpers git
│   ├── json.sh          # JSONL, RUN_ID e rotação de logs
│   ├── sudo.sh          # validação e keepalive de privilégio
│   ├── config.sh        # config XDG e autodetecção
│   ├── catalog.sh       # catálogo de steps e filtros
│   ├── cli.sh           # flags, modos e saídas precoces
│   ├── report.sh        # --report (Markdown e JSON)
│   ├── history.sh       # --history
│   ├── healthcheck.sh   # --healthcheck
│   ├── notify.sh        # notificação ao fim do run
│   ├── tray.sh          # systray: estado, AppIndicator/yad, menu
│   ├── tui.sh           # --config-tui
│   ├── main.sh          # ordem de execução (run_all_steps)
│   └── steps/           # implementação por categoria; doctor/ por área
├── steps.d/             # integrações opcionais empacotadas
├── assets/icons/        # ícones gerados por scripts/gen-icons.py
├── res/                 # desktop entry e unit systemd do systray
└── tests/               # suíte Bats
```

O entrypoint carrega as bibliotecas em ordem de dependência
(`globals → ui → core → json → sudo → config → catalog → cli → report →
history → notify → tray → steps → main`) e executa
`load_config → parse_args → apply_mode_and_early_exits → setup_logging →
print_banner → run_all_steps → finalize`.

## O framework de steps

Tudo é executado por `run_step "Nome exato" funcao`, que:

1. respeita `FULL_UPGRADE_SKIP` (onde os filtros e modos depositam os skips);
2. vira `skip` em `--dry-run`;
3. lê os metadados do catálogo e pula com `cmd-ausente: X` se falta dependência;
4. espera a conectividade antes de steps com tag `network`;
5. aplica o timeout do step (função em subshell com sentinela);
6. traduz o código de retorno em status e grava log humano e evento JSONL.

| Retorno | Status |
| --- | --- |
| `0` | `ok` |
| `RC_WARN` (10) | `warn` |
| `RC_TODO` (11) | `todo` |
| `124` (timeout) | `warn` |
| outro | `fail` (exit code final `2`) |

`STEP_REASON` vira o campo `reason` do JSONL e a linha de motivo do resumo.

## Catálogo e dispatch

O step existe em dois lugares, mantidos em sincronia:

- **`lib/catalog.sh`**: uma linha por step
  (`nome|categoria|tags|efeito|timeout|cmd_deps|função|descrição`). Alimenta
  `--list-steps`, `--explain-step`, filtros, timeouts, dependências e o total da
  barra de progresso.
- **`lib/main.sh`**: `run_all_steps()` define a ordem real e chama
  `step_skip "Nome" "motivo"` quando uma precondição falha, para o step aparecer
  no resumo.

O **nome do step é a chave de junção**: precisa ser idêntico byte a byte no
catálogo, no `main.sh` e em qualquer `--skip`/`--explain-step`. Uma divergência
quebra a busca de metadados em silêncio.

## Estado entre steps

Steps com timeout rodam em subshell, então variáveis globais não chegam ao step
seguinte. Estado compartilhado vai para arquivos com o `RUN_ID` em
`~/.cache/system-upgrade/` (por exemplo `.pkgs-before`, `.pacfiles-todo`,
`.aur-out-of-date`, `.aur-build-failed`). A rotação de logs agrupa por `RUN_ID`,
então esses arquivos são limpos sem precisar de registro.

## Portão de conectividade

Um step de rede com a rede fora não falha rápido: trava até o timeout. Por isso
`run_step` sonda a rede (rotas IPv4/IPv6 e um `getent` com limite) antes de cada
step com tag `network`, guarda o veredito por alguns segundos e espera até
`NETWORK_GATE_WAIT_S` pela volta da rede antes de fechar o step como `warn`.
Todo step que chama `run_network_cmd`/`_retry` precisa da tag `network`, e um
teste garante isso.

## Modos e filtros

`--mode`, `--only` e `--skip-category` são resolvidos antes do run somando nomes
à lista de skips; `run_all_steps` não conhece filtros. `--mode doctor` ainda
pula todo step `mutating`, o que torna o modo read-only por construção.

## Standalone

`build.sh` embute todas as bibliotecas num arquivo só. Nada pode depender de
caminhos de arquivo separados em tempo de execução além da resolução do root.
O systray funciona no standalone, mas os ícones são externos: sem `icons/` ao
lado do script, ele recorre ao tema hicolor.
