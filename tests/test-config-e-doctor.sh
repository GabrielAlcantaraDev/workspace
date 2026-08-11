#!/usr/bin/env bash
# Exercita o que decide onde a ferramenta trabalha: deteccao de raizes,
# precedencia (env > config > deteccao), o config em disco, o doctor e as
# travas do update.
#
# Nada da maquina e tocado: HOME e XDG_CONFIG_HOME apontam para arvore
# descartavel, e o update so fala com file:// local.

set -u

SCRIPT=${1:-$HOME/.claude/skills/workspace/workspace.sh}

fail=0
check() {
  if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"
  else printf '  FALHA %s\n        esperado: %s\n        obtido:   %s\n' "$1" "$2" "$3"; fail=1; fi
}
contem() {
  case $3 in
  *"$2"*) printf '  ok    %s\n' "$1" ;;
  *) printf '  FALHA %s\n        esperava conter: %s\n        obtido:   %s\n' "$1" "$2" "$3"; fail=1 ;;
  esac
}
nao_contem() {
  case $3 in
  *"$2"*) printf '  FALHA %s\n        NAO devia conter: %s\n' "$1" "$2"; fail=1 ;;
  *) printf '  ok    %s\n' "$1" ;;
  esac
}

# HOME descartavel com N pastas de codigo, cada uma com um repo git dentro.
nova_casa() {
  local h d
  h=$(mktemp -d)
  for d in "$@"; do
    mkdir -p "$h/$d/repo-a/.git"
  done
  printf '%s\n' "$h"
}
run() {
  local h=$1; shift
  HOME="$h" XDG_CONFIG_HOME="$h/.config" bash "$SCRIPT" "$@" 2>&1
}

printf '\n== deteccao: uma pasta decide, zero e varias perguntam ==\n'

H=$(nova_casa dev)
out=$(run "$H" repos)
contem "uma pasta de codigo e adotada sozinha" "repo-a" "$out"
check "e gravada no config" "roots=$H/dev" "$(cat "$H/.config/workspace/config" 2>/dev/null)"

H=$(nova_casa)
out=$(run "$H" repos); rc=$?
check "sem pasta nenhuma: falha" 1 "$rc"
contem "sem pasta nenhuma: manda rodar o setup" "workspace setup" "$out"
nao_contem "sem pasta nenhuma: nao segue com lista vazia" "Repositórios disponíveis" "$out"

H=$(nova_casa dev code)
out=$(run "$H" repos); rc=$?
check "duas pastas: falha" 1 "$rc"
contem "duas pastas: nao adivinha" "não vou adivinhar" "$out"
check "duas pastas: nao grava config" "" "$(cat "$H/.config/workspace/config" 2>/dev/null)"

printf '\n== precedencia: env > config > deteccao ==\n'

H=$(nova_casa dev code)
mkdir -p "$H/.config/workspace" "$H/escolhida/repo-z/.git"
printf 'roots=%s\n' "$H/escolhida" > "$H/.config/workspace/config"
out=$(run "$H" repos)
contem "config desempata o que a deteccao nao resolve" "repo-z" "$out"

out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" WORKSPACE_ROOTS="$H/dev" bash "$SCRIPT" repos 2>&1)
contem "WORKSPACE_ROOTS ganha do config" "repo-a" "$out"
nao_contem "WORKSPACE_ROOTS ganha do config (o do config sai)" "repo-z" "$out"

printf '\n== config: editor migra do formato antigo ==\n'

H=$(nova_casa dev)
mkdir -p "$H/workspaces"
printf 'kiro\n' > "$H/workspaces/.editor"
out=$(run "$H" editor)
contem "editor antigo e lido" "kiro" "$out"
contem "e reportado como escolha salva" "escolha salva" "$out"
contem "migrou para o config" "editor=kiro" "$(cat "$H/.config/workspace/config")"
check "o arquivo antigo sai do caminho" "nao existe" \
  "$([ -f "$H/workspaces/.editor" ] && echo existe || echo 'nao existe')"

printf '\n== doctor: relata em vez de morrer ==\n'

H=$(nova_casa)
out=$(run "$H" doctor); rc=$?
check "doctor sem config nenhuma nao falha" 0 "$rc"
contem "doctor diz que nao sabe onde estao os repos" "workspace setup" "$out"
check "doctor nao grava config" "" "$(cat "$H/.config/workspace/config" 2>/dev/null)"

H=$(nova_casa dev)
out=$(run "$H" doctor)
contem "doctor conta os repositorios" "1 repositórios encontrados" "$out"
contem "doctor mostra a versao" "workspace " "$out"

printf '\n== update: so troca o script se o que chegou for script ==\n'

H=$(nova_casa dev)
COPIA="$H/workspace-copia.sh"
cp "$SCRIPT" "$COPIA"
LIXO=$(mktemp -d)
printf '<html>404</html>\n' > "$LIXO/workspace.sh"
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" WORKSPACE_RAW_URL="file://$LIXO" bash "$COPIA" update 2>&1); rc=$?
check "html no lugar do script: falha" 1 "$rc"
contem "html no lugar do script: diz que nao trocou" "nada foi trocado" "$out"
check "html no lugar do script: o script segue intacto" "$(md5sum < "$SCRIPT")" "$(md5sum < "$COPIA")"

QUEBRADO=$(mktemp -d)
{ printf '#!/usr/bin/env bash\n'; printf 'if [ 1 = 1 ; then echo oi\n'; } > "$QUEBRADO/workspace.sh"
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" WORKSPACE_RAW_URL="file://$QUEBRADO" bash "$COPIA" update 2>&1); rc=$?
check "script com sintaxe quebrada: falha" 1 "$rc"
contem "script com sintaxe quebrada: diz que nao trocou" "nada foi trocado" "$out"
check "script com sintaxe quebrada: o script segue intacto" "$(md5sum < "$SCRIPT")" "$(md5sum < "$COPIA")"

MESMA=$(mktemp -d)
cp "$SCRIPT" "$MESMA/workspace.sh"
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" WORKSPACE_RAW_URL="file://$MESMA" bash "$COPIA" update 2>&1)
contem "mesma versao: nao troca a toa" "última versão" "$out"

printf '\n== setup: nao trava sessao sem terminal ==\n'

H=$(nova_casa dev)
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" bash "$SCRIPT" setup < /dev/null 2>&1); rc=$?
check "setup sem tty: falha em vez de esperar" 1 "$rc"
contem "setup sem tty: ensina a saida por env" "WORKSPACE_ROOTS" "$out"

printf '\n'
if [ "$fail" -eq 0 ]; then printf 'TODOS OS TESTES PASSARAM\n\n'; else printf 'HOUVE FALHAS\n\n'; fi
exit "$fail"
