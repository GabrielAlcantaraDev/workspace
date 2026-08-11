---
name: workspace
description: Provisiona ambientes de código isolados para trabalhar em várias demandas ao mesmo tempo nos mesmos repositórios, e sobe os apps de cada um. Cria um git worktree por repositório numa pasta única, copia os arquivos de env ignorados pelo git, instala as dependências, remapeia portas e abre o editor com todos os repos juntos (VSCode, Cursor, Kiro, Zed, JetBrains) — ou, sem abrir janela nenhuma, fixa a aba de chat atual numa demanda. Também sobe, para e mostra o que está rodando em cada workspace. Use quando a pessoa pedir um workspace, um ambiente para desenvolver, quiser mexer em duas demandas em paralelo, quiser que esta aba passe a trabalhar numa demanda específica, pedir para listar, reabrir ou derrubar workspaces, ou pedir para subir, parar ou ver o que está de pé.
---

# workspace

Isolamento de código, e o ciclo de vida do que roda dentro dele. Toda a mecânica está em `workspace.sh`, ao lado deste arquivo — **rode o script, não reimplemente nada em bash na sessão.**

## Invocação

| A pessoa digita | Você roda |
|---|---|
| `/workspace <repo> [<repo>...]` | `workspace.sh create <repos>` |
| `/workspace <nome> <repo> [<repo>...]` | `workspace.sh create --name <nome> <repos>` |
| `/workspace <nome>` | caixa de seleção (abaixo), depois `create --name <nome>` |
| `/workspace` | caixa de seleção, depois `create` sem `--name` |
| `/workspace list` | `workspace.sh list` |
| `/workspace repos` | `workspace.sh repos` — repasse o catálogo como está |
| `/workspace open <nome> [<nome>...]` | `workspace.sh open <nomes>` — vai para a demanda em janela dedicada |
| `/workspace use <nome>` | `workspace.sh use <nome>` — fixa **esta aba de chat** na demanda |
| `/workspace use` | caixa de seleção (abaixo), depois `use <nome>` |
| `/workspace use none` | `workspace.sh use none` — solta a aba |
| `/workspace note` | grave o caderno da demanda fixada (seção abaixo) — não há comando no script |
| `/workspace status [<nome>]` | `workspace.sh status [<nome>]` |
| `/workspace start <nome>` | `workspace.sh start <nome> [--only repo,repo] [--force]` |
| `/workspace stop <nome> [<nome>...]` | `workspace.sh stop <nomes>` |
| `/workspace down <nome> [<nome>...] [--force]` | `workspace.sh down <nomes> [--force] [--keep-editor]` |
| `/workspace editor` | caixa de seleção do editor (seção abaixo) |
| `/workspace doctor` | `workspace.sh doctor` — repasse o relatório como está |
| `/workspace setup` | **não rode** — é interativo e só funciona no terminal da pessoa. Diga isso e repasse o comando |
| `/workspace update` | `workspace.sh update` — uma linha com a versão antes e depois |
| `/workspace help` | `workspace.sh help` — repasse a saída como está, é o manual |

`list`, `repos`, `open`, `use`, `note`, `status`, `start`, `stop`, `down`, `editor`, `prune`, `setup`, `doctor`, `update` e `help` são **palavras reservadas**: como primeiro argumento são sempre o verbo, nunca nome de workspace.

`open`, `down`, `stop` e `baseline` aceitam vários nomes; `start` sobe um por vez (para escolher repos é `--only`). Nome errado aborta antes de mexer em qualquer um; no `down`, workspace que recusa por trabalho não integrado não impede os outros de caírem, e o comando termina com erro apontando quem travou.

Vírgula é separador e o script já trata. `create` de três repositórios passa de um minuto por causa da instalação de dependências — é esperado, não é travamento.

## Caixa de seleção

Quando a pessoa não nomear os repositórios:

