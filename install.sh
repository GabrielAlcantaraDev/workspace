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

KIRO_STEERING="$HOME/.kiro/steering/workspace.md"
CODEX_AGENTS="$HOME/.codex/AGENTS.md"

WITH_AGENTS=ask
for arg in "$@"; do
  case $arg in
  --with-agents | --with-claude) WITH_AGENTS=yes ;; # --with-claude: nome antigo
  --no-agents | --no-claude) WITH_AGENTS=no ;;
  -h | --help)
    printf 'uso: install.sh [--with-agents|--no-agents]\n'
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

# ---- Kiro: arquivo de steering no nível do usuário.
#
# Ganha o frontmatter que o Kiro espera; o corpo é o mesmo dos outros agentes,
# em agents/workspace.md, para os três não divergirem com o tempo.
install_kiro() {
  local body
  [ -d "$HOME/.kiro" ] || return 1
  body=$(mktemp)
  fetch agents/workspace.md "$body" || { rm -f "$body"; return 1; }
  mkdir -p "$(dirname "$KIRO_STEERING")"
  {
    printf -- '---\n'
    printf 'name: workspace\n'
    printf 'description: Ambientes de código isolados por demanda (git worktree por repositório, dependências, portas e editor). Use quando pedirem um workspace, um ambiente para desenvolver, mexer em duas demandas em paralelo, ou listar/subir/parar/derrubar ambientes.\n'
    printf 'inclusion: always\n'
    printf -- '---\n\n'
    cat "$body"
  } > "$KIRO_STEERING"
  rm -f "$body"
}

# ---- Codex: bloco delimitado dentro do AGENTS.md global.
#
# Este arquivo é da pessoa e costuma ter instrução dela dentro. Sobrescrever
# seria apagar trabalho alheio — então o bloco entra entre marcadores, e uma
# reinstalação troca só o que está entre eles. O resto do arquivo nunca é lido
# nem reescrito fora dessa faixa.
install_codex() {
  local body ini fim tmp
  [ -d "$HOME/.codex" ] || return 1
  ini='<!-- workspace:inicio -->'
  fim='<!-- workspace:fim -->'
  body=$(mktemp)
  fetch agents/workspace.md "$body" || { rm -f "$body"; return 1; }

  tmp=$(mktemp)
  if [ -f "$CODEX_AGENTS" ] && grep -qF "$ini" "$CODEX_AGENTS"; then
    # Troca só o miolo, preservando tudo antes e depois dos marcadores.
    awk -v ini="$ini" -v fim="$fim" -v corpo="$body" '
      $0 == ini { print; while ((getline linha < corpo) > 0) print linha; pulando = 1; next }
      $0 == fim { pulando = 0 }
      !pulando  { print }
    ' "$CODEX_AGENTS" > "$tmp"
  else
    [ -f "$CODEX_AGENTS" ] && cat "$CODEX_AGENTS" > "$tmp"
    [ -s "$tmp" ] && printf '\n' >> "$tmp"
    {
      printf '%s\n' "$ini"
      cat "$body"
      printf '%s\n' "$fim"
    } >> "$tmp"
  fi
  mkdir -p "$(dirname "$CODEX_AGENTS")"
  cat "$tmp" > "$CODEX_AGENTS"
  rm -f "$tmp" "$body"
}

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

# Quais agentes existem nesta máquina. Só o que existe é oferecido: perguntar
# sobre ferramenta que a pessoa não usa é ruído.
achados=''
[ -d "$HOME/.claude" ] && achados="$achados Claude Code,"
[ -d "$HOME/.kiro" ] && achados="$achados Kiro,"
[ -d "$HOME/.codex" ] && achados="$achados Codex,"
achados=${achados%,}

if [ -n "$achados" ]; then
  if [ "$WITH_AGENTS" = ask ]; then
    resp=''
    # Testa se dá para LER do tty antes de perguntar. `[ -e /dev/tty ]` não
    # basta: o arquivo existe em sessão sem terminal de controle, e aí a
    # pergunta ia para a tela seguida do erro de abertura — pergunta que
    # ninguém pode responder é pior do que pergunta nenhuma.
    if { : < /dev/tty; } 2>/dev/null; then
      printf '\n  Achei aqui:%s\n' "$achados"
      printf '  Ensinar a ferramenta a eles, para você pedir em linguagem natural? [S/n] '
      { read -r resp < /dev/tty; } 2>/dev/null || resp=__sem_tty__
    else
      resp=__sem_tty__
    fi
    # Sem terminal (agente, CI, `curl | bash` sem tty) a resposta não vem. Aí não
    # se assume nada sobre a config de ninguém — mas também não se sai calado,
    # senão a pessoa fica sem entender por que o agente não conhece o comando.
    if [ "$resp" = __sem_tty__ ]; then
      WITH_AGENTS=no
      printf '\n  ⚠  Achei%s, mas não há terminal para eu perguntar.\n' "$achados"
      printf '     Instalei só o comando. Para ensinar aos agentes:\n'
      printf '       curl -fsSL %s/install.sh | bash -s -- --with-agents\n' "$RAW_URL"
    else
      case ${resp:-s} in [nN]*) WITH_AGENTS=no ;; *) WITH_AGENTS=yes ;; esac
    fi
  fi

  if [ "$WITH_AGENTS" = yes ]; then
    printf '\n'

    if [ -d "$HOME/.kiro" ]; then
      if install_kiro; then
        ok "Kiro: steering em $(printf '%s' "$KIRO_STEERING" | sed "s|$HOME|~|")"
      else
        printf '  ⚠  Kiro: não consegui escrever o steering\n'
      fi
    fi

    if [ -d "$HOME/.codex" ]; then
      if install_codex; then
        ok "Codex: bloco em $(printf '%s' "$CODEX_AGENTS" | sed "s|$HOME|~|") (o resto do arquivo intacto)"
      else
        printf '  ⚠  Codex: não consegui escrever o AGENTS.md\n'
      fi
    fi
  fi
fi

if [ -d "$HOME/.claude" ]; then
  if [ "$WITH_AGENTS" = yes ]; then
    if install_skill_files; then
      ok "Claude Code: skill em $(printf '%s' "$SKILL_DIR" | sed "s|$HOME|~|")"
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
