# Desenvolvimento

## Gate local

```bash
scripts/preflight.sh
```

Equivale aos checks bloqueantes do CI: Conventional Commits pendentes,
`bash -n`, ShellCheck (versão fixada), build do standalone e a suíte Bats. Os
hooks `commit-msg` e `pre-push` (`scripts/install-hooks.sh`) aplicam o mesmo
gate.

Etapas isoladas, com o mesmo escopo do CI:

```bash
bash -n full-upgrade.sh install.sh build.sh lib/*.sh lib/steps/*.sh lib/steps/doctor/*.sh steps.d/*.sh scripts/*.sh
shellcheck -S warning -x full-upgrade.sh lib/*.sh lib/steps/*.sh lib/steps/doctor/*.sh steps.d/*.sh install.sh build.sh scripts/*.sh
bats --jobs "$(nproc)" tests/
./build.sh && ./dist/full-upgrade-standalone.sh --list-steps
XDG_CONFIG_HOME=/tmp/nocfg ./full-upgrade.sh --dry-run --mode full
```

`shfmt -i 4 -d …` é consultivo; não é gate.

## Testes

- A suíte Bats (`tests/`) cobre funções puras e regressões e **nunca muta a
  máquina**. `tests/test_helper.bash` carrega `globals → ui → core → json →
  catalog`; cada teste carrega o módulo que exercita.
- Teste que chama um gerenciador de pacotes precisa stubar **todos** os que o
  caminho pode tocar: um gerenciador não stubado roda de verdade (um
  `corepack install -g` esquecido rebaixava o pnpm do usuário a cada execução).
- Teste que depende do host (`/opt`, `/usr/local/bin`) isola o diretório por
  variável: o runner do CI tem conteúdo que a máquina local não tem.
- Testes com repositório git criam repos descartáveis em `$BATS_TEST_TMPDIR`
  com `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_NOSYSTEM` apontando para lá.
- `tests/stub_helper.bash` isola o PATH: `stub_path_init` deixa só stubs e
  utilitários seguros (coreutils, awk, sed, grep, jq, python3), e `stub` /
  `stub_script` criam comandos falsos que registram cada chamada. Um gerenciador
  de pacotes não stubado simplesmente não existe, em vez de rodar de verdade.
- Prompts `[s/N]` e o `--config-tui` só aparecem com stdin num terminal.
  `pty_call` (em `stub_helper.bash`) roda um trecho num pseudo-terminal via
  `tests/pty_run.py` e responde aos prompts; `tests/tui_pty.py` dirige o TUI
  tecla a tecla. Os dois esperam o primeiro desenho e o fim do processo, sem
  pausas fixas, para não falhar num runner lento. O `pty_call` recoloca o PATH
  isolado depois de carregar `globals.sh`, que prependa `~/.cargo/bin`,
  `~/.local/bin` etc.
- `tests/tray_appindicator.py` exercita o menu do systray com o GTK stubado.
- Cobertura: `scripts/coverage-bats.sh` roda a suíte sob kcov. Programas awk e
  Python embutidos (o applet AppIndicator, os geradores do `--report`) ficam
  entre `# kcov-excl-start` e `# kcov-excl-stop`, porque o kcov não os
  instrumenta; eles são testados por `tests/report.bats` e
  `tests/tray_appindicator.py`.
- O kcov mede pelo `xtrace` do Bash e tem pontos cegos. Prefira a forma
  medível equivalente:
  - comando quebrado com `\` no fim da linha: a primeira linha nunca recebe
    hit; deixe o comando numa linha ou use uma variável/array intermediário;
  - array literal em várias linhas: use `arr=()` e um `arr+=(...)` por linha;
  - braço de `case` vazio (`x) ;;`): escreva `x) : ;;`;
  - padrão de `case` com `(`, mesmo entre aspas: guarde o texto numa variável;
  - `done < <(cmd)` fica fora da medição (`--exclude-line`): o fecho nunca
    recebe hit, e `done <<< "$(cmd)"` muda o comportamento com saída vazia.
- `scripts/install-kcov.sh` aplica `scripts/kcov-bash-quote-state.patch`. Sem
  ele, um `'` sem par numa linha do trace (`[[ it's == a ]]`, `for`, `case` e
  `arr+=()` saem sem escape) fazia o kcov ignorar todo o trace seguinte, de
  todos os processos, e a cobertura mudava com a ordem dos testes.
- `lib/testable/*.sh` são cópias de helpers puros usadas só pelos
  `*_pure.bats`; não são carregadas em runtime.

## Criar ou alterar um step

1. Implemente a função no arquivo da **categoria** em `lib/steps/`. Auditorias
   `doctor_*` vivem em `lib/steps/doctor/<área>.sh`; integrações opcionais, em
   `steps.d/`. O mapa categoria→arquivo é validado por teste.
2. Registre a linha no catálogo (`lib/catalog.sh`) com timeout realista, as
   dependências e a tag `network` se o step usa rede.
3. Chame o step no ponto certo de `run_all_steps()` em `lib/main.sh`, com
   `step_skip` quando a precondição falha.
4. Use `RC_WARN` para o não bloqueante e `RC_TODO` para ação manual. Dependência
   ausente vira `skip`. Condição permanente nunca vira `fail`.
5. Escreva os testes da função nova.

Convenções que já custaram bugs reais:

- Nunca `produtor | grep -q PADRÃO`: com `pipefail`, o SIGPIPE transforma um
  match em "sem match". Use `grep -q PADRÃO <<<"$var"`.
- Saída de comando externo vai ao terminal por `log_stream` (ou `run_logged`),
  nunca direto na coluna 0.
- Programas instalados fora do PATH do run (qodo, mimo, vite-plus) são achados
  com `manual_bin_path` ou uma chave `*_BIN`.
- O JavaScript pode ter até três prefixos npm; código de update e de checagem
  final percorre `npm_secondary_prefix_candidates`.

## CI

| Workflow | Função |
| --- | --- |
| `ci.yml` | `bash -n`, ShellCheck, smoke, Bats e build do standalone. No push, a suíte roda sob kcov e envia a cobertura ao Codecov. |
| `semgrep.yml` | SAST bloqueante para Bash e `pip-audit --strict` do lock do Semgrep. |
| `codeql.yml` | Análise dos próprios workflows. |
| `scorecard.yml` | OpenSSF Scorecard. |
| `commitlint.yml` | Conventional Commits. |
| `labeler.yml`, `stale.yml` | Rótulos por caminho e issues inativas. |
| `release.yml` | Valida, gera o standalone, atesta a proveniência, publica a release e o pacote AUR. |

Todas as actions são fixadas por SHA e atualizadas pelo Dependabot. O kcov é
compilado de um commit fixado (o v43 perde os traces com o bash 5.3), com o
patch de `scripts/kcov-bash-quote-state.patch`.

## Ícones

Os SVGs de `assets/icons/` são gerados por `scripts/gen-icons.py` a partir da
fonte Material Symbols Rounded. Edite os mapas no script e regenere; não edite
os SVGs à mão.

## Release

A `main` aceita push direto (protegida contra force-push). A release sai pelo
workflow `release.yml` (`workflow_dispatch` com a tag `vX.Y.Z`): ele faz o bump
de `VERSION`, fecha o `[Unreleased]` do CHANGELOG, revalida, publica a release
e atualiza o AUR.
