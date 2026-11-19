# Steps e cobertura

Tudo o que o full-upgrade faz é um **step**: uma unidade com nome, categoria,
tags, efeito, timeout e dependências, declarada no catálogo. `--list-steps`
mostra o catálogo inteiro e `--explain-step "NOME"` descreve um step.

```text
nome | categoria | tags | efeito | timeout | dependências | função | descrição
```

```text
Doctor: saúde de rede
Categoria: doctor
Tags: network
Efeito: read
Timeout: 30s
Função: doctor_network_health
Descrição: Verifica DNS e conectividade HTTPS para mirrors Arch.
```

- **Efeito** é `read` ou `mutating`. Step `mutating` nunca pertence à categoria
  `doctor`: as auto-remediações vivem em `autofix`, o que mantém o
  `--mode doctor` read-only por construção.
- **Timeout** é o limite do step. Estourou, vira `warn` e o run continua.
- **Dependências** ausentes viram `skip` com o motivo `cmd-ausente: X`.
- A tag **`network`** faz o step esperar a conectividade antes de rodar, em vez
  de travar até o timeout com a rede fora.

## Categorias

Cada step pertence a **exatamente uma** categoria (conjunto fechado, validado
por teste). As tags são eixos transversais (`network`, `slow`, `sudo`, nome da
ferramenta…).

| Categoria | O que `--only <categoria>` executa |
| --- | --- |
| `core` | Preflight obrigatório: lock, sudo, espaço em disco, keyring. Sempre roda. |
| `backup` | Backup de configs de `/etc`, snapshot pré-upgrade e réplica do snapshot em nuvem. |
| `packages` | pacman/AUR, mirrors, notícias do Arch, `.pacnew`, Flatpak, Snap, Docker e bases de arquivos (`pacman -F`, pkgfile). |
| `repair` | Reparos idempotentes de estado quebrado (lock stale, GnuPG, shadowing, units obsoletas). |
| `security` | Wireshark, Burp Suite, Snyk, OWASP ZAP, gitleaks, trufflehog, assinaturas do ClamAV, templates do nuclei, Exploit-DB e rkhunter. |
| `firmware` | `fwupd` e `systemd-boot`. |
| `lang-js` | Node.js e nvm, npm (todos os prefixos), corepack, pnpm, Bun, Deno, vite-plus. |
| `lang-py` | pip `--user`, pipx, uv (self, Python e ferramentas), Poetry. |
| `lang-rust` | rustup, binários cargo e auditoria de CVEs. |
| `lang-other` | Arduino, Go, .NET, Google Cloud SDK, gems, ghcup, ferramentas do mise, juliaup/elan/coursier/SDKMAN!, Composer global e ESP-IDF (checagem). |
| `ai` | CLIs de IA, plugins do Claude Code e do Codex, agent skills e servidores MCP. |
| `tools` | Utilitários fora de gerenciador: GitKraken CLI, purple, Android CLI, Herdr, cloudflared, CLIProxyAPI, extensões do `gh`, OBS, Proton-GE, Spicetify, krew, plugins do Helm, AppImages, Nerd Fonts, plugins do KiCad (checagem) e arkenfox. |
| `ide` | Orca, Antigravity e extensões da família VSCode. |
| `editor` | Neovim (Lazy, Mason e parsers do nvim-treesitter). |
| `shell` | Oh My Zsh, plugins Zsh (customizados, clones avulsos, zinit/antidote/sheldon), tmux (tpm), fish (fisher), Yazi, Hyprland (`hyprpm`) e cache do tldr. |
| `cleanup` | Caches, snapshots antigos, órfãos, journal, coredumps e relatórios. |
| `autofix` | Auto-remediações mutáveis, sempre atrás de opt-in e/ou confirmação. |
| `doctor` | Auditorias estritamente read-only (ver [Doctor](doctor.md)). |
| `final` | Conferências de pós-condição e aviso de versão nova. Sempre roda. |

Identidades antigas seguem válidas como tag: `--only lang` pega as quatro
categorias `lang-*`, e `--skip-category pacman|flatpak|snap|docker` filtra
dentro de `packages`.

## O que é atualizado