1. `workspace.sh top 4` → uma linha por repo: `identificador ⇥ pasta ⇥ commits`.
2. Monte **uma** pergunta `AskUserQuestion` com `multiSelect: true`, as 4 como opções: `label` = o identificador, `description` = **só a pasta** (não mostre contagem de commits). O "Other" aparece sozinho e cobre os outros repositórios.
3. Chame o `create` com os identificadores marcados, **verbatim** — já vêm com a pasta quando o nome é ambíguo.

Se a pessoa quiser ver todos, `workspace.sh repos` imprime o catálogo agrupado.

**Nunca mostre a caixa quando a pessoa já disse os repositórios** — nesse caso vá direto ao `create`, que resolve em um turno.

## Dois modos: janela e aba

A mesma demanda pode ser trabalhada de duas formas, e a pessoa escolhe na hora:

- **Janela dedicada** (`create`, `open`): o editor abre uma janela com os repos daquele workspace, na cor dele. É o modo de navegar — Ctrl+P, busca e Source Control ficam restritos àquela demanda.
- **Aba fixada** (`use`): nenhuma janela abre. A aba de chat onde o comando foi dado passa a trabalhar só naquela demanda, e o arquivo abre por link quando precisa. É o modo leve, para quando não se quer sair da janela em que já se está.

Os dois convivem. Quatro demandas podem estar provisionadas com uma em janela e três em abas.

**`/workspace use` sem nome:** rode `workspace.sh use` (imprime os workspaces), monte uma pergunta `AskUserQuestion` single select com os nomes (`label` = o nome, `description` = os repos daquele workspace) e chame `use <nome>` com o escolhido.

## Fixação da aba

Depois de um `use <nome>` bem-sucedido, **esta aba é daquela demanda** até um `use` de outra ou um `use none`:

- Todo caminho que você resolver é dentro de `$WORKSPACES_ROOT/<nome>/`. Pedido ambíguo ("arruma o teste que quebrou") é sobre os worktrees dela, não sobre o checkout principal.
- `start`, `stop`, `status` e `down` sem nome são os dela.
- Se o pedido cair fora — outra demanda, o clone principal — **pergunte antes**, não decida sozinho que a pessoa quis dizer outra coisa.

**A trava é do hook, não sua.** O `pin-hook.sh` grava o pino (é ele que enxerga o `session_id`, o script não) e nega `Write`/`Edit` fora da demanda, mais comando de shell que toque outro workspace. Duas consequências práticas:

- **Não anuncie que a aba está fixada antes de o hook confirmar.** A confirmação chega como contexto depois do comando. Se não chegou, o pino não foi gravado, e dizer que foi é pior do que não ter trava nenhuma.
- **Recusa do hook não é bug para diagnosticar.** Repasse o motivo e a saída que ele já sugere (`/workspace use none`). Não tente outro caminho para escrever o mesmo arquivo.

Aba sem `use` não é afetada em nada: sem pino, o hook sai antes de olhar qualquer coisa.

## Caderno da demanda (`.estado.md`)

`<workspace>/.estado.md` é a memória viva da demanda: para que serve, o que já foi feito, o que falta, decisões tomadas, os poucos caminhos de arquivo que importam. Quem grava é você, com o Write — não existe subcomando no script. O `use` lê e imprime.

Ele existe por token: sem caderno, uma aba nova numa demanda que já andou custa uma expedição pelo repositório; com caderno, custa uma leitura curta.

- **Grave** ao fim de uma tarefa, ao dar `use` em outra demanda nesta aba, antes de um `down` e quando a pessoa pedir `/workspace note`.
- **Reescreva, nunca acumule.** Teto de 40 linhas, sempre o estado atual, sem histórico. Caderno que vira log passa a custar mais do que a exploração que ele evitava.
- **Caderno velho o `use` denuncia** (`⚠ mais velho que o último commit`). Quando aparecer, confira antes de partir do que está escrito ali.

Não confunda com o `CLAUDE.md` do workspace, que é fato estável (repos, refs, portas, regras), gerado pelo `create` e carregado sozinho em toda sessão daquela pasta. Aquele é curto porque custa sempre; este é lido sob demanda.

## Editor

