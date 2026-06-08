# Contribuindo

Obrigado pelo interesse em melhorar o `full-upgrade`. Este é um orquestrador
Bash puro (4+) para Arch Linux; não há artefatos compilados.

## Validação antes de qualquer commit

Não há framework de testes unitários. A verificação espelha o CI:

```bash
# Sintaxe
bash -n full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh

# Lint
shellcheck -S warning -x full-upgrade.sh lib/*.sh lib/steps/*.sh steps.d/*.sh install.sh build.sh

# Testes unitários (bats — funções puras, sem mutação)
bats tests/

# Smoke (sem mutação — seguro em qualquer máquina, inclusive CI não-Arch)
./full-upgrade.sh --help
./full-upgrade.sh --list-steps
XDG_CONFIG_HOME=/tmp/nocfg ./full-upgrade.sh --dry-run --mode full

# Build single-file (teste após mudanças estruturais)
./build.sh && ./dist/full-upgrade-standalone.sh --list-steps
```

`--dry-run` registra cada step como `skip` sem rodar comandos mutáveis — é a
principal forma de exercitar o fluxo com segurança.

## Adicionar ou alterar um step

O padrão central é `run_step "Nome exato" funcao_impl`. Para um novo step:

1. Implemente a função no `lib/steps/<domínio>.sh` adequado.
2. Adicione uma linha no catálogo (`lib/catalog.sh`) com timeout realista e
   `cmd_deps` declaradas:
   `nome|categoria|tags|efeito|timeout|cmd_deps|func_name|descrição`.
3. Chame o step no ponto correto de `lib/main.sh` (`run_all_steps`).
4. Use o contrato de retorno: `RC_WARN` (não bloqueante/transitório),
   `RC_TODO` (ação manual). Deixe dependência ausente virar `skip`, não `fail`.

> **O nome do step é a chave de junção.** Ele precisa ser byte-idêntico na linha
> do catálogo, na chamada em `main.sh` e em qualquer `--skip`/`--explain-step`.
> Uma divergência quebra silenciosamente a busca de metadados.

Veja [`CLAUDE.md`](CLAUDE.md) para a arquitetura completa.

## Convenções

- Funções de step retornam pelo contrato de RC; nunca `exit` de dentro de um step.
- `set -uo pipefail` está ativo (sem `-e`) — cheque códigos de retorno explicitamente.
- Comentários e textos ao usuário em **PT-BR**.
- Para gravar saída crua de comando no log, use `log_raw` (remove ANSI), não
  `printf ... >> "$LOG_FILE"`.

## Pull requests

- Branch a partir de `main`; um PR por mudança lógica.
- Garanta que validação (sintaxe + shellcheck + dry-run) passa localmente.
- Atualize `CHANGELOG.md` quando o comportamento mudar.
