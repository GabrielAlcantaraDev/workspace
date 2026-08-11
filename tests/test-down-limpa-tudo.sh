#!/usr/bin/env bash
# Repro do bug: dado escrito por container (LocalStack roda como root via bind
# mount) impede a remocao da pasta do workspace, e o script nao percebe.
#
# Exercita o script de verdade, com WORKSPACES_ROOT apontado para uma pasta
# descartavel. Nada da maquina e tocado.
set -u

SCRIPT=${1:-$HOME/.claude/skills/workspace/workspace.sh}
T=$(mktemp -d)
WSROOT="$T/workspaces"
EMPTY="$T/sem-repos"
WS="$WSROOT/cobranca-teste"
mkdir -p "$WS/api" "$EMPTY"

fail=0
check() { # check <descricao> <esperado> <obtido>
  if [ "$2" = "$3" ]; then
    printf '  ok    %s\n' "$1"
  else
    printf '  FALHA %s\n        esperado: %s\n        obtido:   %s\n' "$1" "$2" "$3"
    fail=1
  fi
}

printf '\n== preparo: container escreve como root dentro do workspace ==\n'
docker run --rm -v "$WS/api":/d alpine:3 sh -c '
  mkdir -p /d/localstack_data/cache /d/localstack_data/lib
  echo x > /d/localstack_data/cache/machine.json
  echo y > /d/localstack_data/lib/estado.bin
' >/dev/null 2>&1 || { echo "  docker indisponivel — teste abortado"; exit 2; }

owner=$(stat -c '%U' "$WS/api/localstack_data" 2>/dev/null)
check "o container criou conteudo de root" "root" "$owner"

printf '\n== confirma que um rm comum nao alcanca (a causa do bug) ==\n'
# Precisa ser conteudo criado PELO container: copiar com cp -r produziria
# arquivos do proprio usuario, que ele apaga sem problema.
probe="$T/probe"
mkdir -p "$probe"
docker run --rm -v "$probe":/d alpine:3 sh -c '
  mkdir -p /d/localstack_data/cache && echo x > /d/localstack_data/cache/machine.json
' >/dev/null 2>&1
rm -rf "$probe" 2>/dev/null
check "rm -rf do usuario deixa resto" "sobrou" "$([ -e "$probe" ] && echo sobrou || echo removeu)"

printf '\n== o script deve limpar a pasta orfa (sem .workspace) ==\n'
out=$(WORKSPACE_ROOTS="$EMPTY" WORKSPACES_ROOT="$WSROOT" XDG_CONFIG_HOME="$T/.config" bash "$SCRIPT" prune 2>&1)
check "a pasta do workspace foi removida" "removida" \
  "$([ -e "$WS" ] && echo sobrou || echo removida)"
check "nao manda o Gabriel apagar na mao" "sem instrucao manual" \
  "$(printf '%s' "$out" | grep -q 'Apague com: rm -rf' && echo 'manda rm -rf na mao' || echo 'sem instrucao manual')"

printf '\n-- saida do prune --\n%s\n' "$out" | sed 's/^/  | /'

# Limpeza do proprio teste: se o script nao removeu, o resto e de root.
if [ -e "$WSROOT" ]; then
  docker run --rm -v "$T":/t alpine:3 rm -rf /t/workspaces >/dev/null 2>&1 || true
fi
rm -rf "$T" 2>/dev/null

printf '\n%s\n\n' "$([ $fail -eq 0 ] && echo 'TODOS OS TESTES PASSARAM' || echo 'HA TESTES FALHANDO')"
exit $fail
