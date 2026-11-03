#!/usr/bin/env bash
# Exercita o install_deps: o token de registry privado e o que acontece quando
# a instalacao falha.
#
# O motivo deste arquivo: um worktree de repo com dependencia no GitHub
# Packages nascia sem os pacotes, e a unica pista era "npm ci falhou". O 401
# ficava escondido no /dev/null.
#
# Nada da maquina e tocado: npm e gh sao dublês num PATH descartavel.

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
  *"$2"*) printf '  FALHA %s\n        NAO devia conter: %s\n        obtido: %s\n' "$1" "$2" "$3"; fail=1 ;;
  *) printf '  ok    %s\n' "$1" ;;
  esac
}

# So as funcoes que interessam, sem disparar o dispatcher do fim do script.
extrai() { sed -n "/^$1()/,/^}/p" "$SCRIPT"; }
eval "$(grep -m1 '^warn()' "$SCRIPT")"
eval "$(extrai pkg_mgr)"
eval "$(extrai pkg_declared)"
eval "$(extrai install_deps)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"

# Dublê do npm: registra o token que recebeu e falha sob encomenda.
cat > "$BIN/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${NODE_AUTH_TOKEN-<ausente>}" > "$REG_TOKEN"
if [ -n "${NPM_FALHA:-}" ]; then
  printf 'npm error code E401\n' >&2
  printf 'npm error 401 Unauthorized - GET https://npm.pkg.github.com/@acme%%2fsdk\n' >&2
  [ -n "${NPM_VAZA_TOKEN:-}" ] && printf 'npm error usou %s\n' "${NODE_AUTH_TOKEN-}" >&2
  exit 1
fi
printf 'added 412 packages in 9s\n'
exit 0
EOF
chmod +x "$BIN/npm"

cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = token ] && { printf 'tok-do-gh\n'; exit 0; }
exit 1
EOF
chmod +x "$BIN/gh"

# Repo npm com lockfile (vira `npm ci`) e sem packageManager (sem corepack).
REPO="$TMP/repo"; mkdir -p "$REPO"
printf '{"name":"r","version":"1.0.0"}\n' > "$REPO/package.json"
printf '{}\n' > "$REPO/package-lock.json"

export REG_TOKEN="$TMP/token-visto"

roda() { # roda [VAR=val ...] -> ecoa a saida de install_deps
  : > "$REG_TOKEN"
  env PATH="$BIN:/usr/bin:/bin" "$@" \
    bash -c 'eval "$FUNCS"; install_deps "$1" "repo-teste" 2>&1' _ "$REPO"
}
export FUNCS="$(grep -m1 '^warn()' "$SCRIPT"; extrai pkg_mgr; extrai pkg_declared; extrai install_deps)"

printf '\n== token de registry privado ==\n'

out=$(roda NODE_AUTH_TOKEN=)
check "sem token no ambiente, pega o do gh" "tok-do-gh" "$(cat "$REG_TOKEN")"

out=$(roda NODE_AUTH_TOKEN=tok-do-usuario)
check "token ja exportado manda, o gh nao atropela" "tok-do-usuario" "$(cat "$REG_TOKEN")"

# PATH com npm mas sem gh: a maquina de quem nunca instalou o gh.
mkdir -p "$TMP/so-npm" && cp "$BIN/npm" "$TMP/so-npm/npm"
out=$(roda PATH="$TMP/so-npm:/usr/bin:/bin" NODE_AUTH_TOKEN=)
contem "sem gh e sem token, ainda instala" "✓" "$out"

printf '\n== a falha precisa aparecer ==\n'

out=$(roda NODE_AUTH_TOKEN=tok NPM_FALHA=1)
contem "mostra a saida real do comando" "401 Unauthorized" "$out"
contem "diz onde rodar na mao" "rode na mão" "$out"

out=$(roda NODE_AUTH_TOKEN= NPM_FALHA=1)
contem "falha de auth ensina a ampliar o escopo" "read:packages" "$out"

out=$(roda NODE_AUTH_TOKEN=tok-secreto NPM_FALHA=1 NPM_VAZA_TOKEN=1)
nao_contem "nunca imprime o token" "tok-secreto" "$out"

printf '\n== sucesso continua quieto ==\n'

out=$(roda NODE_AUTH_TOKEN=tok)
nao_contem "nao despeja a saida do install quando da certo" "added 412 packages" "$out"
contem "anuncia o comando que rodou" "npm ci" "$out"

printf '\n'
exit "$fail"
