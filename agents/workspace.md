# workspace — ambientes de código isolados por demanda

Ferramenta de terminal instalada nesta máquina. Isola uma demanda: cria um git
worktree por repositório dentro de uma pasta única, copia os `.env` ignorados
pelo git, instala as dependências, remapeia as portas e abre o editor com todos
os repos juntos. Também sobe, para e mostra o que está rodando em cada demanda.

**Rode o comando `workspace`. Não reimplemente nada disso em bash na sessão.**

## Comandos

| A pessoa pede | Você roda |
|---|---|
| criar ambiente para uma demanda | `workspace <nome> <repo> [<repo>...]` |
| quais ambientes existem | `workspace list` |
| quais repositórios ele enxerga | `workspace repos` |
| abrir a demanda no editor | `workspace open <nome>` |
| o que está de pé | `workspace status [<nome>]` |
| subir os apps | `workspace start <nome> [--only repo,repo]` |
| parar os apps | `workspace stop <nome>` |
| remover a demanda | `workspace down <nome>` |
| checar a instalação | `workspace doctor` |
| o manual completo | `workspace help` |

Nome de repositório é o nome exato da pasta. Se a pessoa não disser quais, rode
`workspace repos` e pergunte — não escolha por ela. Nome que existe em duas
pastas exige o caminho para desempatar (`cobranca/api`).

## Regras

- **Não rode `workspace setup`.** É o único comando interativo: espera resposta
  no terminal e travaria a sessão. Se o `doctor` pedir, repasse o comando para a
  pessoa rodar.
- **`start` sobe os apps de verdade**, com os `.env` de verdade. Credencial de
  provedor no `.env` continua valendo, então caminho de código que manda
  e-mail, SMS ou cobrança manda de verdade. Não rode para "testar".
- **Não rode `npm run dev`, `docker compose up` nem `serverless offline`** por
  conta própria dentro de uma demanda — quem sabe das portas remapeadas é o
  `start`. Log de cada app em `<demanda>/.logs/<repo>.log`.
- **`down` não integra branch.** Remove o worktree e só apaga a branch se ela já
  estiver na ref base. Se recusar por trabalho não integrado, repasse o motivo;
  não force.
- **O `create` demora.** Três repositórios passam de um minuto por causa da
  instalação de dependências. É esperado, não é travamento.
- **O worktree nasce em detached HEAD.** A branch da demanda é criada pela
  pessoa depois, com `git switch -c`.
- **O `start` recusa serverless que não prove ser local**, e não há como forçar.
  Config que declara `prd`/`production` fica de fora: rodar offline nela mexeria
  em tabela, fila e bucket de produção. Se pedirem para contornar, não contorne.

## Como responder

A saída do comando é a resposta: repasse comprimida, sem reescrever em prosa o
que já veio em lista e sem emendar sugestão que não foi pedida. No `start`,
termine com as URLs que o script imprime no bloco `abra:`.

Erro do script já vem com a correção — repasse os dois e pare por aí.
