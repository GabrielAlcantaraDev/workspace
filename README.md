# workspace

Trabalhar em duas demandas ao mesmo tempo, nos mesmos repositórios, sem uma
atrapalhar a outra.

Ele cria **um git worktree por repositório** dentro de uma pasta só, copia os
`.env` que o git ignora, instala as dependências, remapeia as portas para não
colidir e abre tudo no seu editor. Também sobe, para e mostra o que está
rodando em cada demanda.

```
$ workspace bug-142 api web

  Criando bug-142

    api                  main            :8010
    web                  main            :5183

    abra: code ~/workspaces/bug-142/bug-142.code-workspace
```

Os repositórios continuam onde estavam. O worktree é uma segunda cópia de
trabalho do mesmo clone — nada é baixado de novo, e mexer nele não encosta no
seu checkout principal nem nas outras demandas.

## Instalação

```bash
curl -fsSL https://raw.githubusercontent.com/GabrielAlcantaraDev/workspace/main/install.sh | bash
```

> **Instalando por IA?** Mande o link deste repositório para o seu agente
> (Claude Code, Codex, Cursor…) e peça para instalar. As instruções que ele
> precisa seguir estão em [AGENTS.md](AGENTS.md) — inclusive as duas coisas que
> ele **não** deve fazer.

Depois:

```bash
workspace doctor
```

O `doctor` confere a máquina e diz o que falta, com o comando de cada coisa.
Se ele pedir, rode `workspace setup` para dizer onde ficam seus repositórios.

Atualizar depois: `workspace update`.

Prefere ler antes de rodar? O instalador é um arquivo só, [install.sh](install.sh).

### O que precisa ter na máquina

| | |
|---|---|
| **bash ≥ 4.4** | O macOS traz o 3.2. `brew install bash` resolve. |
| **git** | Qualquer versão com `git worktree` (2.5+). |
| docker | Opcional. Só para repo que sobe por `docker compose`, e para o `down` limpar dado que o container escreveu como root. |
| xprop | Opcional, Linux/X11. É o que deixa o `down` fechar a janela do editor. |

Nada mais. O resto é bash puro.

### No Windows, use o WSL

```powershell
wsl --install        # PowerShell como administrador, uma vez só
```

Abra o Ubuntu que ele instalar e rode a instalação **lá dentro**. Do WSL para
frente é tudo igual ao Linux.

**Git Bash e Cygwin não servem, e a ferramenta recusa instalar neles.** Não é
implicância: quase tudo aqui atravessa a fronteira do bash e cai num programa
do Windows. O `.code-workspace` vai para o VSCode, o bind mount vai para o
Docker — e `/c/Users/...` não significa nada para nenhum dos dois. Instalar
mesmo assim daria uma ferramenta que só falha depois do worktree criado.

Mantenha também **os repositórios dentro do WSL** (`~/dev`, e não
`/mnt/c/Users/...`). Repo no disco do Windows acessado pelo WSL fica lento e dá
problema de permissão no git. O `doctor` avisa se detectar isso.

## Comandos

```
workspace <nome> <repo> [<repo>...]   cria a demanda
workspace list                        as demandas que existem
workspace repos                       os repositórios que ele achou
workspace open <nome>                 abre no editor
workspace use <nome>                  briefing da demanda (e fixa a aba, no Claude Code)
workspace status [<nome>]             o que está de pé
workspace start <nome>                sobe os apps
workspace stop <nome>                 para o que subiu
workspace down <nome>                 para, remove e fecha a janela
workspace setup                       onde ficam seus repositórios
workspace doctor                      checa a máquina
workspace update                      baixa a versão nova
workspace help                        o manual completo
```

`workspace help` é o manual de verdade — este README só cobre a instalação.

## Como ele decide as coisas

**Onde estão seus repos.** Procura em `~/dev`, `~/code`, `~/projects`, `~/src`,
`~/work`, `~/repos` e `~/git`. Achando uma só, usa e guarda. Achando várias ou
nenhuma, ele **pergunta** em vez de adivinhar — `workspace setup`. Para mandar
por fora: `export WORKSPACE_ROOTS=/onde/estao`.

**Portas.** Cada demanda ganha um deslocamento (+10, +20) aplicado ao `PORT` dos
`.env` e às URLs `localhost:<porta>` entre os apps daquela demanda. É o que
permite subir duas demandas ao mesmo tempo. `--no-ports` desliga.

**Subir os apps.** `workspace start` sobe cada repo do jeito que ele é
(serverless offline, vite, watcher, container do compose), **espera a porta
aceitar conexão** e só então diz que subiu. App que morre por env faltando não
é reportado como sucesso: ele mostra o fim do log. Log em `<demanda>/.logs/`.

**Serverless.** Só sobe offline se a config provar que é local: `stage: local`
**e** a AWS apontada para a máquina (`serverless-localstack` ou endpoint em
`127.0.0.1`). Config que declara `prd`/`production` é recusada, e não há flag
para forçar — rodar offline contra ela mexeria em tabela, fila e bucket de
produção de verdade.

**Derrubar.** `workspace down` para os processos, fecha a janela do editor e
remove os worktrees. Ele **não** integra branch: se houver trabalho que não
está na ref base, ele recusa e diz o que falta. Quem integra é você.

## Configuração

Fica em `~/.config/workspace/config`, e o `setup` escreve por você.
Toda variável de ambiente ganha da config.

| Variável | Default |
|---|---|
| `WORKSPACE_ROOTS` | auto-detectado — raízes de busca, separadas por `:` |
| `WORKSPACES_ROOT` | `~/workspaces` — onde as demandas são criadas |
| `WORKSPACE_EDITOR` | auto-detectado entre `code`, `cursor`, `kiro`, `windsurf`, `codium`, `zed`, `webstorm`, `idea`, `subl`. `none` só imprime o caminho |
| `WORKSPACE_ENV_FILES` | `.env:.env.local:.env.development:.env.development.local` |
| `WORKSPACE_IGNORE` | `*_copy*` — glob ignorado na busca |
| `WORKSPACE_MAXDEPTH` | `4` |
| `WORKSPACE_WAIT` | `60` — segundos esperando a porta abrir (`_SERVERLESS` 180, `_CONTAINER` 20) |
| `WORKSPACE_CLOSE_EDITOR` | `1` — `0` faz o `down` deixar a janela aberta |
| `WORKSPACE_PIN` | `1` — `0` desliga a fixação de aba do Claude Code |

## Editores

| Editor | O que recebe |
|---|---|
| VSCode, Cursor, Kiro, Windsurf, VSCodium | o `.code-workspace` — janela com todos os repos, na cor da demanda |
| Zed | os caminhos dos repos |
| JetBrains, Sublime, outros | a pasta da demanda, que já contém os repos |

Escolhe sozinho o primeiro que achar no PATH, e pergunta uma vez quando há mais
de um. Trocar depois: `workspace editor <comando>`.

## Claude Code (opcional)

O instalador oferece instalar a skill. Com ela, `/workspace` no chat faz tudo
acima, e `/workspace use <demanda>` **prende aquela aba de chat na demanda**:
um hook passa a negar escrita fora dela, então o agente não mexe no repositório
errado quando você tem quatro conversas abertas.

Quem não usa Claude Code ignora essa parte — o comando de terminal é o mesmo, e
não depende dela em nada.

## Licença

MIT.