**`/workspace editor`** (ou "quero trocar o editor"): rode `workspace.sh editor --list`, monte uma pergunta `AskUserQuestion` single select com os candidatos (`label` = o comando, `description` = o que ele recebe; marque qual é o atual, que sai de `workspace.sh editor`) e salve a resposta com `workspace.sh editor <comando>`. **Sempre mostre a caixa neste comando**, mesmo já havendo escolha salva — é o comando de trocar.

**Antes do primeiro `create` ou `open`**, rode `workspace.sh editor` e olhe a origem:

- **`WORKSPACE_EDITOR`** ou **`escolha salva`** → não pergunte nada, siga.
- **`detectado`** → se `editor --list` trouxer mais de um candidato, mostre a caixa e salve; com um só, use e siga.
- **`nenhum`** → siga; o script imprime o caminho para abrir na mão.

A escolha fica em `$WORKSPACES_ROOT/.editor`, então a pergunta automática acontece uma vez por máquina.

## Regras

- **Nome de repositório é o nome exato da pasta.** Argumento que não é repositório conhecido é o nome do workspace — **exceto** se for parecido com um repositório (`backen`, `ap`, `web-`): aí **pergunte** se foi typo, nunca crie um workspace com esse nome. Nome que existe em duas pastas exige caminho (`cobranca/api`); se a pessoa não indicar qual, pergunte.
- **Não crie branch.** O worktree nasce em detached HEAD na ref base. A branch da demanda é dele, depois, com `git switch -c`, seguindo o `git-conventions.md` do repositório.
- **A sessão atual não entra no worktree sozinha.** Não use `EnterWorktree`: no modo janela o editor abre uma janela nova, com sessão própria; no modo aba quem autoriza a sessão atual a trabalhar dentro do worktree é o `use`, e só naquela demanda.
- **Editor não é só VSCode.** Cursor, Kiro, Windsurf, Zed, JetBrains e Sublime são suportados. Se alguém usa outro, é `workspace.sh editor <comando>` — não mexa no script.
- **Portas são remapeadas pelo script, você não mexe nelas.** Cada workspace tem um offset (+10, +20) aplicado ao `PORT` do `.env` e às URLs `localhost:<porta>` dos apps do próprio workspace. O relatório do `create` diz a porta de cada um e a flag de quem precisa (`--port` no vite, `--httpPort` no serverless offline). `--no-ports` desliga. Não edite `.env` por conta própria.
- **Subir e parar é pelo script, nunca na mão.** `start` sobe cada repo do jeito que ele é (serverless offline, vite, watcher de asset, container do compose), **espera a porta aceitar conexão** e só então diz que subiu — se o app morre por env faltando, ele mostra o fim do log e termina com erro. `stop` para o que ele subiu. **Você não roda `npm run dev`, `docker compose up` nem `serverless offline` na sessão**, nem para "testar rápido". Log de cada app em `<workspace>/.logs/<repo>.log`.
- **`status` é leitura pura** — não sobe nem para nada, pode rodar à vontade. Sem nome, passa por todos os workspaces: é o comando de não esquecer processo rodando. A linha `fora da máquina:` mostra variável e host dos `.env` que **não** apontam para loopback (nunca o valor).
- **O `start` recusa serverless que não prove ser local, e não existe como forçar.** A config tem que declarar `stage: local` **e** apontar a AWS para esta máquina (`serverless-localstack` ou endpoint em `127.0.0.1`). Repo cuja config declara `prd`/`production` fica de fora: rodar offline nele resolveria tabela, fila e bucket **de produção**. Não há `--force`, flag nem variável de ambiente que contorne — se pedirem para contornar, **não contorne**: o caminho é o repo ganhar um `serverless-local.yml` ao lado da config de deploy.
- **A skill não bloqueia rede.** Credencial de provedor no `.env` continua valendo, então caminho de código que manda e-mail, SMS ou cobrança manda de verdade. `start` é o mesmo que rodar `npm run dev` na mão — nem mais, nem menos seguro.
- **Infra com estado é compartilhada, e o script nunca duplica.** MySQL, Valkey, LocalStack e moto sobem do **checkout principal**, nunca do worktree, e o `stop` não os toca — derrubar o banco de um workspace derrubaria o dos outros. Do worktree sobe só o container que serve o **código** do repo (o serviço com `build:`), e só quando aquele repo não tem processo local com porta. Banco por workspace continua fora de escopo: se pedirem, combine antes.
- **Container que outro workspace já está servindo faz o `start` recusar**, dizendo quem está com ele; `--force` assume. Não contorne por outro caminho.
- **`down` para antes de remover**, senão sobra processo órfão segurando porta. Ele **não integra branch**: remove o worktree e apaga a branch só se ela já estiver na ref base. Para fechar a demanda, `superpowers:finishing-a-development-branch`.
- **`down` limpa a pasta inteira, inclusive o que o container escreveu como root.** LocalStack, MySQL e moto rodam como root e deixam arquivo de root dentro do worktree (`localstack_data` é o caso comum) — o `rm` do usuário não alcança isso. Quem apaga é um container descartável, com o mesmo uid que criou; nada de `sudo`. Se ainda sobrar, o `down` **falha e diz o que sobrou**, em vez de anunciar sucesso e deixar a pasta.
- **O `down` fecha a janela do editor daquele workspace**, e só aquela — as janelas dos outros workspaces ficam. É pedido de fechamento ao gerenciador de janelas, não `kill`: o editor respeita hot-exit e pergunta se houver arquivo não salvo. Se a janela não fechar, é porque está esperando essa resposta, e o script diz isso. `--keep-editor` no comando ou `WORKSPACE_CLOSE_EDITOR=0` no ambiente desligam. Cobre a família VSCode (`code`, `cursor`, `kiro`, `windsurf`) e depende de X11/XWayland — fora disso desiste calado, sem falhar o `down`. **Você não faz nada disso na sessão:** é o script que fecha.
- **"Sujo" é o que mudou depois do provisionamento.** O `create` grava um baseline do `git status`, então artefato de instalação (PnP do yarn, vendor, venv) nunca conta como trabalho dele. Workspace criado antes disso não tem baseline: `workspace.sh baseline <nome>` regrava.
- **Não instale nada por iniciativa própria** nem rode gerenciador de pacotes fora do `create` e do `start`. Se a instalação falhou, o script já disse o comando para rodar na mão — e se o `start` reclamar que o projeto não está instalado, repasse o recado, não conserte por conta própria.

