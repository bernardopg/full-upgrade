# Doctor e auditoria

O Doctor transforma manutenção em diagnóstico acionável. Seus steps são
**estritamente read-only** (invariante validada por teste) e rodam no fim do
fluxo completo ou sozinhos com `full-upgrade --mode doctor`. Achado que exige
ação vira `todo` com a remediação; achado não bloqueante vira `warn`.

## Checks

| Check | Detecta |
| --- | --- |
| Reboot pendente | Kernel, systemd ou microcode atualizados sem reboot. |
| systemd | Units falhadas no sistema e no usuário, e units em loop de restart (`Restart=on-failure` rearmando: em `auto-restart` agora, ou com `NRestarts>0` na última ativação, mesmo que já tenham passado) com pelo menos `SYSTEMD_RESTART_LOOP_MIN` (padrão 3) falhas no boot atual — essas nunca chegam a `failed`. Scopes transitórios (`*.scope`) já encerrados são informativos e limpos pelo reparo. |
| Journal | Erros críticos do boot atual, agrupados e com ruído conhecido filtrado. |
| Crashes recorrentes | Coredumps dos últimos 14 dias por programa; `todo` quando quebrou 3+ vezes **e** voltou a quebrar nas últimas 48 h. Binários de build do cargo (`target/debug`, `target/release`) viram nota informativa, sem `todo`. |
| Firmware | Nível HSI de `fwupdmgr security`: contagem de atributos ✔ e lista dos ✘. |
| Flatpak | Inconsistências via `flatpak repair --user --dry-run` (repete a verificação completa só quando os refs mudam ou a cada 7 dias). |
| Disco | Espaço e inodes nos mounts essenciais. |
| Boot | systemd-boot, kernel/initrd e espaço no ESP. |
| Rede | DNS e HTTPS contra os mirrors do Arch. |
| Serviços antigos | Serviços usando bibliotecas já atualizadas (`needrestart`/`checkservices`). |
| pacman | Arquivos ausentes (`pacman -Qkq`), com falsos positivos conhecidos filtrados. |
| `.pacnew`/`.pacsave` | Merges pendentes em `/etc`. |
| CVEs oficiais | Vulnerabilidades via `arch-audit`: corrigível vira `warn`, sem correção vira `todo`. |
| Hooks ALPM | Hooks com falha no journal do boot atual. |
| SMART/NVMe | Saúde dos discos via `smartctl` e `nvme`. |
| btrfs | Erros de device e idade do último scrub. |
| Tempo de boot | Total de `systemd-analyze time` e as 5 piores units. |
| Sessão desktop | Portais, PipeWire, WirePlumber e informações gráficas. |
| Apps manuais | Programas fora de gerenciador sem step de atualização. |
| Pacotes locais | Pacote de PKGBUILD local que o AUR não conhece e está atrás do release do GitHub. |
| CLIs de IA | Versões das CLIs detectadas, cada `--version` limitado por `AI_CLI_VERSION_TIMEOUT_S`. |
| Servidores MCP | Configs de Claude, Codex, OpenCode, hub central e Hermes: executáveis, configurações e variáveis obrigatórias (no Codex, `bearer_token_env_var`; `env_vars` é repasse opcional), sem imprimir segredos. |
| Python e JavaScript | Dependências quebradas, venvs ausentes, interpretadores inválidos e conflitos npm/pnpm. |

Os limites e opt-ins de cada check (`BTRFS_SCRUB_MAX_DAYS`,
`BOOT_TIME_WARN_S`, `FWUPD_HSI_MIN`, `COREDUMP_IGNORE_EXE`,
`STALE_SERVICES_IGNORE`…) estão em [Configuração](configuration.md#doctor).

## Auditoria de segurança

```bash
full-upgrade --audit
```

Consolida, sem mutar nada, CVEs de pacotes oficiais e do AUR, CVEs de binários
Rust, segurança de firmware (HSI) e saúde do btrfs. As remediações existem como
steps `autofix` separados e desligados por padrão (`AUTO_FIX_RUST_CVES`,
`AUTO_BTRFS_SCRUB`, `AUTO_MERGE_PACNEW`, `AUTO_FIX_PIP_DEPS`,
`AUTO_RECREATE_STALE_CONTAINERS`).

## Reconhecer achados conhecidos

```bash
full-upgrade --doctor-ack-journal      # grava as assinaturas "unknown" do boot atual como ruído local
full-upgrade --doctor-ack-coredumps    # marca os crashes recorrentes atuais como reconhecidos
```

Crash novo depois do reconhecimento volta a alertar.

## Filtro de ruído do journal

`Doctor: journal erros críticos` já filtra ruído conhecido (firmware/ACPI,
drivers, keyring, corridas de boot). Para silenciar padrões da sua máquina,
crie `~/.config/full-upgrade/journal-noise.txt` com um regex estendido
(`grep -E`) por linha. Linhas em branco e iniciadas por `#` são ignoradas.

```text
# um regex-E por linha
codeisland\.service: (Failed at step CHDIR|Changing to the requested)
ftdi_sio .*Unable to read latency timer
```
