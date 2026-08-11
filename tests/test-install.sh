#!/usr/bin/env bash
# Exercita o instalador nos dois modos em que ele roda de verdade:
#
#   bash install.sh                 dentro do repo clonado
#   cat install.sh | bash -s -- …   o caminho do `curl | bash`
#
# O segundo existe porque nele o BASH_SOURCE nao esta definido e o stdin nao e
# terminal — foi ali que apareceu o "BASH_SOURCE[0]: variavel nao associada",
# que o primeiro modo nunca mostraria.
#
# Nada da maquina e tocado: HOME descartavel e WORKSPACE_RAW_URL em file://.

set -u

BASE=${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}
INSTALL="$BASE/install.sh"
# Lida do script, nunca fixada: bump de versao nao pode quebrar teste de instalacao.
VER=$(grep -m1 "^VERSION=" "$BASE/workspace.sh" | cut -d'"' -f2)

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

nova_casa() {
  local h
  h=$(mktemp -d)
  mkdir -p "$h/dev/api/.git" "$h/.claude"
  printf '%s\n' "$h"
}

printf '\n== modo arquivo: bash install.sh ==\n'

H=$(nova_casa)
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" bash "$INSTALL" --with-claude 2>&1)
contem "instala o comando" "em ~/.local/bin/workspace" "$out"
contem "instala a skill" "skill em ~/.claude/skills/workspace" "$out"
nao_contem "modo arquivo nao precisa de rede" "não consegui" "$out"
check "o binario existe e roda" "$VER" "$(HOME="$H" bash "$H/.local/bin/workspace" --version 2>&1)"

printf '\n== modo pipe: cat install.sh | bash -s (o caminho do curl) ==\n'

H=$(nova_casa)
out=$(cat "$INSTALL" | HOME="$H" XDG_CONFIG_HOME="$H/.config" WORKSPACE_RAW_URL="file://$BASE" \
  bash -s -- --with-claude 2>&1)
nao_contem "sem erro de BASH_SOURCE nao associado" "BASH_SOURCE" "$out"
nao_contem "sem erro de variavel nao associada" "unbound variable" "$out"
contem "instala o comando" "em ~/.local/bin/workspace" "$out"
contem "instala a skill mesmo sem tty, com a flag" "skill em ~/.claude/skills/workspace" "$out"
check "o binario existe e roda" "$VER" "$(HOME="$H" bash "$H/.local/bin/workspace" --version 2>&1)"

printf '\n== modo pipe sem a flag: nao mexe no settings.json calado ==\n'

H=$(nova_casa)
out=$(cat "$INSTALL" | HOME="$H" XDG_CONFIG_HOME="$H/.config" WORKSPACE_RAW_URL="file://$BASE" \
  bash -s 2>&1)
contem "avisa que nao havia terminal para perguntar" "não há terminal" "$out"
contem "ensina como acrescentar depois" "--with-agents" "$out"
nao_contem "nao imprime pergunta que ninguem pode responder" "[S/n]" "$out"
nao_contem "nao vaza erro de /dev/tty" "/dev/tty" "$out"
check "settings.json nao foi criado" "nao existe" \
  "$([ -f "$H/.claude/settings.json" ] && echo existe || echo 'nao existe')"

printf '\n== o diretorio de onde se roda nao contamina a instalacao ==\n'

# Um workspace.sh impostor no CWD nao pode virar a fonte quando veio por pipe.
H=$(nova_casa)
IMPOSTOR=$(mktemp -d)
printf '#!/usr/bin/env bash\necho IMPOSTOR\n' > "$IMPOSTOR/workspace.sh"
out=$(cd "$IMPOSTOR" && cat "$INSTALL" | HOME="$H" XDG_CONFIG_HOME="$H/.config" \
  WORKSPACE_RAW_URL="file://$BASE" bash -s -- --no-claude 2>&1)
check "instalou o script de verdade, nao o do diretorio atual" "$VER" \
  "$(HOME="$H" bash "$H/.local/bin/workspace" --version 2>&1)"

printf '\n== idempotencia: instalar de novo nao duplica hook ==\n'

H=$(nova_casa)
for _ in 1 2 3; do
  HOME="$H" XDG_CONFIG_HOME="$H/.config" WORKSPACE_RAW_URL="file://$BASE" \
    bash "$INSTALL" --with-claude >/dev/null 2>&1
