#!/usr/bin/env bash
# pin-hook — prende uma aba de chat a uma demanda da skill `workspace`.
#
# Sem isto, "esta aba só mexe na demanda X" é promessa do assistente. Com isto é
# o harness que barra: o hook roda antes da ferramenta e nega a chamada.
#
# Três modos, um por evento do Claude Code:
#
#   record   PostToolUse/Bash  vê `workspace.sh use <nome>` e grava o pino
#   guard    PreToolUse        nega escrita fora da demanda fixada
#   restore  SessionStart      reinjeta o pino depois de uma compactação
#
# O pino é um arquivo por sessão em $WS_ROOT/.pins/<session_id>, com o nome da
# demanda dentro. Duas razões para morar em arquivo, e não no contexto:
#
#   1. O session_id só existe aqui. O workspace.sh não tem como saber qual aba
#      o chamou, então quem grava o pino é o hook, não o comando — e o
#      assistente não tem como forjar um pino que não pediu.
#   2. Conversa longa é compactada e detalhe se perde. Arquivo não.
#
# Desligador: WORKSPACE_PIN=0 no ambiente. Hook rígido demais que trava trabalho
# legítimo precisa de saída sem editar settings.json às pressas.

set -uo pipefail

# Mesma resolução do workspace.sh, na versão mínima: env > config > default.
# Ler o config aqui custa um awk, e é o que mantém hook e comando apontando para
# a mesma pasta quando alguém move a raiz dos workspaces.
CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/workspace/config"
WS_ROOT="${WORKSPACES_ROOT:-}"
if [ -z "$WS_ROOT" ] && [ -f "$CONFIG_FILE" ]; then
  WS_ROOT=$(awk -F= '$1=="workspaces_root" { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG_FILE")
fi
WS_ROOT="${WS_ROOT:-$HOME/workspaces}"
PINS="$WS_ROOT/.pins"
MODE=${1:-guard}

[ "${WORKSPACE_PIN:-1}" != 0 ] || exit 0

# Caminho rápido, e é ele que torna este hook aceitável: ele roda em TODA
# chamada de ferramenta da máquina, inclusive em projeto que nada tem a ver com
# a skill. Sem nenhum pino gravado, sai antes de ler o stdin e de invocar o jq —
# custo de um glob. Quem nunca deu `use` não paga nada, e nada é barrado.
if [ "$MODE" != record ]; then
  shopt -s nullglob
  set -- "$PINS"/*
  [ $# -gt 0 ] || exit 0
fi

payload=$(cat)

sid=$(printf '%s' "$payload" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
# session_id vem da API; nunca deveria ter barra, mas o valor vira nome de
# arquivo e um '../' aqui escreveria fora do diretório.
case $sid in */* | *..*) exit 0 ;; esac
pin="$PINS/$sid"

# ------------------------------------------------------------------ record

if [ "$MODE" = record ]; then
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
  # Só reage à linha de comando do próprio script. Casa `workspace.sh use X`,
  # `/caminho/workspace.sh use X` e `workspace use X`.
  alvo=$(printf '%s' "$cmd" |
    grep -oE '(^|[^[:alnum:]_-])workspace(\.sh)?[[:space:]]+use([[:space:]]+[A-Za-z0-9._-]+)?' |
    head -1 | awk '{print $NF}')
  case $alvo in '' | use) exit 0 ;; esac # `use` sozinho é a caixa de seleção

  mkdir -p "$PINS"
  if [ "$alvo" = none ]; then
    rm -f "$pin"
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Aba solta: nenhuma demanda fixada. As travas de caminho estão desligadas nesta aba."}}\n'
    exit 0
  fi
  # Valida aqui, e não no comando: pino apontando para workspace inexistente
  # travaria a aba sem nada para destravar.
  if [ ! -f "$WS_ROOT/$alvo/.workspace" ]; then exit 0; fi
  printf '%s\n' "$alvo" > "$pin"
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Pino gravado: esta aba está fixada no workspace %s. Todo caminho resolve dentro de %s. O hook nega escrita em outra demanda; solte com /workspace use none."}}\n' \
    "$alvo" "$WS_ROOT/$alvo"
  exit 0
fi

# ---------------------------------------------------------- pino atual

[ -f "$pin" ] || exit 0
alvo=$(head -1 "$pin" 2>/dev/null | tr -d '[:space:]')
mine="$WS_ROOT/$alvo"
# Demanda derrubada com a aba ainda aberta: o pino perdeu o dono. Some sozinho,
# senão a aba fica travada apontando para uma pasta que não existe mais.
if [ -z "$alvo" ] || [ ! -f "$mine/.workspace" ]; then
  rm -f "$pin"
  exit 0
fi

# ----------------------------------------------------------------- restore

if [ "$MODE" = restore ]; then
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"Esta aba está fixada no workspace %s (%s). Trabalhe apenas nesses worktrees; o hook nega escrita em outra demanda. Solte com /workspace use none."}}\n' \
    "$alvo" "$mine"
  exit 0
fi

# ------------------------------------------------------------------- guard

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty')

# Os outros workspaces, que é o erro que importa barrar: editar a árvore da
# demanda errada não dá erro nenhum na hora, e só aparece no diff do dia
# seguinte.
proibidos=()
for d in "$WS_ROOT"/*/; do
  [ -f "$d/.workspace" ] || continue
  [ "${d%/}" = "$mine" ] && continue
  proibidos+=("${d%/}")
done

case $tool in
Write | Edit | NotebookEdit)
  # O clone principal entra na lista só para edição de arquivo: é o engano
  # clássico (mexer no master achando que é o worktree) e aqui dá para separar
  # leitura de escrita com precisão, coisa que numa linha de shell não dá.
  while IFS=$'\t' read -r _ main _ _; do
    [ -n "$main" ] || continue
    case $mine in "$main"/*) continue ;; esac # nunca barrar a própria demanda
    proibidos+=("$main")
  done < "$mine/.workspace"

  destino=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
  [ -n "$destino" ] || exit 0
  for p in ${proibidos[@]+"${proibidos[@]}"}; do
    case $destino in
    "$p"/*)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Esta aba está fixada no workspace %s, e %s está fora dele. Se era para mexer nessa outra árvore, solte a aba com /workspace use none (ou fixe na outra demanda com /workspace use <nome>); se não era, corrija o caminho para dentro de %s."}}\n' \
        "$alvo" "$destino" "$mine"
      exit 0
      ;;
    esac
  done
  ;;
Bash)
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty')
  [ -n "$cmd" ] || exit 0
  # O próprio script passa sempre: `down`, `status` e `stop` de outra demanda
  # são operação normal de qualquer aba, e é justamente o que a skill oferece.
  case $cmd in *workspace.sh*) exit 0 ;; esac
  # Clone principal NÃO entra aqui de propósito: `git -C <clone> log` para
  # comparar com a base é rotina, e uma linha de shell não diz se lê ou
  # escreve. Barrar tudo faria o hook atrapalhar mais do que protege — a
  # escrita de verdade em arquivo passa por Write/Edit, que é estrito.
  for p in ${proibidos[@]+"${proibidos[@]}"}; do
    case $cmd in
    *"$p"*)
      printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Esta aba está fixada no workspace %s, e o comando toca %s, que é de outra demanda. Solte a aba com /workspace use none se era intencional."}}\n' \
        "$alvo" "$p"
      exit 0
      ;;
    esac
  done
  ;;
esac

exit 0