## Resposta depois de rodar

**A saída do script é a resposta.** Ele não vê o terminal, então repasse o conteúdo — mas comprimido, sem reexplicar o que a skill faz e sem reescrever em prosa o que já estava em lista.

| Comando | O que sua mensagem contém |
|---|---|
| criação | Uma linha por repositório: branch base, porta se houver. Mais os avisos que o script emitiu (porta, instalação, `.env.local`). Fim. |
| `list` | Um bloco por workspace, uma linha por repositório. Se houver marcador anormal (`(sujo)`, `✗ pasta ausente`, `✗ worktree quebrado`), **uma** linha apontando o fato. |
| `open` | Uma linha: qual abriu. |
| `use` | Uma linha por repo (porta, estado, branch) e o caderno quando houver. Confirme a fixação **só** se o hook tiver confirmado. Nada além disso — o briefing é para você trabalhar, não para a pessoa reler. |
| `note` | Uma linha: caderno gravado. Não repita o conteúdo que você acabou de escrever. |
| `status` | Uma linha por repo com porta e estado, o `fora da máquina:` quando houver, e o total no fim. Nada além disso. |
| `start` | Uma linha por repo: porta e se subiu. Quem falhou leva o motivo que o script deu (o fim do log já vem na saída — repasse comprimido, não repita o log inteiro). Recusa por stage não-local se repassa como está: é decisão da skill, não erro a diagnosticar. **Termine com o bloco `abra:` do script — as URLs completas, uma por linha, clicáveis, sempre por último.** Bloco ausente significa que nada com porta subiu: aí não invente URL. |
| `stop` | Uma linha do que parou, ou que nada estava de pé. |
| `down` | Uma linha do que saiu, ou o que travou e por quê. |
| `editor` | Uma linha: qual ficou salvo. |
| `repos`, `help`, `doctor` | Repasse o bloco como saiu, sem comentário antes ou depois. |
| `prune` | Uma linha: o que limpou, ou que não havia nada. |
| `update` | Uma linha: versão antes e depois, ou que já estava na última. |
| erro do script | Repasse o erro e a correção que ele já sugere. Não diagnostique além disso. |

