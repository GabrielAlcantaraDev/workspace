#!/usr/bin/env bash
# pin-hook (Kiro CLI) — prende a sessão de chat a uma demanda do `workspace`.
#
# Sem isto, "esta sessão só mexe na demanda X" é promessa do assistente. Com
# isto é o harness que barra: o hook roda antes da ferramenta e nega a
# chamada via `exit 2`, cuja stderr vai pro contexto do agente.
#
# Diferenças concretas frente à versão Claude (não é um port cego):
#
#   - Kiro chama tools com nomes diferentes: `execute_bash`, `fs_write`,
#     `fs_append`, `str_replace` (não `Bash`, `Write`, `Edit`).
#   - Kiro passa o caminho em `tool_input.path` (não `file_path`).
#   - Kiro esvazia `tool_input` no PostToolUse — então o `record` do pino
#     precisa acontecer no PreToolUse, validando o workspace no filesystem
#     antes de gravar. Se o comando `workspace use` falhar depois, a pessoa
#     desfixa com `workspace use none`.
#   - Kiro não documenta `permissionDecision:"deny"`; bloqueio hard é `exit 2`
#     com stderr descritiva. Só stdout de PreToolUse/SessionStart chega ao
#     contexto do agente — PostToolUse não injeta nada.
#
# Dois modos, um por trigger:
#
#   guard    PreToolUse    dispara para execute_bash/fs_write/fs_append/str_replace.
#                          Roteia por tool_name:
#                          - execute_bash com `workspace use X` → grava o pino.
#                          - execute_bash com comando comum → checa se toca
#                            worktree de outra demanda.
#                          - fs_*/str_replace → checa `tool_input.path`.
#   restore  SessionStart  reanuncia o pino após restart de sessão.
#
# O pino mora em $WS_ROOT/.pins/$session_id. Duas razões pra ficar em arquivo:
#
#   1. O session_id só existe aqui, no stdin do hook. O `workspace.sh` não
#      sabe qual sessão o chamou; quem grava é o hook.
#   2. Sessão reiniciada mantém o arquivo, e o `restore` re-injeta o aviso.
#
# Desligador: WORKSPACE_PIN=0 no ambiente do usuário.

set -uo pipefail

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/workspace/config"
WS_ROOT="${WORKSPACES_ROOT:-}"
if [ -z "$WS_ROOT" ] && [ -f "$CONFIG_FILE" ]; then
  WS_ROOT=$(awk -F= '$1=="workspaces_root" { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG_FILE")
fi
WS_ROOT="${WS_ROOT:-$HOME/workspaces}"
PINS="$WS_ROOT/.pins"
MODE=${1:-guard}

[ "${WORKSPACE_PIN:-1}" != 0 ] || exit 0

# Caminho rápido: se nada foi fixado nunca, sai antes de ler stdin ou invocar
# jq. Custo por chamada = um glob. Máquina que instalou os hooks mas nunca deu
# `workspace use` não paga nada, e nada é barrado.
if [ "$MODE" != guard ] || [ ! -d "$PINS" ]; then :; else
  shopt -s nullglob
  set -- "$PINS"/*
  # Se não é um `workspace use` em curso e não há pinos, sai. `workspace use`
  # precisa passar para gravar o primeiro pino da sessão.
  if [ $# -eq 0 ]; then
    # Ainda tem que checar se é o `workspace use X` que vai criar o pino.
    # Como isso exige ler o stdin, adiamos o exit para depois do parse.
    :
  fi
fi

# jq é requisito. O install.sh checa antes de configurar os hooks.
command -v jq >/dev/null 2>&1 || exit 0

payload=$(cat)
sid=$(printf '%s' "$payload" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
# session_id vira nome de arquivo; '../' aqui escreveria fora do diretório.
case $sid in */* | *..*) exit 0 ;; esac
pin="$PINS/$sid"

# ------------------------------------------------------------------- restore

if [ "$MODE" = restore ]; then
  [ -f "$pin" ] || exit 0
  alvo=$(head -1 "$pin" 2>/dev/null | tr -d '[:space:]')
  mine="$WS_ROOT/$alvo"
  if [ -z "$alvo" ] || [ ! -f "$mine/.workspace" ]; then
    rm -f "$pin"
    exit 0
  fi
  printf 'Esta sessão está fixada no workspace %s (%s). Trabalhe apenas nesses worktrees; o hook nega escrita em outra demanda. Solte com: workspace use none\n' \
    "$alvo" "$mine"
  exit 0
