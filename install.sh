#!/usr/bin/env bash
# install — põe o `workspace` no PATH e, opcionalmente, liga a camada Claude Code.
#
# Roda de duas formas, e as duas precisam funcionar:
#
#   curl -fsSL <raw>/install.sh | bash        máquina de outra pessoa, sem clone
#   ./install.sh                              dentro do repo clonado
#
# Sob `curl | bash` o stdin é o próprio script, então pergunta alguma pode sair
# de `read` no stdin: quando há terminal, a pergunta vai e volta por /dev/tty;
# quando não há, o instalador NÃO mexe no settings.json e imprime o que fazer.
# Mudar config de editor de alguém sem confirmação não é atalho aceitável.

set -euo pipefail

RAW_URL="${WORKSPACE_RAW_URL:-https://raw.githubusercontent.com/GabrielAlcantaraDev/workspace/main}"
BIN_DIR="${WORKSPACE_BIN_DIR:-$HOME/.local/bin}"
SKILL_DIR="$HOME/.claude/skills/workspace"
SETTINGS="$HOME/.claude/settings.json"

WITH_CLAUDE=ask
for arg in "$@"; do
  case $arg in
  --with-claude) WITH_CLAUDE=yes ;;
  --no-claude) WITH_CLAUDE=no ;;
  -h | --help)
    printf 'uso: install.sh [--with-claude|--no-claude]\n'
    exit 0
    ;;
  *)
    printf '  ✗ opção desconhecida: %s\n' "$arg" >&2
    exit 1
    ;;
  esac
done

