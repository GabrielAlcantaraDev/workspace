#!/usr/bin/env bash
# Roda a bateria inteira. Existe porque cada teste recebe um alvo diferente
# (o do hook recebe o pin-hook.sh, os outros o workspace.sh) e errar isso
# produz falha que parece bug do script.
#
#   tests/run.sh              testa os arquivos deste repositorio
#   tests/run.sh /caminho     testa outra copia (ex: a instalada)

set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BASE=${1:-$(dirname -- "$HERE")}

falhou=0
for t in "$HERE"/test-*.sh; do
  nome=$(basename "$t")
  case $nome in
  test-pin-hook.sh) alvo="$BASE/claude/pin-hook.sh" ;;
  *) alvo="$BASE/workspace.sh" ;;
  esac
  [ -f "$alvo" ] || { printf '  PULADO  %-30s (nao achei %s)\n' "$nome" "$alvo"; continue; }
  printf '  %-30s' "$nome"
  if saida=$(bash "$t" "$alvo" 2>&1); then
    printf 'ok  (%s asserçoes)\n' "$(printf '%s' "$saida" | grep -c '^  ok')"
  else
    printf 'FALHOU\n'
    printf '%s\n' "$saida" | sed 's/^/      /'
    falhou=1
  fi
done

printf '\n'
[ "$falhou" -eq 0 ] && printf '  bateria completa passou\n\n' || printf '  HA TESTES FALHANDO\n\n'
exit "$falhou"
