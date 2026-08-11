#!/usr/bin/env bash
# Exercita o pin-hook: gravacao do pino, recusa fora da demanda, liberacao
# dentro dela, a assimetria entre Write/Edit e Bash, e o caminho rapido.
#
# O caminho rapido e o teste que mais importa: este hook roda em TODA chamada de
# ferramenta da maquina, e aba sem pino nao pode ser afetada por nada.
set -u

HOOK=${1:-$HOME/.claude/skills/workspace/pin-hook.sh}
T=$(mktemp -d)
WSROOT="$T/workspaces"
CLONE="$T/repos/api"

hook() { WORKSPACES_ROOT="$WSROOT" XDG_CONFIG_HOME="$T/.config" bash "$HOOK" "$@"; }

fail=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
  else printf '  FALHA %s\n        esperado: %s\n        obtido:   %s\n' "$1" "$2" "$3"; fail=1; fi
}
# Roda o guard e devolve 'deny' ou 'passa'.
guard() {
  local r
  r=$(printf '%s' "$1" | hook guard | jq -r '.hookSpecificOutput.permissionDecision // "passa"' 2>/dev/null)
  printf '%s' "${r:-passa}"
}
edit_em() { printf '{"session_id":"s1","tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1"; }
bash_com() { printf '{"session_id":"s1","tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"; }

printf '\n== preparo: duas demandas sobre o mesmo clone principal ==\n'
mkdir -p "$CLONE" "$WSROOT/demanda-a/api" "$WSROOT/demanda-b/api"
printf 'api\t%s\t-\tmain\n' "$CLONE" > "$WSROOT/demanda-a/.workspace"
cp "$WSROOT/demanda-a/.workspace" "$WSROOT/demanda-b/.workspace"

printf '\n== caminho rapido: aba sem pino nao e tocada ==\n'
check "sem pino, edicao em outra demanda passa" "passa" "$(guard "$(edit_em "$WSROOT/demanda-b/api/x.ts")")"
check "sem pino, comando em outra demanda passa" "passa" "$(guard "$(bash_com "cat $WSROOT/demanda-b/x")")"

printf '\n== record: grava o pino a partir da linha de comando ==\n'
printf '%s' "$(bash_com "/qualquer/caminho/workspace.sh use demanda-a")" | hook record >/dev/null
check "pino gravado com o nome da demanda" "demanda-a" "$(cat "$WSROOT/.pins/s1" 2>/dev/null)"
printf '%s' "$(bash_com "workspace.sh use nao-existe")" | hook record >/dev/null
check "workspace inexistente nao sobrescreve o pino" "demanda-a" "$(cat "$WSROOT/.pins/s1" 2>/dev/null)"
printf '%s' "$(bash_com "workspace.sh use")" | hook record >/dev/null
check "use sem nome (caixa de selecao) nao mexe no pino" "demanda-a" "$(cat "$WSROOT/.pins/s1" 2>/dev/null)"

printf '\n== guard: Write/Edit e estrito ==\n'
check "edicao na propria demanda passa" "passa" "$(guard "$(edit_em "$WSROOT/demanda-a/api/x.ts")")"
check "edicao em outra demanda e negada" "deny" "$(guard "$(edit_em "$WSROOT/demanda-b/api/x.ts")")"
check "edicao no clone principal e negada" "deny" "$(guard "$(edit_em "$CLONE/src/x.ts")")"
check "edicao fora de tudo passa" "passa" "$(guard "$(edit_em "$T/avulso.md")")"

printf '\n== guard: Bash barra a outra demanda, mas nao o clone principal ==\n'
check "comando tocando outra demanda e negado" "deny" "$(guard "$(bash_com "cat $WSROOT/demanda-b/api/x.ts")")"
check "git no clone principal passa (comparar com a base e rotina)" "passa" "$(guard "$(bash_com "git -C $CLONE log -1")")"
check "workspace.sh sobre outra demanda passa (down/status/stop)" "passa" "$(guard "$(bash_com "/x/workspace.sh down demanda-b")")"

printf '\n== restore: o pino sobrevive a compactacao ==\n'
ctx=$(printf '{"session_id":"s1","source":"compact"}' | hook restore | jq -r '.hookSpecificOutput.additionalContext')
check "reinjecao cita a demanda fixada" "cita" "$(printf '%s' "$ctx" | grep -q 'demanda-a' && echo cita || echo omite)"

printf '\n== pino sem dono: demanda derrubada com a aba aberta ==\n'
printf 'demanda-sumida\n' > "$WSROOT/.pins/s1"
check "pino apontando para demanda inexistente nao trava nada" "passa" "$(guard "$(edit_em "$WSROOT/demanda-b/api/x.ts")")"
check "e o pino orfao e apagado" "ausente" "$([ -f "$WSROOT/.pins/s1" ] && echo presente || echo ausente)"

printf '\n== use none e o desligador ==\n'
printf '%s' "$(bash_com "workspace.sh use demanda-a")" | hook record >/dev/null
printf '%s' "$(bash_com "workspace.sh use none")" | hook record >/dev/null
check "use none apaga o pino" "ausente" "$([ -f "$WSROOT/.pins/s1" ] && echo presente || echo ausente)"
printf '%s' "$(bash_com "workspace.sh use demanda-a")" | hook record >/dev/null
r=$(printf '%s' "$(edit_em "$WSROOT/demanda-b/x.ts")" | WORKSPACE_PIN=0 WORKSPACES_ROOT="$WSROOT" bash "$HOOK" guard | jq -r '.hookSpecificOutput.permissionDecision // "passa"' 2>/dev/null)
check "WORKSPACE_PIN=0 desliga a trava" "passa" "${r:-passa}"

rm -rf "$T" 2>/dev/null

printf '\n%s\n\n' "$([ $fail -eq 0 ] && echo 'TODOS OS TESTES PASSARAM' || echo 'HA TESTES FALHANDO')"
exit $fail
