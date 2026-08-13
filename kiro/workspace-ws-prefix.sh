#!/usr/bin/env bash
# workspace-ws-prefix — hook UserPromptSubmit que reforça o atalho `ws `.
#
# Se `.prompt` vier populado e começar com `ws` (isolado ou seguido de
# argumentos), injeta no contexto do agente uma ordem explícita para
# executar o comando `workspace` correspondente via execute_bash. Isso
# reforça a steering — Kiro não pode fingir que não viu.
#
# Sem `.prompt`, injeta apenas um lembrete curto do atalho, para o caso de a
# steering não ter sido pesada o suficiente.
#
# Sempre exit 0 — nunca bloqueia o prompt.

set -uo pipefail

# Log opcional: só grava se WORKSPACE_DEBUG=1 no ambiente do usuário.
if [ "${WORKSPACE_DEBUG:-0}" = 1 ]; then
  ts=$(date +%s%N)
  cat > "/tmp/workspace-userprompt-${ts}.json"
  payload=$(cat "/tmp/workspace-userprompt-${ts}.json")
else
  payload=$(cat)
fi

command -v jq >/dev/null 2>&1 || exit 0

prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty')

if [ -z "$prompt" ]; then
  # Kiro não entregou o prompt (versão antiga ou mecânica interna). Sem
  # lembrete redundante para não poluir contexto quando não há atalho.
  exit 0
fi

# Match: mensagem começa com "ws" seguida de fim, espaço ou tab.
case $prompt in
ws | ws[[:space:]]*)
  args=$(printf '%s' "$prompt" | sed -E 's/^ws[[:space:]]*//' | sed 's/[[:space:]]*$//')
  if [ -z "$args" ]; then
    # `ws` isolado = `workspace list`
    printf 'ATALHO ws detectado. O usuário digitou "ws" isolado. Execute IMEDIATAMENTE via execute_bash:\n\n  workspace list\n\nSem interpretação em linguagem natural. Sem perguntas. Repasse a saída conforme a steering "workspace".\n'
  else
    printf 'ATALHO ws detectado. O usuário digitou "%s". Execute IMEDIATAMENTE via execute_bash:\n\n  workspace %s\n\nSem interpretação em linguagem natural. Sem perguntas. Repasse a saída conforme a steering "workspace".\n' "$prompt" "$args"
  fi
  exit 0
  ;;
esac

exit 0
