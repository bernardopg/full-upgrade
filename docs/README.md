# Documentação do full-upgrade

Referência técnica completa. Para a visão geral e o início rápido, veja o
[README](../README.md) do projeto.

## Para quem usa

| Guia | Conteúdo |
| --- | --- |
| [Instalação e atualização](installation.md) | AUR, script de instalação, standalone, requisitos e o `--update` com verificação de integridade. |
| [Uso](usage.md) | Comandos, modos, filtros, status dos steps, exit codes e receitas do dia a dia. |
| [Steps e cobertura](steps.md) | O que cada categoria atualiza, o catálogo de steps e as integrações opcionais. |
| [Doctor e auditoria](doctor.md) | Os checks read-only, `--audit` e o filtro de ruído do journal. |
| [Configuração](configuration.md) | TUI interativo, arquivo de config e a referência de todas as chaves. |
| [Systray](tray.md) | Applet de bandeja: estados, menu, badge, notificações e backends. |
| [Logs e relatórios](logs-and-reports.md) | Log humano, JSONL, `--report`, `--history`, `--json` e automação. |
| [Solução de problemas](troubleshooting.md) | Sintomas comuns, causa provável e o que fazer. |

## Para quem desenvolve

| Guia | Conteúdo |
| --- | --- |
| [Arquitetura](architecture.md) | Estrutura do código, o framework de steps, catálogo e estado entre steps. |
| [Salvaguardas](safeguards.md) | Decisões de projeto que evitam falhas reais já observadas. |
| [Desenvolvimento](development.md) | Gate local, testes, CI e como criar ou alterar um step. |

Veja também: [CONTRIBUTING](../CONTRIBUTING.md) · [SECURITY](../SECURITY.md) ·
[CHANGELOG](../CHANGELOG.md).
