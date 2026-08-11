#!/usr/bin/env bash
# statusline — rodapé do chat, com a demanda fixada nesta aba em destaque.
#
# Existe por causa das quatro abas: cor de janela resolve quando cada demanda
# tem a sua janela, mas no modo `use` as abas são idênticas. Aqui fica escrito.
#
# Recebe o JSON da sessão no stdin. Roda a cada atualização do rodapé, então é
# uma chamada de jq e nada mais — sem git, sem rede, sem varrer diretório.

set -uo pipefail

CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/workspace/config"
WS_ROOT="${WORKSPACES_ROOT:-}"
if [ -z "$WS_ROOT" ] && [ -f "$CONFIG_FILE" ]; then
  WS_ROOT=$(awk -F= '$1=="workspaces_root" { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG_FILE")
fi
WS_ROOT="${WS_ROOT:-$HOME/workspaces}"

# IFS de tabulação, não o padrão: nome de modelo tem espaço ("Opus 5") e
# caminho pode ter, então quebrar por espaço embaralharia os três campos.
IFS=$'\t' read -r sid dir modelo < <(
  jq -r '[.session_id // "", (.workspace.current_dir // .cwd // ""), (.model.display_name // "")] | @tsv'
)

# Basename do diretório, com ~ no lugar do home quando for a raiz de algum lugar.
curto=${dir##*/}
[ -n "$curto" ] || curto='~'

linha="$curto"
[ -n "${modelo:-}" ] && linha="$linha  ·  $modelo"

pin="$WS_ROOT/.pins/$sid"
if [ -n "${sid:-}" ] && [ -f "$pin" ]; then
  alvo=$(head -1 "$pin" 2>/dev/null | tr -d '[:space:]')
  # Amarelo: a informação mais importante do rodapé é em que demanda esta aba
  # está presa, porque é ela que decide o que o assistente pode escrever.
  [ -n "$alvo" ] && linha="$linha  ·  $(printf '\033[1;33m⬤ %s\033[0m' "$alvo")"
fi

printf '%s\n' "$linha"
