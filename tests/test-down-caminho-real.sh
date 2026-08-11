#!/usr/bin/env bash
# Exercita o `down` de verdade: repo git + worktree + dado de root escrito por
# container dentro do worktree (como o LocalStack faz com localstack_data).
#
# Nada da maquina e tocado: WORKSPACES_ROOT e WORKSPACE_ROOTS apontam para
# uma arvore descartavel.
set -u

SCRIPT=${1:-$HOME/.claude/skills/workspace/workspace.sh}
T=$(mktemp -d)
MAIN="$T/repos/api"
WSROOT="$T/workspaces"
WS="$WSROOT/demanda-teste"

fail=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
  else printf '  FALHA %s\n        esperado: %s\n        obtido:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

printf '\n== preparo: repo principal com uma branch e um worktree ==\n'
mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@t; git -C "$MAIN" config user.name t
# localstack_data e ignorado no repo real — sem isso a guarda de trabalho nao
# integrado veria o dado do container como arquivo novo e recusaria o down.
printf 'localstack_data/\n' > "$MAIN/.gitignore"
printf 'x\n' > "$MAIN/app.js"
git -C "$MAIN" add -A && git -C "$MAIN" commit -qm inicial

mkdir -p "$WS"
git -C "$MAIN" worktree add -q --detach "$WS/api" main
printf 'api\t%s\t-\tmain\n' "$MAIN" > "$WS/.workspace"
: > "$WS/.baseline"

printf '\n== o container escreve como root dentro do worktree ==\n'
docker run --rm -v "$WS/api":/d alpine:3 sh -c '
  mkdir -p /d/localstack_data/cache && echo x > /d/localstack_data/cache/machine.json
' >/dev/null 2>&1 || { echo "  docker indisponivel — teste abortado"; exit 2; }
check "conteudo de root criado no worktree" "root" \
  "$(stat -c '%U' "$WS/api/localstack_data" 2>/dev/null)"

printf '\n== roda o down ==\n'
out=$(WORKSPACE_ROOTS="$T/repos" WORKSPACES_ROOT="$WSROOT" XDG_CONFIG_HOME="$T/.config" \
      WORKSPACE_CLOSE_EDITOR=0 bash "$SCRIPT" down demanda-teste 2>&1)
rc=$?

check "down terminou com sucesso" "0" "$rc"
check "a pasta do workspace foi removida" "removida" \
  "$([ -e "$WS" ] && echo sobrou || echo removida)"
check "registro de worktree limpo no repo principal" "0" \
  "$(git -C "$MAIN" worktree list 2>/dev/null | grep -c 'demanda-teste' || true)"

printf '\n-- saida do down --\n%s\n' "$out" | sed 's/^/  | /'

[ -e "$WSROOT" ] && docker run --rm -v "$T":/t alpine:3 rm -rf /t/workspaces >/dev/null 2>&1
rm -rf "$T" 2>/dev/null

printf '\n%s\n\n' "$([ $fail -eq 0 ] && echo 'TODOS OS TESTES PASSARAM' || echo 'HA TESTES FALHANDO')"
exit $fail