**Nunca emende, em nenhum desses casos:** sugestão de melhoria, lista de pendências, próximo passo, observação cosmética sobre a própria saída, nem pergunta que não foi feita. Se você notou algo que vale dizer, guarde para quando perguntarem — a exceção é risco de perder trabalho da pessoa, que se diz na hora.

**Não investigue por conta própria.** `list`, `repos` e `help` são leitura: rodou, repassou, acabou. Ver algo estranho não autoriza rodar `git status`, `git log` ou abrir diagnóstico — pediram o comando, não uma auditoria. Só investigue se pedirem.

## Configuração

| Variável | Default |
|---|---|
| `WORKSPACE_ROOTS` | raízes de busca, separadas por `:` — sem ela, sai do config ou da auto-detecção |
| `WORKSPACES_ROOT` | `~/workspaces` |
| `WORKSPACE_IGNORE` | `*_copy*` — glob de caminhos ignorados |
| `WORKSPACE_MAXDEPTH` | `4` |
| `WORKSPACE_ENV_FILES` | `.env:.env.local:.env.development:.env.development.local` |
| `WORKSPACE_EDITOR` | vazio — auto-detecta `code`, `cursor`, `kiro`, `windsurf`, `codium`, `zed`, `webstorm`, `idea`, `subl`. Use `none` para só imprimir o caminho |
| `WORKSPACE_WAIT` | `60` — segundos que o `start` espera a porta abrir. `WORKSPACE_WAIT_SERVERLESS` (`180`) e `WORKSPACE_WAIT_CONTAINER` (`20`) para os casos mais lentos |
| `WORKSPACE_CLEAN_IMAGE` | `alpine:3` — imagem que o `down` e o `prune` usam para apagar o que o container escreveu como root |
| `WORKSPACE_PIN` | `1` — `0` desliga o hook de fixação da aba (o `use` vira só briefing, sem trava) |
| `WORKSPACE_COLOR` | `1` — `0` gera o `.code-workspace` sem cor de janela |

## Quando algo quebra

**Comece pelo `workspace.sh doctor`.** Ele diz o que falta na máquina (git, PATH, raízes, editor, docker, hooks) e o comando que resolve cada item. Máquina recém-instalada que se comporta estranho é quase sempre config faltando, não bug.

`workspace.sh setup` é o único comando interativo: **não o rode você** — ele espera resposta no terminal e travaria a sessão. Repasse o comando para a pessoa rodar.

`workspace.sh prune` limpa registro órfão de worktree em todos os repositórios e aponta pasta de workspace quebrada. É o caminho quando alguém apaga a pasta na mão em vez de usar o `down`.

**Pasta sem `.workspace` o `prune` remove**, inclusive conteúdo de root. É o resgate do caso em que o `down` foi interrompido no meio: sem esse arquivo o `down` recusa o nome, então só o `prune` alcança a pasta.

App que não sobe: o `start` já imprime o fim de `<workspace>/.logs/<repo>.log`. Se precisar de mais, o log inteiro está lá — leia esse arquivo, não recomece o diagnóstico do zero.

Trava atrapalhando: `WORKSPACE_PIN=0` desliga o hook sem mexer em `settings.json`. Pino perdido (aba antiga, demanda derrubada) o próprio hook apaga na próxima chamada, e o `prune` limpa o que sobrar. O hook está em `pin-hook.sh` e o rodapé em `statusline.sh`, os dois ao lado deste arquivo, ligados no `~/.claude/settings.json`.

O porquê de cada decisão de desenho está em `NOTES.md`, ao lado. Leia só se precisar mudar a skill.