fi

# --------------------------------------------------------------------- guard

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')
[ -n "$tool" ] || exit 0

# ---- record embutido no guard: `workspace use X` no execute_bash

if [ "$tool" = execute_bash ]; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
  if [ -n "$cmd" ]; then
    alvo=$(printf '%s' "$cmd" |
      grep -oE '(^|[^[:alnum:]_-])workspace[[:space:]]+use([[:space:]]+[A-Za-z0-9._-]+)?' |
      head -1 | awk '{print $NF}')
    case ${alvo:-} in
    '' | use)
      # não é `workspace use ...`, ou é sem argumento (caixa de seleção); cai
      # pro guard de comando abaixo.
      :
      ;;
    none)
      # solta a aba.
      mkdir -p "$PINS"
      rm -f "$pin"
      printf 'Pino removido: esta sessão não está mais fixada em nenhum workspace.\n'
      exit 0
      ;;
    *)
      # valida no filesystem antes de gravar — pino apontando pra pasta
      # inexistente travaria a sessão sem nada para destravar.
      if [ -f "$WS_ROOT/$alvo/.workspace" ]; then
        mkdir -p "$PINS"
        printf '%s\n' "$alvo" > "$pin"
        printf 'Pino gravado: esta sessão está fixada no workspace %s. Todo caminho resolve dentro de %s. O hook nega escrita em outra demanda; solte com: workspace use none\n' \
          "$alvo" "$WS_ROOT/$alvo"
      fi
      exit 0
      ;;
    esac
  fi
fi

# ---- guard puro: precisa ter pino ativo

[ -f "$pin" ] || exit 0
alvo=$(head -1 "$pin" 2>/dev/null | tr -d '[:space:]')
mine="$WS_ROOT/$alvo"
if [ -z "$alvo" ] || [ ! -f "$mine/.workspace" ]; then
  # pino perdeu o dono (demanda foi derrubada). Some sozinho.
  rm -f "$pin"
  exit 0
fi

# monta a lista dos outros workspaces (as áreas proibidas).
proibidos=()
for d in "$WS_ROOT"/*/; do
  [ -f "$d/.workspace" ] || continue
  [ "${d%/}" = "$mine" ] && continue
  proibidos+=("${d%/}")
done

case $tool in
fs_write | fs_append | str_replace)
  # Escrita direta em arquivo. Também bloqueia edição no clone principal —
  # é o engano clássico "achei que era o worktree".
  while IFS=$'\t' read -r _ main _ _; do
    [ -n "$main" ] || continue
    case $mine in "$main"/*) continue ;; esac
    proibidos+=("$main")
  done < "$mine/.workspace"

  destino=$(printf '%s' "$payload" | jq -r '.tool_input.path // empty')
  [ -n "$destino" ] || exit 0
  for p in ${proibidos[@]+"${proibidos[@]}"}; do
    case $destino in
    "$p"/*)
      printf 'Esta sessão está fixada no workspace %s, e %s está fora dele. Se era pra mexer nessa outra árvore, solte a sessão com: workspace use none (ou fixe na outra demanda com: workspace use <nome>). Se não era, corrija o caminho para dentro de %s.\n' \
        "$alvo" "$destino" "$mine" >&2
      exit 2
      ;;
    esac
  done
  ;;
execute_bash)
  # cmd já foi lido acima
  [ -n "${cmd:-}" ] || exit 0
  # O próprio `workspace` passa sempre: down/status/stop de outra demanda são
  # operação normal de qualquer sessão.
  case $cmd in *workspace*) exit 0 ;; esac
  # Clone principal NÃO entra aqui de propósito: `git -C <clone> log` pra
  # comparar com a base é rotina, e uma linha de shell não separa leitura de
  # escrita. Escrita real passa por fs_write/str_replace, onde é estrito.
  for p in ${proibidos[@]+"${proibidos[@]}"}; do
    case $cmd in
    *"$p"*)
      printf 'Esta sessão está fixada no workspace %s, e o comando toca %s, que é de outra demanda. Solte com: workspace use none se era intencional.\n' \
        "$alvo" "$p" >&2
      exit 2
      ;;
    esac
  done
  ;;
esac

exit 0
