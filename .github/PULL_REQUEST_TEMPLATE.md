<!-- markdownlint-disable MD041 -->
## Descrição

<!-- O que muda e por quê. -->

## Tipo

- [ ] Correção de bug
- [ ] Novo step / funcionalidade
- [ ] Documentação
- [ ] Refatoração (sem mudança de comportamento)

## Checklist

- [ ] `bash -n` passa em todos os arquivos alterados
- [ ] `shellcheck -S warning -x` limpo
- [ ] `./full-upgrade.sh --dry-run --mode full` roda sem erro
- [ ] `./build.sh && ./dist/full-upgrade-standalone.sh --list-steps` ok (se mudança estrutural)
- [ ] Novo/alterado step: catálogo (`lib/catalog.sh`) e dispatch (`lib/main.sh`) em sincronia
- [ ] `CHANGELOG.md` atualizado (se o comportamento mudou)
- [ ] Textos ao usuário em PT-BR