say() { printf '  %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
bad() {
  printf '\n  ✗ %s\n\n' "$*" >&2
  exit 1
}

printf '\n  Instalando workspace\n\n'

# ---------------------------------------------------------------- pré-requisitos

# Antes de tudo: Git Bash tem bash, git e curl, e passaria em todas as checagens
# seguintes para entregar uma instalação que quebra no primeiro `create`. O
# motivo está no cabeçalho do workspace.sh — caminho POSIX não atravessa para o
# VSCode nem para o Docker do Windows.
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
  printf '  ✗ Git Bash e Cygwin não servem para esta ferramenta.\n\n' >&2
  printf '    No Windows, use o WSL:\n\n' >&2
  printf '      1. No PowerShell, como administrador:  wsl --install\n' >&2
  printf '      2. Abra o Ubuntu que ele instalar\n' >&2
  printf '      3. Rode esta mesma instalação lá dentro\n\n' >&2
  printf '    Mantenha também os repositórios dentro do WSL: repo no disco do\n' >&2
  printf '    Windows fica lento e dá problema de permissão.\n\n' >&2
  exit 1
  ;;
esac

command -v git >/dev/null 2>&1 || bad "git não está no PATH — instale o git antes"
command -v curl >/dev/null 2>&1 || bad "curl não está no PATH"

# O script alvo exige bash >= 4.4, e o macOS traz 3.2 em /bin/bash. Descobrir
# isso aqui é melhor do que a pessoa descobrir no primeiro comando.
bash_ok=0
for b in bash /usr/local/bin/bash /opt/homebrew/bin/bash; do
  command -v "$b" >/dev/null 2>&1 || continue
  v=$("$b" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"' 2>/dev/null) || continue
  maj=${v%%.*}
  min=${v##*.}
  if [ "$maj" -gt 4 ] || { [ "$maj" -eq 4 ] && [ "$min" -ge 4 ]; }; then
    bash_ok=1
    break
  fi
done
[ "$bash_ok" -eq 1 ] || bad "precisa de bash >= 4.4 (o do sistema é $BASH_VERSION).
       No macOS: brew install bash"

# ---------------------------------------------------------------- script

# Do clone quando existe ao lado; da rede quando veio por curl.
#
# Sob `curl | bash` (e `bash -s`) o BASH_SOURCE não existe, e com `set -u` isso
# aborta a linha. Vazio é a resposta certa ali — mas tem que ser vazio de
# propósito: `dirname ""` devolve ".", e aí um workspace.sh qualquer no diretório
# de onde a pessoa rodou o curl viraria a fonte da instalação.
HERE=''
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fi

fetch() {
  local rel=$1 dest=$2
  if [ -n "$HERE" ] && [ -f "$HERE/$rel" ]; then
    cp "$HERE/$rel" "$dest"
  else
    curl -fsSL "$RAW_URL/$rel" -o "$dest" || return 1
  fi
}

mkdir -p "$BIN_DIR"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

fetch workspace.sh "$tmp" || bad "não consegui obter o workspace.sh de $RAW_URL"
head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' || bad "o arquivo baixado não parece o script — nada foi instalado"
bash -n "$tmp" 2>/dev/null || bad "o script baixado não passou na checagem de sintaxe — nada foi instalado"

cat "$tmp" > "$BIN_DIR/workspace"
chmod +x "$BIN_DIR/workspace"
ok "workspace $("$BIN_DIR/workspace" --version) em $(printf '%s' "$BIN_DIR/workspace" | sed "s|$HOME|~|")"

# ---------------------------------------------------------------- PATH

case ":$PATH:" in
*":$BIN_DIR:"*) ok "já está no PATH" ;;
*)
  rc="$HOME/.bashrc"
  [ -n "${ZSH_VERSION:-}" ] || [ "$(basename -- "${SHELL:-}")" = zsh ] && rc="$HOME/.zshrc"
  printf '  ⚠  %s não está no PATH. Adicione ao %s:\n' \
    "$(printf '%s' "$BIN_DIR" | sed "s|$HOME|~|")" "$(printf '%s' "$rc" | sed "s|$HOME|~|")"
  printf '\n       export PATH="$HOME/.local/bin:$PATH"\n\n'
  ;;
esac

# ---------------------------------------------------------------- Claude Code

install_skill_files() {
  mkdir -p "$SKILL_DIR"
  local f
  for f in SKILL.md pin-hook.sh statusline.sh; do
    fetch "claude/$f" "$SKILL_DIR/$f" || return 1
  done
  chmod +x "$SKILL_DIR/pin-hook.sh" "$SKILL_DIR/statusline.sh"
  # A SKILL.md manda rodar o `workspace.sh` ao lado dela. Link em vez de cópia
  # para que `workspace update` valha para os dois de uma vez.
  ln -sf "$BIN_DIR/workspace" "$SKILL_DIR/workspace.sh" 2>/dev/null ||
    cp "$BIN_DIR/workspace" "$SKILL_DIR/workspace.sh"
}

# Insere statusline e os três hooks preservando o resto do arquivo. Idempotente:
# settings que já cita pin-hook.sh não é tocado. Nunca sobrescreve statusline de
# terceiro — quem já tem a sua fica com ela, e o instalador avisa.
merge_settings() {
  local runner=''
  command -v python3 >/dev/null 2>&1 && runner=python3
  [ -n "$runner" ] || { command -v jq >/dev/null 2>&1 && runner=jq; }
  [ -n "$runner" ] || return 2

  if [ -f "$SETTINGS" ] && grep -q 'pin-hook\.sh' "$SETTINGS" 2>/dev/null; then
    return 3
  fi
  [ -f "$SETTINGS" ] && cp "$SETTINGS" "$SETTINGS.bak-$(date +%Y%m%d%H%M%S)"

  if [ "$runner" = python3 ]; then
    SKILL_DIR="$SKILL_DIR" SETTINGS="$SETTINGS" python3 - <<'PY'
import json, os, sys

skill, path = os.environ['SKILL_DIR'], os.environ['SETTINGS']
pin, status = skill + '/pin-hook.sh', skill + '/statusline.sh'

try:
    with open(path) as fh:
        cfg = json.load(fh)
except (IOError, ValueError):
    cfg = {}

hooks = cfg.setdefault('hooks', {})


def add(event, matcher, cmd):
    entries = hooks.setdefault(event, [])
    inner = {'type': 'command', 'command': cmd, 'timeout': 10}
    entry = {'hooks': [inner]}
    if matcher:
        entry['matcher'] = matcher
    entries.append(entry)


add('PreToolUse', 'Write|Edit|NotebookEdit|Bash', pin + ' guard')
add('PostToolUse', 'Bash', pin + ' record')
add('SessionStart', None, pin + ' restore')

if 'statusLine' not in cfg:
    cfg['statusLine'] = {'type': 'command', 'command': status}
    kept = False
else:
    kept = True

with open(path, 'w') as fh:
    json.dump(cfg, fh, indent=2, ensure_ascii=False)
    fh.write('\n')

sys.exit(10 if kept else 0)
PY
    case $? in
    0) return 0 ;;
    10) return 4 ;;
    *) return 2 ;;
    esac
  fi

  local t
  t=$(mktemp)
  jq --arg pin "$SKILL_DIR/pin-hook.sh" --arg st "$SKILL_DIR/statusline.sh" '
    .hooks.PreToolUse  = ((.hooks.PreToolUse  // []) + [{matcher:"Write|Edit|NotebookEdit|Bash", hooks:[{type:"command", command:($pin+" guard"),   timeout:10}]}])
  | .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{matcher:"Bash",                        hooks:[{type:"command", command:($pin+" record"),  timeout:10}]}])
  | .hooks.SessionStart= ((.hooks.SessionStart// []) + [{                                        hooks:[{type:"command", command:($pin+" restore"), timeout:10}]}])
  | if .statusLine then . else .statusLine = {type:"command", command:$st} end
  ' "${SETTINGS:-/dev/null}" > "$t" 2>/dev/null || { rm -f "$t"; return 2; }
  mv "$t" "$SETTINGS"
}

if [ -d "$HOME/.claude" ]; then
  if [ "$WITH_CLAUDE" = ask ]; then
    resp=''
    if [ -e /dev/tty ]; then
      printf '\n  Achei o Claude Code aqui. Instalar a skill (/workspace no chat)\n'
      printf '  e ligar os hooks de fixação de aba? [S/n] '
      read -r resp < /dev/tty 2>/dev/null || resp=__sem_tty__
    else
      resp=__sem_tty__
    fi
    # Sem terminal (agente, CI, `curl | bash` sem tty) a resposta não vem. Aí não
    # se assume nada sobre o settings.json de ninguém — mas também não se sai
    # calado, senão a pessoa fica sem entender por que o /workspace não apareceu.
    if [ "$resp" = __sem_tty__ ]; then
      WITH_CLAUDE=no
      printf '\n  ⚠  Claude Code detectado, mas não há terminal para eu perguntar.\n'
      printf '     Instalei só o comando. Para acrescentar a skill e os hooks:\n'
      printf '       curl -fsSL %s/install.sh | bash -s -- --with-claude\n' "$RAW_URL"
    else
      case ${resp:-s} in [nN]*) WITH_CLAUDE=no ;; *) WITH_CLAUDE=yes ;; esac
    fi
  fi

  if [ "$WITH_CLAUDE" = yes ]; then
    printf '\n'
    if install_skill_files; then
      ok "skill em $(printf '%s' "$SKILL_DIR" | sed "s|$HOME|~|")"
    else
      printf '  ⚠  não consegui baixar os arquivos da skill — o comando de terminal está instalado do mesmo jeito\n'
    fi

    set +e
    merge_settings
    rc=$?
    set -e
    case $rc in
    0) ok "hooks e statusline ligados no settings.json (backup ao lado)" ;;
    3) ok "hooks já estavam ligados — settings.json não foi tocado" ;;
    4) ok "hooks ligados; sua statusLine foi preservada como estava" ;;
    *)
      printf '  ⚠  sem python3 nem jq: não mexi no settings.json.\n'
      printf '     Cole isto em %s para ligar a fixação de aba:\n\n' "$(printf '%s' "$SETTINGS" | sed "s|$HOME|~|")"
      cat <<JSON
       "statusLine": { "type": "command", "command": "$SKILL_DIR/statusline.sh" },
       "hooks": {
         "PreToolUse":   [{ "matcher": "Write|Edit|NotebookEdit|Bash",
                            "hooks": [{ "type": "command", "command": "$SKILL_DIR/pin-hook.sh guard",   "timeout": 10 }] }],
         "PostToolUse":  [{ "matcher": "Bash",
                            "hooks": [{ "type": "command", "command": "$SKILL_DIR/pin-hook.sh record",  "timeout": 10 }] }],
         "SessionStart": [{ "hooks": [{ "type": "command", "command": "$SKILL_DIR/pin-hook.sh restore", "timeout": 10 }] }]
       }
JSON
      printf '\n'
      ;;
    esac
  fi
fi

printf '\n  Pronto. Agora:\n\n'
printf '    workspace doctor      confere a máquina e aponta o que falta\n'
printf '    workspace setup       diz onde ficam seus repositórios (só se o doctor pedir)\n'
printf '    workspace help        o manual\n\n'