| Domínio | Cobertura |
| --- | --- |
| Preflight | Lock anti-concorrência, sudo, espaço em `/` e `/boot`, `archlinux-keyring`, backup de configs críticas de `/etc` (`tar.zst` com rotação). |
| Snapshot e mirrors | `snapper`/`timeshift` em btrfs com checagem de espaço; `reflector`/`rate-mirrors` com backup validado da mirrorlist. |
| Sistema | `pacman`, AUR (`paru`/`yay`/`pikaur`), reparos de lock, GnuPG e conflitos locais, órfãos recursivos, `.pacnew/.pacsave`. |
| Apps e containers | Flatpak, Snap e pull de imagens Docker em paralelo, com aviso de container rodando imagem antiga. |
| Firmware e boot | `fwupdmgr` e `bootctl`. |
| JavaScript | npm (prefixo ativo, `~/.npm-global` e o do Node em uso), globais npm e pnpm, corepack, Bun e Deno (pulados quando vêm do pacman). |
| Python | pip `--user`, pipx, uv, Python gerenciado pelo uv e Poetry. Ferramenta uv presa por restrição do receipt vira `todo`. |
| Rust | `rustup`, `cargo-install-update`, auditoria com `cargo-audit` e remediação opcional de CVEs (`AUTO_FIX_RUST_CVES`). |
| Outras linguagens | Go (só reinstala o que mudou), .NET, Ruby gems, ghcup, Arduino CLI e ferramentas do mise (dentro do intervalo do config). |
| Shell, editor e IDE | Oh My Zsh, plugins Zsh (customizados e clones git avulsos, como `~/.local/share/zsh-defer`), Neovim Lazy/Mason, `hyprpm`, extensões VSCode/Cursor/Codium e cache do tldr. |
| IA | Claude Code (CLI e plugins), Codex (plugins), Copilot, opencode, kilo, mimo, pi, Ollama, Hermes, TokenSave, droid, Kiro, grok, kimchi, muse, qodo, ori, pool, agent skills e servidores MCP uvx. |
| Apps manuais | Programas fora de gerenciador com step dedicado: droid, Snyk CLI e GitKraken CLI (sha256 conferido), OWASP ZAP (core e add-ons), vite-plus, Herdr, cloudflared, CLIProxyAPI (sha256, troca atômica e rollback do serviço). `Doctor: apps manuais` aponta o que ainda não tem step. |
| Componentes sem dono | O pacote instala, mas não mantém: extensões do `gh`, assinaturas do ClamAV (`freshclam`, só sem unit do freshclam ativa), ferramentas do mise, modelos do Ollama (opt-in `OLLAMA_MODELS_UPDATE`), bases `pacman -F`/pkgfile, templates do nuclei, Exploit-DB em clone git, bases e propriedades do rkhunter, plugins do krew, Helm, tmux, fish e dos gerenciadores Zsh, parsers do nvim-treesitter, Composer global e toolchains de juliaup/elan/coursier/SDKMAN!. |
| Baixados à mão | Proton-GE (instala ao lado, `PROTON_GE_KEEP`), AppImages com zsync, Nerd Fonts (`NERD_FONTS_DIR`), arkenfox e Spicetify (reaplica depois do update do Spotify). |
| Só checagem (`todo`) | Plugins do KiCad com versão nova no PCM e patch novo do ESP-IDF na série instalada (só a maior versão instalada de cada série `vX.Y` conta; patches antigos lado a lado são apenas listados para `eim remove`): atualizar por fora quebraria a contabilidade da ferramenta dona. |

## Integrações empacotadas

`steps.d/` reúne integrações com ferramentas opcionais. Elas fazem parte do
repositório (e do binário standalone/AUR) e rodam **por presença da
ferramenta**: sem a ferramenta, o step vira `skip`.

| Arquivo | Hook | Roda quando |
| --- | --- | --- |
| `steps.d/10-hermes.sh` | `update_hermes` | `hermes` no PATH |
| `steps.d/30-copilot.sh` | `update_copilot_cli` | `copilot` no PATH ou `COPILOT_BIN` |
| `steps.d/40-dms.sh` | `update_dms_plugins` | `DMS_PLUGINS_DIR` existe |
| `steps.d/60-openclaw.sh` | `update_openclaw` | `openclaw` no PATH ou `OPENCLAW_BIN` |
| `steps.d/70-rtk.sh` | `update_rtk` | `rtk` no PATH ou `RTK_BIN` |
| `steps.d/71-tokensave.sh` | `update_tokensave` | `tokensave` no PATH |
| `steps.d/80-orca.sh` | `ensure_orca_ide` | Orca instalado; instalação nova só com `ENABLE_CUSTOM_TOOLS=1` |
| `steps.d/81-antigravity.sh` | `ensure_antigravity` | Antigravity instalado |
| `steps.d/85-obs.sh` | `update_obs_plugins` | Plugins do OBS presentes |

Exigem `ENABLE_CUSTOM_TOOLS=1`, porque **instalam** pacote em vez de só
atualizar:

| Arquivo | Hook |
| --- | --- |
| `steps.d/50-wireshark.sh` | `ensure_wireshark` e permissões de captura |
| `steps.d/51-burp-suite.sh` | `ensure_burpsuite`, fallback PortSwigger e atalhos antigos |

Uma integração pode ser desligada por ID estável, sem depender do nome do step:
`FULL_UPGRADE_DISABLED_INTEGRATIONS="openclaw,coderabbit,artcraft,cua-driver"`.

### Suíte Artcraft

`--only artcraft` atualiza (em `full`/`update`) e audita (em `doctor`) os apps
Artcraft instalados a partir de releases locais em `ARTCRAFT_DIR` (padrão
`~/development/artcraft`).

- Baixa só versões estáveis mais novas dos apps já instalados, confere SHA-256
  e a inicialização MCP, e atualiza binários GUI/CLI, ícones, `.desktop`, MIME
  e inventários. Os caminhos usados pelos clientes MCP não mudam.
- Falha de download, integridade, MCP ou integração mantém aquele app na versão
  em uso, sem impedir os demais.
- Depois dos updates, cada app guarda só a versão apontada por `current`. Só sai
  o que tem nome e layout de pacote do app. O clone original e qualquer clone de
  release com alteração local nunca são apagados.
- `check` e `doctor` não apagam nada. A bandeja mostra contagem e lista de
  releases Artcraft.

## Plugins do usuário

Com `ENABLE_CUSTOM_TOOLS=1`, arquivos `.sh` em `~/.config/full-upgrade/steps.d/`
também são carregados. A última definição de função vence, então dá para
sobrescrever uma integração empacotada. Um step totalmente novo exige a função,
a linha no catálogo e o dispatch em `lib/main.sh` (ver
[Desenvolvimento](development.md)).
