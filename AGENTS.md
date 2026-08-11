# Instruções para agentes

Você recebeu o link deste repositório e a pessoa quer o `workspace` instalado e
funcionando. Siga isto na ordem. São dois comandos e uma verificação.

## 0. Se a máquina for Windows

Confira antes de qualquer coisa:

```bash
uname -s
```

- `Linux` ou `Darwin` → siga para o passo 1.
- `Linux` com `microsoft` em `/proc/version` → é WSL, siga para o passo 1.
- `MINGW*`, `MSYS*` ou `CYGWIN*` → **pare**. É Git Bash ou Cygwin, e a
  ferramenta recusa instalar ali (caminho POSIX não atravessa para o VSCode nem
  para o Docker do Windows). Diga à pessoa para instalar o WSL:

  ```powershell
  wsl --install
  ```

  No PowerShell como administrador, uma vez só. Depois ela abre o Ubuntu e você
  recomeça deste arquivo lá dentro. Avise também que os repositórios devem
  ficar dentro do WSL (`~/dev`), não em `/mnt/c/...`.

## 1. Instale

```bash
curl -fsSL https://raw.githubusercontent.com/GabrielAlcantaraDev/workspace/main/install.sh | bash -s -- --with-agents
```

O `--with-agents` é obrigatório para você. Sem ele o instalador tenta perguntar
se deve ensinar a ferramenta aos agentes da máquina (Claude Code, Kiro, Codex),
não acha terminal na sua sessão e segue sem isso — a pessoa fica só com o
comando de terminal, e o agente dela continua sem conhecer o `workspace`. Se ela
preferir não ter isso, troque por `--no-agents`.

O instalador só mexe no que já existe: `~/.claude`, `~/.kiro` e `~/.codex`. No
Codex ele acrescenta um bloco delimitado ao AGENTS.md global e preserva o resto
do arquivo — não o sobrescreva por conta própria.

Se o instalador avisar que `~/.local/bin` não está no PATH, adicione a linha que
ele mostrar ao `~/.bashrc` ou `~/.zshrc` da pessoa e diga que é preciso abrir um
terminal novo.

## 2. Verifique

```bash
workspace doctor
```

Repasse o relatório. Ele lista o que falta e o comando de cada item. Os `·` são
opcionais e não impedem o uso; os `✗` são o que precisa de ação.

## 3. Diga onde ficam os repositórios (só se o doctor pedir)

O `doctor` descobre sozinho quando os repositórios estão em `~/dev`, `~/code`,
`~/projects`, `~/src`, `~/work`, `~/repos` ou `~/git`. Quando não descobre, ele
pede o `setup`.

**Não rode `workspace setup`.** Ele é interativo e vai travar sua sessão
esperando uma resposta que você não tem como dar. Faça uma destas duas:

- Pergunte à pessoa onde ficam os repositórios dela e grave direto:

  ```bash
  mkdir -p ~/.config/workspace
  printf 'roots=%s\n' "$HOME/o-caminho-que-ela-disse" >> ~/.config/workspace/config
  ```

- Ou repasse o comando `workspace setup` para ela rodar no terminal dela.

Rode `workspace doctor` de novo depois, para confirmar.

## O que não fazer

- **Não rode `workspace setup`** — é o único comando interativo (ver acima).
- **Não rode `workspace start` para "testar"** sem a pessoa pedir. Ele sobe os
  apps de verdade, com os `.env` de verdade: credencial de provedor no `.env`
  continua valendo, e caminho de código que manda e-mail, SMS ou cobrança manda
  de verdade.
- **Não edite o `settings.json` na mão** para ligar os hooks. O instalador faz
  isso de forma idempotente e com backup. Rodá-lo de novo é seguro.
- **Não crie workspace nenhum** para demonstrar. Criar clona dependências e leva
  minutos; a pessoa cria o dela quando quiser.

## Depois de instalar

Diga à pessoa, em duas linhas:

- `workspace <nome> <repo> <repo>` cria o ambiente da demanda dela.
- `workspace help` é o manual completo.

E que atualizar depois é `workspace update`.
