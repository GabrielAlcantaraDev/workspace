# Kiro CLI — Hooks de fixação de aba (pin)

O `workspace use <nome>` fixa a sessão de chat do Kiro CLI numa demanda. Um
hook barra qualquer escrita fora daquele workspace, evitando que o agente
mexa no lugar errado quando há várias demandas abertas.

## Pré-requisitos

| | |
|---|---|
| **Kiro CLI** | `kiro-cli chat` instalado e funcional |
| **jq** | `sudo apt install jq` (Debian/Ubuntu) ou `brew install jq` (macOS) |
| **workspace** | Já instalado (`workspace --version` funciona) |

## Instalação automática (recomendada)

Se você ainda não instalou, ou quer reinstalar com suporte a hooks:

```bash
curl -fsSL https://raw.githubusercontent.com/GabrielAlcantaraDev/workspace/main/install.sh | bash -s -- --with-agents
```

O instalador:

1. Detecta que `~/.kiro` existe
2. Instala o steering em `~/.kiro/steering/workspace.md`
3. Copia os scripts de hook para `~/.local/share/workspace/kiro/`
4. Resolve os caminhos absolutos nos JSONs
5. Propaga os hooks para cada raiz de projeto em `WORKSPACE_ROOTS`

Se `WORKSPACE_ROOTS` não estiver configurado (nunca rodou `workspace setup`),
o instalador avisa e imprime o comando manual.

## Instalação manual (projeto por projeto)

Se o instalador não encontrar suas raízes, ou se quiser ativar num projeto
específico:

```bash
# 1. Certifique-se de que os scripts estão no local fixo
ls ~/.local/share/workspace/kiro/
# Deve conter: workspace-pin-hook.sh, workspace-ws-prefix.sh, e os 3 JSONs

# 2. Copie para o projeto onde você abre o kiro-cli chat
mkdir -p ~/projetos/.kiro/hooks
cp ~/.local/share/workspace/kiro/*.json ~/projetos/.kiro/hooks/
cp ~/.local/share/workspace/kiro/*.sh   ~/projetos/.kiro/hooks/
chmod +x ~/projetos/.kiro/hooks/*.sh
```

Repita o passo 2 para cada pasta de projeto onde costuma abrir o `kiro-cli`.

## Por que precisa ser no projeto (e não em ~/.kiro/hooks)?

O Kiro CLI **só carrega hooks de `.kiro/hooks/` dentro do diretório de
trabalho** (o cwd onde o chat foi aberto). Hooks em `~/.kiro/hooks/` existem
no filesystem mas **nunca são disparados**.

Isso é diferente do Claude Code, que usa um `~/.claude/settings.json` global.

## Como funciona

### Arquivos instalados

| Arquivo | Trigger | Função |
|---|---|---|
| `workspace-pin-guard.json` | PreToolUse | Intercepta `execute_bash`, `fs_write`, `fs_append`, `str_replace`. Grava o pin quando detecta `workspace use <nome>` e bloqueia escrita fora da demanda fixada. |
| `workspace-pin-restore.json` | SessionStart | Reanuncia o pin quando a sessão reinicia (o arquivo de pin persiste entre sessões). |
| `workspace-ws-prefix.json` | UserPromptSubmit | Reforça o atalho `ws` — quando detecta mensagem começando com `ws`, injeta ordem para executar o comando workspace correspondente. |
| `workspace-pin-hook.sh` | — | Script principal de pin (chamado pelos JSONs acima). |
| `workspace-ws-prefix.sh` | — | Script do atalho `ws` (chamado pelo JSON acima). |

### Fluxo do pin

```
Usuário digita: workspace use minha-feature
         │
         ▼
   PreToolUse hook dispara
         │
         ▼
   workspace-pin-hook.sh guard
         │
         ├─ Detecta "workspace use minha-feature"
         ├─ Valida que ~/workspaces/minha-feature/.workspace existe
         ├─ Grava o pin em ~/workspaces/.pins/<session_id>
         └─ Imprime confirmação no stdout (injetado no contexto do agente)
         │
         ▼
   Agente sabe que está fixado e trabalha dentro de ~/workspaces/minha-feature/
```

### Guarda (bloqueio)

Com o pin ativo, qualquer tentativa de:
- Escrever arquivo (`fs_write`, `str_replace`) **em outro workspace**
- Rodar comando (`execute_bash`) que **referencia outro workspace**

...resulta em `exit 2` + mensagem no stderr, e a operação é **negada**.

Exceções:
- Comandos `workspace` (status/stop/down de outra demanda são operação normal)
- Leitura do clone principal (pra comparar com a base)

### Soltar o pin

```
workspace use none
```

## Verificação

Depois de instalar, confirme que está tudo certo:

```bash
# 1. Os hooks existem no seu projeto?
ls -la ~/projetos/.kiro/hooks/workspace-pin-*

# 2. Os JSONs têm o caminho absoluto correto (não __HOOKS_DIR__)?
grep "command" ~/projetos/.kiro/hooks/workspace-pin-guard.json
# Deve mostrar algo como: "/home/seuuser/.local/share/workspace/kiro/workspace-pin-hook.sh guard"

# 3. jq está instalado?
jq --version

# 4. Abra o kiro-cli no projeto e teste:
#    workspace use <algum-workspace-ativo>
#    → deve imprimir "Pino gravado: esta sessão está fixada..."
```

## Troubleshooting

| Sintoma | Causa | Solução |
|---|---|---|
| `workspace use` não grava o pin | Hooks não estão em `.kiro/hooks/` do cwd | Copie os hooks para o diretório correto (ver instalação manual) |
| Pin grava mas não bloqueia | Só há um workspace ativo | A guarda só bloqueia escrita em **outros** workspaces |
| JSON mostra `__HOOKS_DIR__` | Placeholder não foi resolvido | Rode o install.sh novamente, ou faça sed manualmente: `sed -i "s|__HOOKS_DIR__|$HOME/.local/share/workspace/kiro|g" .kiro/hooks/*.json` |
| Hook não dispara (nenhum efeito) | Kiro CLI aberto em diretório sem `.kiro/hooks/` | Abra o chat no diretório do projeto onde os hooks foram instalados |
| `jq: command not found` | jq não instalado | `sudo apt install jq` ou `brew install jq` |

## Desativar

Para desligar os hooks sem removê-los:

```bash
export WORKSPACE_PIN=0
```

Ou remova os arquivos:

```bash
rm -f ~/projetos/.kiro/hooks/workspace-pin-*
rm -f ~/projetos/.kiro/hooks/workspace-ws-prefix*
```
