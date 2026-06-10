# Distribuição via AUR

Este diretório contém o empacotamento do `full-upgrade` para o
[AUR](https://aur.archlinux.org/) (Arch User Repository).

- `PKGBUILD` — receita de build do pacote **source** `full-upgrade`. Baixa o
  tarball da tag publicada no GitHub, roda `build.sh` e instala o executável
  único (`dist/full-upgrade-standalone.sh`) em `/usr/bin/full-upgrade`.
- `.SRCINFO` — metadados gerados a partir do `PKGBUILD`
  (`makepkg --printsrcinfo`). Mantido em sincronia.

## Publicação automática

O job **`publish-aur`** em `.github/workflows/release.yml` publica no AUR a cada
release (push de tag `v*`). Fluxo:

1. Copia o `PKGBUILD` deste diretório e fixa `pkgver` na versão da tag.
2. Baixa o tarball da tag recém-publicada e calcula o `sha256sums` real
   (substitui o placeholder `SKIP`).
3. Usa [`KSXGitHub/github-actions-deploy-aur`](https://github.com/KSXGitHub/github-actions-deploy-aur)
   (pinada por commit SHA) para validar o `PKGBUILD`, gerar o `.SRCINFO` e
   fazer push para o repositório Git do AUR.

### Secrets necessários no GitHub

Configure em **Settings → Secrets and variables → Actions** do repositório:

| Secret | Conteúdo |
| --- | --- |
| `AUR_USERNAME` | Nome de usuário/commit para o push no AUR (ex.: `bernardopg`). |
| `AUR_EMAIL` | E-mail do mantenedor usado no commit. |
| `AUR_SSH_PRIVATE_KEY` | Chave SSH **privada** dedicada cujo par público está cadastrado no perfil do AUR. |

### Gerar a chave SSH do AUR (uma vez)

```bash
ssh-keygen -t ed25519 -C "aur-full-upgrade" -f ~/.ssh/aur_full_upgrade
# Cadastre a PÚBLICA (~/.ssh/aur_full_upgrade.pub) em:
#   https://aur.archlinux.org/  ->  My Account  ->  SSH Public Key
# Cole a PRIVADA (conteúdo de ~/.ssh/aur_full_upgrade) no secret AUR_SSH_PRIVATE_KEY.
```

### Primeira publicação (bootstrap manual)

O AUR exige que o repositório do pacote exista. Para o primeiro envio:

```bash
git clone ssh://aur@aur.archlinux.org/full-upgrade.git
cd full-upgrade
cp /caminho/para/PKGBUILD .
# ajuste pkgver e rode:
updpkgsums              # preenche sha256sums
makepkg --printsrcinfo > .SRCINFO
makepkg -si             # testa o build localmente (opcional)
git add PKGBUILD .SRCINFO
git commit -m "Versão inicial"
git push
```

Depois disso, as releases seguintes são publicadas automaticamente pelo workflow.

## Testar o PKGBUILD localmente

```bash
cd packaging/aur
updpkgsums                              # atualiza sha256sums a partir do source
makepkg --printsrcinfo > .SRCINFO       # regenera metadados
namcap PKGBUILD                         # lint (pacote pacman-contrib/namcap)
makepkg -si                             # build + instala
```
