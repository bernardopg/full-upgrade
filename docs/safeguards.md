# Salvaguardas

Decisões de projeto que existem porque uma falha real aconteceu. Cada item diz
o que o full-upgrade faz e por quê.

## Princípios

- **Condição permanente nunca vira `fail`.** Upstream removido, credencial
  revogada ou layout não suportado se repetiriam em todo run, sem nada que a
  ferramenta pudesse fazer. Isso é pendência do usuário: `todo` com remediação.
- **Rede instável não derruba o run.** Erros de DNS e conectividade viram
  `warn`, e steps com tag `network` esperam a rede voltar em vez de travar até o
  timeout.
- **Atalho de "nada mudou" precisa provar que nada mudou.** Os pré-filtros (Go,
  plugins do Claude, agent skills, repair do Flatpak) só pulam o trabalho quando
  conseguem demonstrar que não há mudança; qualquer dúvida roda o update real.
- **Serviços que carregam a sessão nunca são reiniciados sozinhos.** Display
  managers e a pilha de rede (`NetworkManager`, `wpa_supplicant`,
  `systemd-resolved`) ficam fora do `--restart-services`; reiniciá-los no meio do
  run derrubava a sessão e o SSH.

## Pacotes e sistema

- **Órfãos recursivos:** `pacman -Qdtq` é repetido após cada remoção, para pegar
  dependências que só viram órfãs depois (até `ORPHAN_CLEANUP_MAX_ROUNDS`).
- **AUR com falha de compilação:** um pacote que falhou no `build()` não é
  recompilado de novo no mesmo run; erro de compilação é determinístico.
- **Mirrorlist:** se `reflector`/`rate-mirrors` falha, o backup só é restaurado
  se tiver uma linha `Server =` ativa.
- **Retenção de snapshots:** só são removidos snapshots com a descrição
  `full-upgrade pré-upgrade`, mantendo os `SNAPSHOT_KEEP` mais recentes. Falha de
  leitura do Timeshift vira `warn`, nunca "lista vazia".
- **Coredumps:** a limpeza remove só dumps mais antigos que `COREDUMP_KEEP_DAYS`.
  O Doctor lê os metadados do journal, então um crash ativo continua `todo`.
- **Temp dirs do Codex:** clones `git-*` e stagings abandonados em
  `~/.codex/.tmp` (acumulavam dezenas de GiB) são removidos, preservando os mais
  novos que `CODEX_TMP_KEEP_DAYS` para não quebrar um refresh em andamento.
- **Verificação final por gerenciador:** depois dos updates, `pacman`/AUR, npm,
  pnpm, cargo, gems e Flatpak são consultados de novo. Sobrou pendência, vira
  `todo` com o comando de remediação.

## Backup em nuvem do Timeshift

`TIMESHIFT_CLOUD_BACKUP=1` replica o snapshot mais recente (`@` + `@home`) num
repositório Restic criptografado via rclone.

- Falha na nuvem vira aviso e nunca remove a cópia local.
- Cooldown: depois de um envio bem-sucedido, os próximos runs pulam o step
  por `TIMESHIFT_CLOUD_COOLDOWN_DAYS` dias (padrão 7; `0` desliga). O carimbo
  fica em `~/.local/state/full-upgrade/timeshift-cloud-last-ok`; apague-o para
  forçar o envio no próximo run. Carimbo ausente, ilegível ou no futuro conta
  como "enviar": o atalho nunca pula na dúvida.
- O catálogo reserva até 48 horas para a primeira réplica; o lock é mantido
  durante o envio, então não rode outro full-upgrade em paralelo.
- A leitura dos snapshots (root:root 0700) usa privilégio administrativo, sem
  abrir permissões. Snapshot sem `@` ou `@home` acessível é recusado.
- Por unidade systemd do usuário, preserve o PATH com `--setenv="PATH=$PATH"`.

## Plugins clonados (Zsh, DMS, OBS)

Os três steps usam os mesmos helpers de git, que desarmam armadilhas reais:

| Armadilha | O que acontecia | Proteção |
| --- | --- | --- |
| Clone raso | `fetch --depth=1` cria um graft point a cada run e o fast-forward fica impossível mesmo com árvore limpa. | Fetch completo, sempre com `--prune`. |
| `pull --ff-only` com rebase | Sob `pull.rebase=true` + `autostash`, um conflito deixa marcadores no código **saindo com 0**. | Pull forçado sem rebase e conferência de arquivos unmerged. |
| Conflito pendente | O git recusa `fetch`/`pull`/`stash` e o step falhava em todo run. | Detectado antes e convertido em `todo` com remediação. |
| Branch apagado no remoto | A ref morta sobrevivia e o plugin "atualizava" em todo run. | `--prune` e verificação de que o upstream existe. |
| Upstream removido | "Repository not found" em todo run, para sempre. | `todo` com remediação, não `fail`. |
| Clone em desenvolvimento | Um realinhamento chegou a mover um branch de trabalho para `origin/main`. | Clone com trabalho local nunca é realinhado. |

Plugin com histórico reescrito upstream e árvore limpa é realinhado em
`origin/HEAD`, com o HEAD anterior guardado em
`refs/full-upgrade/pre-realign/<timestamp>`.

## Ferramentas específicas

- **Docker:** a checagem do daemon usa timeout curto (`DOCKER_INFO_TIMEOUT_S`).
  Imagens `local/` e `localhost/` são tratadas como builds locais.
- **OWASP ZAP:** “Check for updates call failed” (que sai com 0) vira `warn`, e o
  Java do ZAP prefere IPv6 quando há rota.
- **Node/Electron:** updater com `ETIMEDOUT` tenta uma segunda vez sem a
  auto-seleção de família IPv6/IPv4.
- **TokenSave:** sem acesso ao GitHub pelo updater, a API de releases é
  consultada só para comparar versões; esse caminho nunca instala nada.
- **Poetry:** quando o Poetry fixa `poetry-core`, o update de `pip --user` o
  ignora, evitando o ping-pong de versão entre os dois steps.
- **Plugins do Claude Code:** o CLI é chamado sem os hooks de sessão do usuário
  (cada chamada disparava sync de dotfiles e `git push`), com limite por plugin;
  o que não couber no tempo do step fica para o próximo run.
- **Btrfs:** `BTRFS_DEVICE_STATS_ACK_SHA256` reconhece um histórico revisado de
  erros por device; qualquer mudança volta a alertar, e scrub incompleto nunca é
  dispensado.
