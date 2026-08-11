# Instruções para agentes

Você recebeu o link deste repositório e a pessoa quer o `workspace` instalado e
funcionando. Siga isto na ordem. São dois comandos e uma verificação.

## 1. Instale

```bash
curl -fsSL https://raw.githubusercontent.com/GabrielAlcantaraDev/workspace/main/install.sh | bash -s -- --with-claude
```

O `--with-claude` é obrigatório para você. Sem ele o instalador tenta perguntar
se deve instalar a camada do Claude Code, não acha terminal na sua sessão e
segue sem ela — a pessoa fica só com o comando de terminal, sem o `/workspace`
no chat. Se ela **não** usa Claude Code, troque por `--no-claude`.

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
