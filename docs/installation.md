# Instalação e atualização

## Requisitos

| Requisito | Observação |
| --- | --- |
| Arch Linux ou derivado | O fluxo assume `pacman` e as convenções do Arch. |
| Bash 4.3+ | Usa arrays, subscritos negativos e outros recursos modernos de Bash. |
| `sudo` (ou `doas`/`run0`/`sudo-rs`) | Necessário para os steps de sistema. Sem elevação, esses steps viram `skip`. |

Todo o resto é opcional e detectado automaticamente. Ferramenta ausente vira
`skip` com o motivo, e o restante do fluxo continua:

```text
paru, yay, pikaur, doas, run0, sudo-rs, pacman-contrib, pacdiff, reflector,
rate-mirrors, snapper, timeshift, informant, arch-audit, flatpak, snap, docker,
fwupdmgr, bootctl, npm, corepack, pnpm, bun, deno, python, pipx, uv, uvx, poetry,
rustup, cargo, cargo-install-update, cargo-audit, go, dotnet, gem, ghcup,
arduino-cli, gcloud, claude, codex, copilot, gemini, qwen, cline, opencode,
ollama, kimi, hermes, pi, nvim, code, cursor, codium, hyprpm, needrestart,
checkservices, smartctl, nvme, notify-send, yad, python-gobject,
libayatana-appindicator, xdg-terminal-exec, vulkaninfo, glxinfo
```

## Via AUR (recomendado)

```bash
paru -S full-upgrade    # ou: yay -S full-upgrade
```

O pacote instala:

| Caminho | Conteúdo |
| --- | --- |
| `/usr/bin/full-upgrade` | Executável único (standalone). |
| `/usr/share/full-upgrade/config.example` | Exemplo de configuração. |
| `/usr/lib/systemd/user/full-upgrade-tray.service` | Unit systemd do usuário para o [systray](tray.md). |
| `/usr/share/icons/hicolor/scalable/apps/` | Ícones do app, do painel e do menu. |
| `/usr/share/{licenses,doc}/full-upgrade/` | Licença, README, CHANGELOG e esta documentação. |

Para começar com um config próprio:

```bash
mkdir -p ~/.config/full-upgrade
cp /usr/share/full-upgrade/config.example ~/.config/full-upgrade/config
```

## Via script de instalação

Funciona em qualquer distro com Bash 4.3+:

```bash
git clone https://github.com/bernardopg/full-upgrade
cd full-upgrade
./install.sh
full-upgrade --help
```

| Caminho | Função |
| --- | --- |
| `~/.local/share/full-upgrade` | Instalação modular (`full-upgrade.sh`, `lib/`, `steps.d/`, `config.example`). |
| `~/.local/bin/full-upgrade` | Symlink para o executável. Garanta que `~/.local/bin` esteja no `PATH`. |
| `~/.config/full-upgrade/config` | Config inicial criado a partir do exemplo, sem sobrescrever um existente. |

## Standalone

Um arquivo único, com todas as bibliotecas embutidas:

```bash
./build.sh
./dist/full-upgrade-standalone.sh --help
```

Cada release publica o standalone com o `.sha256` e o bundle Sigstore da
proveniência de build. Para conferir:

```bash
sha256sum -c full-upgrade-standalone.sh.sha256
gh attestation verify full-upgrade-standalone.sh \
  --bundle full-upgrade-standalone.sh.sigstore.json --repo bernardopg/full-upgrade
```

## Atualização do próprio full-upgrade

```bash
full-upgrade --version      # versão instalada
full-upgrade --update       # baixa e instala a última release (pede confirmação)
full-upgrade --update -y    # sem perguntar
```

No fluxo normal, o step **Checar atualização do full-upgrade** só avisa quando
há versão nova; ele não baixa nada. Instalações pelo AUR devem ser atualizadas
pelo helper (`paru -S full-upgrade`).

| Chave | Default | Descrição |
| --- | --- | --- |
| `FULL_UPGRADE_REPO` | `bernardopg/full-upgrade` | Repositório `owner/repo` no GitHub. |
| `FULL_UPGRADE_UPDATE_CHANNEL` | `release` | `release` (última tag) ou `main` (bleeding edge). |

No canal `release`, o `--update` baixa o standalone e o `.sha256`, confere o
SHA-256 e só então instala em `~/.local/bin/full-upgrade`, guardando o anterior
em `full-upgrade.bak`. Checksum divergente aborta antes de qualquer execução.
Requer `curl` e `sha256sum`/`shasum`. O canal `main` usa o tarball-fonte com
`install.sh` e avisa que, nesse caso, a integridade depende só do TLS.

Depois de atualizar, reinicie o applet para carregar o código novo:
`full-upgrade --tray --restart`.
