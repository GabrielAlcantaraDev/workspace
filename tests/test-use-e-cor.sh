#!/usr/bin/env bash
# Exercita o `use` (briefing, backfill do CLAUDE.md, caderno e idade do caderno)
# e a estabilidade da cor da janela.
#
# Nada da maquina e tocado: WORKSPACES_ROOT e WORKSPACE_ROOTS apontam para
# uma arvore descartavel. WORKSPACE_EDITOR=none impede o `open` de abrir janela.
set -u

SCRIPT=${1:-$HOME/.claude/skills/workspace/workspace.sh}
T=$(mktemp -d)
MAIN="$T/repos/api"
WSROOT="$T/workspaces"
WS="$WSROOT/demanda-teste"

run() { WORKSPACE_ROOTS="$T/repos" WORKSPACES_ROOT="$WSROOT" XDG_CONFIG_HOME="$T/.config" WORKSPACE_EDITOR=none bash "$SCRIPT" "$@" 2>&1; }

fail=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
  else printf '  FALHA %s\n        esperado: %s\n        obtido:   %s\n' "$1" "$2" "$3"; fail=1; fi
}
tem() {
  if printf '%s' "$2" | grep -qF "$3"; then printf '  ok    %s\n' "$1"
  else printf '  FALHA %s\n        nao achei: %s\n' "$1" "$3"; fail=1; fi
}

printf '\n== preparo: repo principal e um workspace ==\n'
mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email t@t; git -C "$MAIN" config user.name t
printf 'x\n' > "$MAIN/app.js"
git -C "$MAIN" add -A && git -C "$MAIN" commit -qm inicial

mkdir -p "$WS"
git -C "$MAIN" worktree add -q --detach "$WS/api" main
printf 'api\t%s\t-\tmain\n' "$MAIN" > "$WS/.workspace"
: > "$WS/.baseline"

printf '\n== use: briefing e backfill do CLAUDE.md ==\n'
check "workspace nasceu sem CLAUDE.md (simula versao antiga)" "ausente" \
  "$([ -f "$WS/CLAUDE.md" ] && echo presente || echo ausente)"
out=$(run use demanda-teste)
tem "briefing traz o nome" "$out" "demanda-teste"
tem "briefing traz o repo" "$out" "api"
tem "briefing traz a ref base" "$out" "main"
tem "briefing traz o caminho do worktree" "$out" "$WS/api"
tem "avisa que nao ha caderno" "$out" "Sem caderno ainda"
check "o use gravou o CLAUDE.md que faltava" "presente" \
  "$([ -f "$WS/CLAUDE.md" ] && echo presente || echo ausente)"
tem "CLAUDE.md proibe subir na mao" "$(cat "$WS/CLAUDE.md")" "npm run dev"
check "CLAUDE.md e curto (carrega em toda sessao)" "curto" \
  "$([ "$(wc -l < "$WS/CLAUDE.md")" -le 30 ] && echo curto || echo longo)"

printf '\n== use: caderno aparece e a idade e denunciada ==\n'
printf 'branch: feature/x\nfeito: nada\n' > "$WS/.estado.md"
out=$(run use demanda-teste)
tem "caderno impresso no briefing" "$out" "branch: feature/x"
check "caderno recem-escrito nao e acusado de velho" "sem aviso" \
  "$(printf '%s' "$out" | grep -q 'mais velho' && echo acusado || echo 'sem aviso')"

# Commit posterior ao caderno: e exatamente o caso que precisa gritar.
touch -d '2020-01-01' "$WS/.estado.md" 2>/dev/null || touch -t 202001010000 "$WS/.estado.md"
printf 'y\n' > "$WS/api/app.js"
git -C "$WS/api" add -A && git -C "$WS/api" commit -qm depois
out=$(run use demanda-teste)
check "caderno anterior ao ultimo commit e acusado" "acusado" \
  "$(printf '%s' "$out" | grep -q 'mais velho' && echo acusado || echo 'sem aviso')"

printf '\n== use: formas sem alvo ==\n'
out=$(run use); tem "use sem nome lista para escolher" "$out" "demanda-teste"
out=$(run use none); tem "use none avisa que a aba esta solta" "$out" "solta"
run use nao-existe >/dev/null 2>&1
check "use de workspace inexistente falha" "1" "$?"

printf '\n== cor: estavel entre geracoes e imune a workspace vizinho ==\n'
run open demanda-teste >/dev/null
cor1=$(jq -r '.settings["workbench.colorCustomizations"]["activityBar.background"]' "$WS/demanda-teste.code-workspace")
run open demanda-teste >/dev/null
cor2=$(jq -r '.settings["workbench.colorCustomizations"]["activityBar.background"]' "$WS/demanda-teste.code-workspace")
check "mesma cor ao regerar o arquivo" "$cor1" "$cor2"

# O refresh_all_wsfiles reescreve TODOS os arquivos quando nasce um workspace:
# e aqui que cor sorteada trocaria a cor da demanda antiga.
mkdir -p "$WSROOT/vizinha"
git -C "$MAIN" worktree add -q --detach "$WSROOT/vizinha/api" main
printf 'api\t%s\t-\tmain\n' "$MAIN" > "$WSROOT/vizinha/.workspace"
run open vizinha >/dev/null
cor3=$(jq -r '.settings["workbench.colorCustomizations"]["activityBar.background"]' "$WS/demanda-teste.code-workspace")
check "cor sobrevive ao nascimento de um vizinho" "$cor1" "$cor3"
corv=$(jq -r '.settings["workbench.colorCustomizations"]["activityBar.background"]' "$WSROOT/vizinha/vizinha.code-workspace")
check "arquivo do vizinho tambem tem cor" "cor" "$([ -n "$corv" ] && [ "$corv" != null ] && echo cor || echo vazia)"
check "o .code-workspace continua JSON valido" "0" \
  "$(jq -e . "$WS/demanda-teste.code-workspace" >/dev/null 2>&1; echo $?)"

git -C "$MAIN" worktree remove --force "$WS/api" 2>/dev/null
git -C "$MAIN" worktree remove --force "$WSROOT/vizinha/api" 2>/dev/null
rm -rf "$T" 2>/dev/null

printf '\n%s\n\n' "$([ $fail -eq 0 ] && echo 'TODOS OS TESTES PASSARAM' || echo 'HA TESTES FALHANDO')"
exit $fail
