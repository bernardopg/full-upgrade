# full-upgrade

> Orquestrador modular de upgrade para Arch Linux — atualiza pacman/AUR, Flatpak,
> Docker, toolchains de linguagem, firmware, plugins de editor/shell e roda
> auditorias de saúde (doctor), tudo num único comando com log estruturado.
>
> *Modular Arch Linux upgrade orchestrator — system + AUR + Flatpak + Docker +
> language toolchains + firmware + health audits, in one command.*

![shell](https://img.shields.io/badge/shell-bash-4EAA25?logo=gnu-bash&logoColor=white)
![platform](https://img.shields.io/badge/platform-Arch%20Linux-1793D1?logo=arch-linux&logoColor=white)
![license](https://img.shields.io/badge/license-MIT-blue)

---

## PT-BR

### O que faz
Roda ~69 steps agrupados: preflight (lock, sudo, disco, keyring), snapshot
pré-upgrade, refresh de mirrors, update de pacman/AUR, Flatpak, Docker, npm/pnpm,
pip/pipx/uv/poetry, rust/cargo, go, .NET, gems, ghcup, firmware, Neovim, Hyprland,
limpeza (cache/órfãos/journal) e auditorias **doctor** (reboot pendente, units
falhadas, CVEs, SMART, rede, etc). Cada step tem timeout, log e evento JSONL.

### Instalação
```bash
git clone https://github.com/bernardopg/full-upgrade
cd full-upgrade
./install.sh          # ~/.local/share/full-upgrade + symlink em ~/.local/bin
full-upgrade --help
```

### Uso
```bash
full-upgrade                 # modo full (update + repair + doctor + cleanup)
full-upgrade --mode update   # só update + limpeza
full-upgrade --mode doctor   # só auditorias (read-only)
full-upgrade --dry-run       # simula, não executa
full-upgrade --list-steps    # lista o catálogo
full-upgrade -y              # não-interativo
```

### Configuração
Zero-config funciona. Para personalizar, copie `config.example` para
`~/.config/full-upgrade/config`. Chaves principais:

| Chave | Default | Função |
|-------|---------|--------|
| `ENABLE_CUSTOM_TOOLS` | `0` | Habilita plugins em `steps.d/` |
| `SNAPSHOT_TOOL` | `auto` | `snapper`/`timeshift`/`none` |
| `MIRROR_TOOL` | `auto` | `reflector`/`rate-mirrors`/`none` |
| `MIN_FREE_GIB` | `2` | Espaço mínimo em `/` e `/boot` |
| `FULL_UPGRADE_AUR_IGNORE` | _(vazio)_ | Pacotes AUR a não atualizar |
| `GCLOUD_BIN` etc | _(auto)_ | Override de caminhos |

### Plugins (steps.d/)
Coloque `.sh` em `~/.config/full-upgrade/steps.d/` (ou no repo) definindo funções
de step e ative com `ENABLE_CUSTOM_TOOLS=1`. Exemplos inclusos: Hermes, AdGuard
VPN, GitHub Copilot, DankMaterialShell, Burp Suite.

### Requisitos
- Arch Linux (ou derivado), bash ≥ 4, `pacman`. Opcionais auto-detectados:
  `paru`/`yay`, `flatpak`, `docker`, `reflector`, `snapper`/`timeshift`, etc.

---

## English

### What it does
Runs ~69 grouped steps: preflight (lock, sudo, disk, keyring), pre-upgrade
snapshot, mirror refresh, pacman/AUR update, Flatpak, Docker, language toolchains
(npm/pnpm, pip/pipx/uv/poetry, rust/cargo, go, .NET, gems, ghcup), firmware,
Neovim, Hyprland, cleanup, and **doctor** health audits. Each step has a timeout,
log, and JSONL event.

### Install
```bash
git clone https://github.com/bernardopg/full-upgrade
cd full-upgrade && ./install.sh
full-upgrade --help
```

### Usage
```bash
full-upgrade                 # full mode
full-upgrade --mode doctor   # audits only (read-only)
full-upgrade --dry-run       # simulate
full-upgrade --list-steps    # show catalog
```

### Configuration
Zero-config works. Copy `config.example` to `~/.config/full-upgrade/config` to
customize. See the table above. Output is currently **Portuguese** (bilingual
support planned).

### License
MIT — see [LICENSE](LICENSE).