done
if command -v python3 >/dev/null 2>&1; then
  n=$(python3 -c "
import json
c=json.load(open('$H/.claude/settings.json'))
print(sum(len(v) for v in c['hooks'].values()))" 2>&1)
  check "3 instalacoes deixam 3 hooks, nao 9" "3" "$n"
fi

printf '\n== recusa o que nao e script ==\n'

# Pelo pipe, de proposito: em modo arquivo o instalador usa o clone ao lado dele
# e nem chega a olhar a WORKSPACE_RAW_URL, entao a rejeicao nao seria exercitada.
H=$(nova_casa)
LIXO=$(mktemp -d)
printf '<html>404</html>\n' > "$LIXO/workspace.sh"
out=$(cat "$INSTALL" | HOME="$H" XDG_CONFIG_HOME="$H/.config" WORKSPACE_RAW_URL="file://$LIXO" \
  bash -s -- --no-claude 2>&1); rc=$?
check "html no lugar do script: falha" 1 "$rc"
contem "html no lugar do script: diz que nao instalou" "nada foi instalado" "$out"
check "html no lugar do script: nada foi para o PATH" "nao existe" \
  "$([ -f "$H/.local/bin/workspace" ] && echo existe || echo 'nao existe')"

printf '\n== agentes: Kiro, Codex e Claude Code na mesma instalacao ==\n'

# O AGENTS.md do Codex e arquivo DA PESSOA e costuma ter instrucao dela dentro.
# Sobrescrever seria apagar trabalho alheio, entao o bloco entra entre
# marcadores — e o teste guarda conteudo antes E depois do bloco de proposito.
H=$(mktemp -d); mkdir -p "$H/dev/api/.git" "$H/.claude" "$H/.kiro" "$H/.codex"
printf '# Regras da pessoa\n\nSempre responder em portugues.\n' > "$H/.codex/AGENTS.md"
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" bash "$INSTALL" --with-agents 2>&1)
contem "instala o steering do Kiro" "Kiro: steering em" "$out"
contem "instala o bloco do Codex" "Codex: bloco em" "$out"
contem "instala a skill do Claude Code" "Claude Code: skill em" "$out"
check "steering do Kiro existe" "existe" \
  "$([ -f "$H/.kiro/steering/workspace.md" ] && echo existe || echo 'nao existe')"
contem "steering do Kiro tem o frontmatter" "inclusion: always" "$(cat "$H/.kiro/steering/workspace.md")"
contem "AGENTS.md preservou o que era da pessoa" "Sempre responder em portugues" "$(cat "$H/.codex/AGENTS.md")"

printf '\n== agentes: reinstalar nao duplica nem come o arquivo da pessoa ==\n'

printf '\n# Rodape\n\nIsto vem depois do bloco.\n' >> "$H/.codex/AGENTS.md"
for _ in 1 2 3; do
  HOME="$H" XDG_CONFIG_HOME="$H/.config" bash "$INSTALL" --with-agents >/dev/null 2>&1
done
check "um unico bloco, nao quatro" "1" "$(grep -c 'workspace:inicio' "$H/.codex/AGENTS.md")"
check "o texto anterior ao bloco continua la" "1" "$(grep -c 'Regras da pessoa' "$H/.codex/AGENTS.md")"
check "o texto POSTERIOR ao bloco tambem" "1" "$(grep -c 'Isto vem depois do bloco' "$H/.codex/AGENTS.md")"
check "steering do Kiro nao acumula frontmatter" "1" \
  "$(grep -c '^name: workspace' "$H/.kiro/steering/workspace.md")"

printf '\n== agentes: so mexe no que existe na maquina ==\n'

H=$(mktemp -d); mkdir -p "$H/dev/api/.git" "$H/.kiro" # so o Kiro
out=$(HOME="$H" XDG_CONFIG_HOME="$H/.config" bash "$INSTALL" --with-agents 2>&1)
contem "instala o Kiro" "Kiro: steering em" "$out"
nao_contem "nao inventa Codex" "Codex:" "$out"
nao_contem "nao inventa Claude Code" "Claude Code:" "$out"
check "nao criou ~/.codex do nada" "nao existe" \
  "$([ -d "$H/.codex" ] && echo existe || echo 'nao existe')"

printf '\n== Windows fora do WSL: recusa em vez de instalar meio funcionando ==\n'

# `uname` falso no PATH, que e como o Git Bash se identifica. Vale para o
# instalador e para o proprio comando: os dois precisam recusar sozinhos.
FAKE=$(mktemp -d)
printf '#!/usr/bin/env bash\necho MINGW64_NT-10.0-22631\n' > "$FAKE/uname"
chmod +x "$FAKE/uname"

H=$(nova_casa)
out=$(PATH="$FAKE:$PATH" HOME="$H" XDG_CONFIG_HOME="$H/.config" bash "$INSTALL" --no-claude 2>&1); rc=$?
check "instalador recusa no Git Bash" 1 "$rc"
contem "instalador manda usar o WSL" "wsl --install" "$out"
check "instalador nao deixa nada no PATH" "nao existe" \
  "$([ -f "$H/.local/bin/workspace" ] && echo existe || echo 'nao existe')"

out=$(PATH="$FAKE:$PATH" HOME="$H" bash "$BASE/workspace.sh" list 2>&1); rc=$?
check "o proprio comando recusa no Git Bash" 1 "$rc"
contem "e explica por que (caminho POSIX nao atravessa)" "VSCode" "$out"

printf '\n'
if [ "$fail" -eq 0 ]; then printf 'TODOS OS TESTES PASSARAM\n\n'; else printf 'HOUVE FALHAS\n\n'; fi
exit "$fail"
