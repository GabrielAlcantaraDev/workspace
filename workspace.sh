#!/usr/bin/env bash
# workspace — provisiona ambientes de código isolados em N repositórios via git worktree.
#
# Uso:
#   workspace.sh create [--name <nome>] <repo> [<repo> ...]   cria um workspace
#   workspace.sh open <nome>                                  reabre no VSCode
#   workspace.sh use <nome>                                   briefing p/ fixar a aba de chat
#   workspace.sh status [<nome>]                              o que está de pé
#   workspace.sh start <nome> [--only a,b] [--force]          sobe os apps
#   workspace.sh stop <nome>                                  para o que subiu
#   workspace.sh down <nome> [--force]                        para, remove worktrees e pasta
#   workspace.sh list                                         workspaces ativos
#   workspace.sh prune                                        limpa registro órfão
#   workspace.sh top [N]                                      ranking p/ a caixa de seleção
#   workspace.sh repos                                        catálogo de repositórios
#
# Env:
#   WORKSPACE_ROOTS     raízes onde procurar repos, separadas por ':'
#   WORKSPACES_ROOT     raiz onde moram os workspaces         (default ~/workspaces)
#   WORKSPACE_IGNORE    glob de caminhos a ignorar na busca   (default *_copy*)
#   WORKSPACE_MAXDEPTH  profundidade da busca                 (default 4)
#   WORKSPACE_ENV_FILES arquivos de env a copiar, separados por ':'
#   WORKSPACE_CLOSE_EDITOR  0 para o down não fechar a janela do editor
#
# Sem WORKSPACE_ROOTS, as raízes saem do config (~/.config/workspace/config) ou
# da auto-detecção das pastas comuns de código. `workspace setup` grava a escolha.
#
# Flags de create:
#   --no-open      não abre o VSCode
#   --no-install   não instala dependências
#
# Flags de down:
#   --force        descarta trabalho não integrado
#   --keep-editor  não fecha a janela do editor

set -euo pipefail

# set -u + expansão de array vazio quebra em bash < 4.4 (o 3.2 do macOS).
# Melhor recusar com instrução do que falhar com mensagem críptica no meio.
if [ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }; then
  printf '  ✗ precisa de bash >= 4.4 (este é %s). No macOS: brew install bash\n' "$BASH_VERSION" >&2
  exit 1
fi

# Git Bash e Cygwin trazem bash, e é exatamente por isso que a recusa precisa
# ser explícita: ter bash não basta. Quase tudo que importa aqui atravessa a
# fronteira do bash e cai num programa do Windows, que não entende caminho
# POSIX — o `.code-workspace` vai para o VSCode, o bind mount vai para o Docker,
# e `/c/Users/...` não significa nada para nenhum dos dois. Meio funcionando é
# pior do que não instalar, porque o estrago aparece depois do worktree criado.
#
# No WSL isto é Linux de verdade (uname diz Linux) e passa direto, que é o
# caminho recomendado para quem está no Windows.
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
  printf '\n  ✗ Git Bash e Cygwin não servem para esta ferramenta.\n\n' >&2
  printf '    Ela entrega caminho para o VSCode e para o Docker, e o caminho\n' >&2
  printf '    do Git Bash (/c/Users/...) não é entendido por nenhum dos dois.\n\n' >&2
  printf '    No Windows, use o WSL:\n\n' >&2
  printf '      1. No PowerShell, como administrador:  wsl --install\n' >&2
  printf '      2. Abra o Ubuntu que ele instalar\n' >&2
  printf '      3. Rode a instalação lá dentro, e clone seus repos lá dentro\n\n' >&2
  printf '    Repo clonado no disco do Windows e usado pelo WSL fica lento e\n' >&2
  printf '    quebra permissão — vale manter tudo dentro do WSL.\n\n' >&2
  exit 1
  ;;
esac

VERSION="1.0.1"
RAW_URL="${WORKSPACE_RAW_URL:-https://raw.githubusercontent.com/GabrielAlcantaraDev/workspace/main}"

die() { printf '\n  ✗ %s\n' "$*" >&2; exit 1; }
warn() { printf '  ⚠  %s\n' "$*"; }

# ---------------------------------------------------------------- config
#
# Fica fora de WORKSPACES_ROOT de propósito: a raiz dos workspaces é uma das
# coisas que o config guarda, e config dentro do que ele configura não resolve
# a primeira execução de quem mudou a raiz de lugar.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/workspace"
CONFIG_FILE="$CONFIG_DIR/config"

# Valor de uma chave (roots, workspaces_root, editor); vazio quando não há.
config_get() {
  [ -f "$CONFIG_FILE" ] || return 0
  awk -F= -v k="$1" '$1==k { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG_FILE"
}

# Grava uma chave preservando as outras.
config_set() {
  local k=$1 v=$2 tmp
  mkdir -p "$CONFIG_DIR"
  tmp=$(mktemp)
  if [ -f "$CONFIG_FILE" ]; then grep -v "^$k=" "$CONFIG_FILE" > "$tmp" 2>/dev/null || true; fi
  printf '%s=%s\n' "$k" "$v" >> "$tmp"
  mv "$tmp" "$CONFIG_FILE"
}

WS_ROOT="${WORKSPACES_ROOT:-$(config_get workspaces_root)}"
WS_ROOT="${WS_ROOT:-$HOME/workspaces}"
IGNORE="${WORKSPACE_IGNORE:-*_copy*}"
MAXDEPTH="${WORKSPACE_MAXDEPTH:-4}"
# Imagem descartável que apaga o que o container escreveu como root.
CLEAN_IMAGE="${WORKSPACE_CLEAN_IMAGE:-alpine:3}"

# Arquivos ignorados pelo git que o worktree precisa para o app subir.
if [ -n "${WORKSPACE_ENV_FILES:-}" ]; then
  IFS=':' read -r -a ENV_FILES <<< "$WORKSPACE_ENV_FILES"
else
  ENV_FILES=(.env .env.local .env.development .env.development.local)
fi

# ---------------------------------------------------------------- raízes
#
# Onde procurar os repositórios. Preenchido sob demanda (ensure_roots), não na
# partida: `help`, `doctor`, `setup` e `--version` precisam rodar em máquina
# ainda não configurada.
ROOTS=""

# Pastas comuns de código que existem e contêm ao menos um repositório git.
detect_roots() {
  local c p
  for c in dev code projects src work repos git; do
    p="$HOME/$c"
    [ -d "$p" ] || continue
    [ -n "$(find "$p" -maxdepth 3 -name .git 2>/dev/null | head -1)" ] && printf '%s\n' "$p"
  done
  return 0
}

# Precedência: WORKSPACE_ROOTS > config > auto-detecção.
#
# Auto-detecção que acha UMA pasta decide sozinha e grava — é o caso comum, e
# perguntar o óbvio é atrito. Zero ou várias exige decisão humana: `setup` no
# terminal, ou WORKSPACE_ROOTS no ambiente. Não adivinha entre duas.
ensure_roots() {
  local found n
  [ -z "$ROOTS" ] || return 0

  if [ -n "${WORKSPACE_ROOTS:-}" ]; then
    ROOTS="$WORKSPACE_ROOTS"
    return 0
  fi

  ROOTS=$(config_get roots)
  [ -z "$ROOTS" ] || return 0

  found=$(detect_roots)
  n=$(printf '%s\n' "$found" | grep -c . || true)
  case $n in
  1)
    ROOTS="$found"
    config_set roots "$ROOTS"
    ;;
  0)
    die "não sei onde ficam seus repositórios.
       Rode 'workspace setup' para escolher, ou exporte WORKSPACE_ROOTS.
       Procurei por ~/dev, ~/code, ~/projects, ~/src, ~/work, ~/repos e ~/git."
    ;;
  *)
    die "achei mais de uma pasta de código e não vou adivinhar:
$(printf '%s\n' "$found" | sed "s|$HOME|~|;s|^|         |")
       Rode 'workspace setup' para escolher, ou exporte WORKSPACE_ROOTS."
    ;;
  esac
}

# mtime em epoch e data (YYYY-MM-DD) portáveis: stat -c/-f e date -d/-r
# divergem entre GNU (Linux) e BSD (macOS).
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
date_of() {
  local t
  t=$(mtime_of "$1")
  date -d "@$t" +%F 2>/dev/null || date -r "$t" +%F 2>/dev/null || echo '?'
}

# ---------------------------------------------------------------- help

cmd_help() {
  cat <<'AJUDA'

  workspace — ambientes de código isolados para trabalhar em várias demandas
  ao mesmo tempo nos mesmos repositórios.

  Cria um git worktree por repositório dentro de uma pasta única, copia os
  arquivos de env ignorados pelo git, instala as dependências e abre o editor
  com todos os repos juntos. Os arquivos de cada workspace são independentes:
  mexer num não encosta nos outros nem no seu checkout principal.

  USO

    workspace [nome] [repo ...]           cria um workspace
                                          ex: workspace bug-142 api web
                                          --no-ports mantém as portas originais
    workspace list                        mostra os workspaces ativos
    workspace repos                       lista os repositórios disponíveis
    workspace open <nome> [<nome>...]     vai para a demanda (janela dedicada)
    workspace use <nome>                  fixa a aba de chat nesta demanda
                                          sem nome, lista para escolher
                                          'none' solta a aba
    workspace status [<nome>]             o que está de pé; sem nome, todos
    workspace start <nome>                sobe os apps do workspace
                                          --only repo,repo sobe só esses
                                          --force assume container de outro
    workspace stop <nome> [<nome>...]     para o que o start subiu
    workspace down <nome> [<nome>...]     para, remove e fecha a janela do editor
                                          --force descarta pendência
                                          --keep-editor deixa a janela aberta
    workspace editor [comando]            escolhe o editor que abre
    workspace prune                       limpa registro órfão de worktree
    workspace setup                       diz onde ficam seus repositórios
    workspace doctor                      checa a máquina e aponta o que falta
    workspace update                      baixa a versão mais nova por cima
    workspace help                        esta tela

AJUDA
}

# ---------------------------------------------------------------- descoberta
#
# Todos os repositórios git sob as raízes de busca, como "nome<TAB>caminho".
# Exclui os worktrees dos próprios workspaces (senão eles apareceriam como
# repositórios disponíveis) e o que casar com WORKSPACE_IGNORE.
discover_repos() {
  local root p
  ensure_roots
  local IFS=':'
  # shellcheck disable=SC2086
  set -- $ROOTS
  unset IFS
  for root in "$@"; do
    [ -d "$root" ] || continue
    # -printf é GNU; -print + dirname funciona em BSD/macOS também.
    find "$root" -maxdepth "$MAXDEPTH" -name node_modules -prune -o -name .git -print 2>/dev/null |
      sed 's|/\.git$||'
  done | sort -u | while read -r p; do
    case $p in
    "$WS_ROOT" | "$WS_ROOT"/*) continue ;;
    esac
    # shellcheck disable=SC2254
    case $p in
    $IGNORE) continue ;;
    esac
    printf '%s\t%s\n' "${p##*/}" "$p"
  done
}

# Resolve um argumento em caminho de repositório. Aceita o nome exato da pasta
# ou um sufixo de caminho ("cobranca/api") para desempatar nome
# repetido. Imprime os caminhos que casaram, um por linha.
resolve_repo() {
  local arg=$1 map=$2
  case $arg in
  */*) printf '%s\n' "$map" | awk -F'\t' -v a="/$arg" 'length($2)>=length(a) && substr($2, length($2)-length(a)+1)==a {print $2}' ;;
  *) printf '%s\n' "$map" | awk -F'\t' -v n="$arg" '$1==n {print $2}' ;;
  esac
}

# ---------------------------------------------------------------- ranking
#
# Os N repositórios em que a pessoa mais trabalhou: commits dela nos últimos 30
# dias, desempate pelo commit mais recente e, para quem não tem commit nenhum,
# pela última atividade local do git (quem acabou de clonar).
#
# Não guarda histórico: o git de cada repo já é o registro, e conta commit de
# verdade em vez de uso da skill. Imprime, por linha:
#   identificador<TAB>pasta<TAB>commits_30d
# O identificador já vem pronto para passar ao create — com o caminho quando o
# nome existir em mais de uma pasta.
cmd_top() {
  local n=${1:-4} map email dups
  case $n in
  '' | *[!0-9]*) die "top espera um número, recebeu '$n'" ;;
  esac
  # Aqui e nos outros pontos de entrada: `die` dentro de $(discover_repos)
  # mataria só o subshell, e o comando seguiria com a lista vazia.
  ensure_roots
  map=$(discover_repos)
  [ -n "$map" ] || return 0
  email=$(git config user.email 2>/dev/null) || email=''
  dups=$(printf '%s\n' "$map" | cut -f1 | sort | uniq -d)

  printf '%s\n' "$map" | while IFS=$'\t' read -r name path; do
    local c30=0 last=0 idx=0
    if [ -n "$email" ]; then
      c30=$(git -C "$path" log --all --author="$email" --since=30.days --oneline 2>/dev/null | wc -l | tr -d ' ')
      last=$(git -C "$path" log --all --author="$email" -1 --format=%ct 2>/dev/null) || last=0
    fi
    idx=$(mtime_of "$path/.git/index")
    printf '%s\t%s\t%s\t%s\t%s\n' "${c30:-0}" "${last:-0}" "${idx:-0}" "$name" "$path"
  done | sort -rn -k1,1 -k2,2 -k3,3 | head -n "$n" | while IFS=$'\t' read -r c30 _ _ name path; do
    local folder id
    folder=${path%/*}
    if printf '%s\n' "$dups" | grep -qxF "$name"; then
      id="${folder##*/}/$name" # nome repetido: identificador com a pasta
    else
      id=$name
    fi
    printf '%s\t%s\t%s\n' "$id" "$(printf '%s' "$folder" | sed "s|$HOME|~|")" "$c30"
  done
}

# ---------------------------------------------------------------- list

# Catálogo de repositórios agrupado pela pasta que os contém.
print_catalog() {
  local map=$1 total dups first ex
  total=$(printf '%s\n' "$map" | grep -c . || true)
  printf '  Repositórios disponíveis (%s) em %s\n\n' "$total" "$(printf '%s' "$ROOTS" | sed "s|$HOME|~|g")"
  printf '%s\n' "$map" | sed "s|$HOME|~|" | awk -F'\t' '
    NF==2 {
      path=$2; sub(/\/[^\/]*$/, "", path)
      if (!(path in seen)) { order[++n]=path; seen[path]=1 }
      repos[path]=repos[path] (repos[path]=="" ? "" : "\t") $1
    }
    END {
      for (i=1;i<=n;i++) {
        p=order[i]
        printf "    %s\n", p
        m=split(repos[p], a, "\t")
        line=""
        for (j=1;j<=m;j++) {
          if (line != "" && length(line) + length(a[j]) + 2 > 70) { printf "      %s\n", line; line="" }
          line = line (line=="" ? "" : "  ") a[j]
        }
        if (line != "") printf "      %s\n", line
      }
    }
  '
  dups=$(printf '%s\n' "$map" | cut -f1 | sort | uniq -d)
  if [ -n "$dups" ]; then
    printf '\n    Nome repetido em mais de uma pasta: %s\n' "$(printf '%s' "$dups" | tr '\n' ' ')"
    first=$(printf '%s\n' "$dups" | head -1)
    ex=$(printf '%s\n' "$map" | awk -F'\t' -v n="$first" '$1==n {
      p=$2; sub(/\/[^\/]*$/, "", p); sub(/.*\//, "", p); print p "/" n
    }' | tr '\n' ' ')
    printf '    Para esses, passe o caminho em vez do nome: %s\n' "$ex"
  fi
}

cmd_repos() {
  ensure_roots
  printf '\n'
  print_catalog "$(discover_repos)"
  printf '\n'
}

# Saída do /workspace sem argumento: o que existe agora + o que dá para fazer.
cmd_overview() {
  printf '\n  Workspaces ativos\n\n'
  cmd_list
  printf '\n  Comandos\n\n'
  printf '    workspace [nome] [repo ...]   cria um workspace\n'
  printf '    workspace list                esta tela\n'
  printf '    workspace repos               lista os repositórios disponíveis\n'
  printf '    workspace open <nome>         vai para a demanda (janela dedicada)\n'
  printf '    workspace use <nome>          fixa a aba de chat nesta demanda\n'
  printf '    workspace status [nome]       o que está de pé (leitura pura)\n'
  printf '    workspace start <nome>        sobe os apps do workspace\n'
  printf '    workspace stop <nome>         para o que ele subiu\n'
  printf '    workspace down <nome>         derruba (--force descarta o não integrado)\n'
  printf '    workspace editor              escolhe qual editor abre o workspace\n'
  printf '    workspace help                manual completo\n'
  printf '\n'
}

cmd_list() {
  local found=0 d name
  if [ -d "$WS_ROOT" ]; then
    for d in "$WS_ROOT"/*/; do
      [ -f "${d}.workspace" ] || continue
      found=1
      name=$(basename "$d")
      printf '  %-16s %s\n' "$name" "$(date_of "$d")"
      while IFS=$'\t' read -r repo main branch base; do
        local cur dirty='' port=''
        if [ -f "${d}.ports" ]; then
          port=$(awk -F'\t' -v r="$repo" '$1=="port" && $2==r{printf " :%s", $4}' "${d}.ports")
        fi
        # Pasta ausente e worktree quebrado precisam se distinguir de um
        # workspace saudável — senão os dois se parecem no list.
        if [ ! -d "${d}${repo}" ]; then
          cur='✗ pasta ausente'
        elif ! git -C "${d}${repo}" rev-parse --git-dir >/dev/null 2>&1; then
          cur='✗ worktree quebrado — use down --force'
        else
          cur=$(git -C "${d}${repo}" branch --show-current 2>/dev/null) || cur=''
          [ -n "$cur" ] || cur="$base (sem branch ainda)"
          # "sujo" é o que mudou depois do provisionamento, não artefato de instalação
          [ -n "$(new_dirt "${d%/}" "$repo")" ] && dirty=' (sujo)'
        fi
        printf '    %-20s %s%s%s\n' "$repo" "$cur" "$dirty" "$port"
      done < "${d}.workspace"
    done
  fi
  [ "$found" -eq 1 ] || echo "  Nenhum workspace ativo."
}

# ---------------------------------------------------------------- arquivo do VSCode

# Escreve o .code-workspace multi-root a partir do .workspace e imprime o caminho.
# Usado na criação e no open (que regenera o arquivo se ele tiver sido apagado).
#
# O git.ignoredRepositories não é enfeite: o `.git` de um worktree aponta para o
# `.git` do clone principal, e o GitLens resolve esse commonPath e chama a API
# `openRepository()` da extensão Git nativa. Essa chamada passa force=true, o que
# fura a checagem de "repositório fora do workspace" — o clone principal entra no
# Source Control com a branch e as alterações dele, misturado com os worktrees.
# Só o ignoredRepositories barra: ele é testado antes do force. Caminho absoluto,
# porque a comparação é igualdade exata de path.
# Todo checkout git do repo cujo clone principal é $1, MENOS o caminho $2.
#
# `git worktree list` traz o clone principal e todos os worktrees, então isto
# cobre de uma vez o clone principal e os worktrees dos OUTROS workspaces —
# que é o que a extensão do git abriria no Source Control. Excluir o próprio
# é obrigatório: ignorar o worktree deste workspace apagaria o Source Control
# que a gente quer ver.
#
# --porcelain com `sed` em vez de `awk '{print $2}'`: caminho com espaço.
foreign_checkouts() {
  local main=$1 mine=$2 p
  git -C "$main" worktree list --porcelain 2>/dev/null |
    sed -n 's/^worktree //p' |
    while IFS= read -r p; do
      [ -n "$p" ] && [ "$p" != "$mine" ] && printf '%s\n' "$p"
    done
  # Se o git falhar (repo estranho, permissão), ao menos o clone principal sai.
  return 0
}

# Escapa para string JSON: barra invertida e aspas.
json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# Cor da janela, "fundo|texto", derivada do nome do workspace.
#
# Com quatro demandas abertas, achar a janela pelo título é ler quatro títulos.
# Pela cor é bater o olho. Vale o punhado de linhas.
#
# Função PURA do nome, e isso não é detalhe: o refresh_all_wsfiles reescreve o
# arquivo de TODOS os workspaces a cada create, então cor sorteada faria a
# demanda mudar de cor sozinha quando a vizinha nascesse — exatamente o oposto
# do que ela serve. Mesmo nome, mesma cor, para sempre.
#
# Fundo escuro com texto claro: as barras herdam o tema do editor, que pode ser
# claro ou escuro, e este par tem contraste suficiente nos dois.
WS_PALETTE=(
  '#1f4d3a|#d9f2e6' # verde
  '#42306b|#e6dcf7' # roxo
  '#6b4416|#f7e6cc' # âmbar
  '#6b1f2a|#f7d9de' # vermelho
  '#14415e|#d4ebf7' # azul
  '#4a4714|#f2f0cc' # oliva
  '#5c2d52|#f5dcf0' # magenta
  '#1d4d4d|#d4f0f0' # teal
)
ws_color() {
  local h
  h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '%s\n' "${WS_PALETTE[$((h % ${#WS_PALETTE[@]}))]}"
}


write_wsfile() {
  local ws=$1 name=$2 wsfile="$1/$2.code-workspace" repo main i=0 p c bg fg
  local -a ignore=()
  # Coleta antes de imprimir: a lista de um repo depende de `git worktree list`,
  # e montar dentro do heredoc misturaria I/O com a geração do JSON.
  while IFS=$'\t' read -r repo main _ _; do
    [ -n "$repo" ] || continue
    local achou=0
    while IFS= read -r p; do
      [ -n "$p" ] && { ignore+=("$p"); achou=1; }
    done < <(foreign_checkouts "$main" "$ws/$repo")
    # Fallback: sem saída do git, mantém o comportamento antigo (clone principal).
    [ "$achou" -eq 1 ] || ignore+=("$main")
  done < "$ws/.workspace"

  {
    printf '{\n  "folders": [\n'
    while IFS=$'\t' read -r repo _ _ _; do
      [ -n "$repo" ] || continue
      [ $i -gt 0 ] && printf ',\n'
      printf '    { "name": "%s", "path": "%s" }' "$(json_str "$repo")" "$(json_str "$repo")"
      i=$((i + 1))
    done < "$ws/.workspace"
    printf '\n  ],\n  "settings": {\n    "git.ignoredRepositories": [\n'
    i=0
    for p in ${ignore[@]+"${ignore[@]}"}; do
      [ $i -gt 0 ] && printf ',\n'
      printf '      "%s"' "$(json_str "$p")"
      i=$((i + 1))
    done
    printf '\n    ]'
    if [ "${WORKSPACE_COLOR:-1}" != 0 ]; then
      c=$(ws_color "$name")
      bg=${c%%|*}
      fg=${c##*|}
      printf ',\n    "workbench.colorCustomizations": {\n'
      printf '      "titleBar.activeBackground": "%s",\n' "$bg"
      printf '      "titleBar.inactiveBackground": "%s",\n' "$bg"
      printf '      "titleBar.activeForeground": "%s",\n' "$fg"
      printf '      "titleBar.inactiveForeground": "%s",\n' "$fg"
      printf '      "activityBar.background": "%s",\n' "$bg"
      printf '      "activityBar.foreground": "%s",\n' "$fg"
      printf '      "statusBar.background": "%s",\n' "$bg"
      printf '      "statusBar.foreground": "%s"\n' "$fg"
      printf '    }'
    fi
    printf '\n  }\n}\n'
  } > "$wsfile"
  printf '%s\n' "$wsfile"
}

# Regera o .code-workspace de todos os workspaces.
#
# Necessário porque a lista de ignorados de um workspace depende dos OUTROS: um
# workspace criado depois acrescenta um worktree que os arquivos já escritos não
# conhecem. É derivado e barato de reescrever, então o `create` e o `open`
# regeram tudo em vez de tentar remendar incrementalmente.
refresh_all_wsfiles() {
  local d n
  for d in "$WS_ROOT"/*/; do
    [ -f "$d/.workspace" ] || continue
    n=$(basename "$d")
    write_wsfile "${d%/}" "$n" >/dev/null 2>&1 || true
  done
  return 0
}

# ---------------------------------------------------------------- dependências
#
# O gerenciador sai do lockfile e a VERSÃO sai do campo packageManager, via
# corepack. Sem isso, um yarn 1 da máquina roda num projeto yarn 4 e escreve
# artefatos estranhos na árvore.

# Gerenciador do repo, pela prioridade dos lockfiles.
pkg_mgr() {
  local dir=$1
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    printf 'pnpm\n'
  elif [ -f "$dir/yarn.lock" ]; then
    printf 'yarn\n'
  else
    printf 'npm\n'
  fi
}

# Campo packageManager sem o hash: "yarn@4.2.2+sha512..." → "yarn@4.2.2".
pkg_declared() {
  [ -f "$1/package.json" ] || return 0
  sed -nE 's/.*"packageManager"[[:space:]]*:[[:space:]]*"([^"+]+).*/\1/p' "$1/package.json" | head -1
}

# Como rodar um script do package.json: "prefixo<TAB>separador".
#
# O separador existe porque só o npm precisa de `--` antes dos argumentos do
# script. E o prefixo passa por corepack quando o repo declara a versão, pelo
# mesmo motivo da instalação: projeto yarn 4 com PnP não tem node_modules/.bin,
# e ali `npm run` não acha binário nenhum.
pkg_runner() {
  local dir=$1 mgr decl pre
  mgr=$(pkg_mgr "$dir")
  decl=$(pkg_declared "$dir")
  pre=$mgr
  [ -n "$decl" ] && command -v corepack >/dev/null 2>&1 && pre="corepack $mgr"
  case $mgr in
  npm) printf '%s run\t--\n' "$pre" ;;
  *) printf '%s run\t\n' "$pre" ;;
  esac
}

install_deps() {
  local dir=$1 repo=$2 mgr decl flag ver
  [ -f "$dir/package.json" ] || return 0

  mgr=$(pkg_mgr "$dir")
  if [ "$mgr" = pnpm ]; then flag=--frozen-lockfile; fi
  decl=$(pkg_declared "$dir")

  if [ "$mgr" = yarn ]; then
    case $decl in
    yarn@1.*) flag=--frozen-lockfile ;;
    yarn@*) flag=--immutable ;; # Berry: --frozen-lockfile foi removido
    *)
      ver=$(yarn --version 2>/dev/null | cut -d. -f1)
      if [ "${ver:-1}" -ge 2 ] 2>/dev/null; then flag=--immutable; else flag=--frozen-lockfile; fi
      ;;
    esac
  fi

  local -a cmd
  if [ -n "$decl" ] && command -v corepack >/dev/null 2>&1; then
    cmd=(corepack "$mgr") # corepack lê o packageManager e roda a versão exata
  else
    cmd=("$mgr")
  fi
  if [ "$mgr" = npm ] && [ -f "$dir/package-lock.json" ]; then
    cmd+=(ci)
  else
    cmd+=(install)
    [ -n "${flag:-}" ] && cmd+=("$flag")
  fi

  if ! command -v "${cmd[0]}" >/dev/null 2>&1; then
    warn "$repo precisa de ${cmd[0]}, que não está instalado — instale as dependências na mão"
    return 0
  fi
  if (cd "$dir" && "${cmd[@]}" >/dev/null 2>&1); then
    printf '    %-20s %s ✓\n' '' "${cmd[*]}"
  else
    warn "$repo: ${cmd[*]} falhou — rode na mão em $dir"
  fi
}

# Estado do git logo depois do provisionamento. O que a instalação escreveu na
# árvore (PnP do yarn, vendor, venv) é artefato da ferramenta, não trabalho da
# pessoa — o down compara com isto em vez de comparar com vazio.
write_baseline() {
  local ws=$1 repo
  : > "$ws/.baseline"
  while IFS=$'\t' read -r repo _ _ _; do
    git -C "$ws/$repo" status --porcelain 2>/dev/null |
      awk -v r="$repo" '{print r "\t" $0}' >> "$ws/.baseline"
  done < "$ws/.workspace"
}

# Sujeira que apareceu DEPOIS do provisionamento, para um repo.
new_dirt() {
  local ws=$1 repo=$2 now was
  now=$(git -C "$ws/$repo" status --porcelain 2>/dev/null) || now=''
  if [ ! -f "$ws/.baseline" ]; then
    printf '%s' "$now" # workspace anterior ao baseline: comportamento antigo
    return 0
  fi
  was=$(awk -F'\t' -v r="$repo" '$1==r { sub(/^[^\t]*\t/, ""); print }' "$ws/.baseline")
  comm -13 <(printf '%s\n' "$was" | sort -u) <(printf '%s\n' "$now" | sort -u) | grep -v '^[[:space:]]*$' || true
}

# ---------------------------------------------------------------- portas
#
# Cada workspace recebe um offset (10, 20, 30…) somado às portas dos apps, para
# que dois workspaces subam ao mesmo tempo. Duas famílias de porta:
#
#   1. Vem do .env (PORT=)         → o script reescreve e o app obedece.
#   2. Vem da ferramenta de dev    → vite e serverless offline ignoram o env;
#      (vite, serverless offline)     o script reserva o número e imprime a flag.
#
# O cross-wiring cai por gravidade: montado o conjunto de portas remapeadas,
# qualquer `localhost:<porta>` nos .env do workspace é reescrito. Assim
# CORS_ORIGINS e VITE_API_URL se ajustam sem eu catalogar repo por repo, e a
# infra compartilhada (MySQL 3307, moto 4567) fica intacta porque nunca entrou
# no conjunto.
PORT_STEP="${WORKSPACE_PORT_STEP:-10}"

# sed -i não é portável (GNU quer -i, BSD quer -i ''): temp + mv.
rewrite_in_place() {
  local f=$1
  shift
  sed "$@" "$f" > "$f.wstmp" && mv "$f.wstmp" "$f"
}

# Menor offset livre, olhando o que os outros workspaces já reservaram.
next_offset() {
  local used n=$PORT_STEP
  used=$(cat "$WS_ROOT"/*/.ports 2>/dev/null | awk -F'\t' '$1=="offset"{print $2}') || used=''
  while printf '%s\n' "$used" | grep -qx "$n"; do n=$((n + PORT_STEP)); done
  printf '%s\n' "$n"
}

# Porta que a ferramenta de dev fixa e a flag para mudá-la: "porta<TAB>flag".
# Vazio quando o repo não é de uma ferramenta conhecida — melhor não reservar
# número nenhum do que anunciar porta que ninguém respeita.
tool_port() {
  local dir=$1 scripts
  [ -f "$dir/package.json" ] || return 0
  scripts=$(tr -d '\n' < "$dir/package.json" | sed -nE 's/.*"scripts"[^{]*\{([^}]*)\}.*/\1/p')
  case $scripts in
  *"serverless offline"*) printf '3000\t--httpPort\n' ;;
  *vite*) printf '5173\t--port\n' ;;
  esac
}

# Aplica o offset nos .env do workspace e grava o mapa em .ports.
remap_ports() {
  local ws=$1 offset=$2
  local repo main branch base envf old new tp flag f pair
  local -a map=()

  : > "$ws/.ports"
  printf 'offset\t%s\n' "$offset" >> "$ws/.ports"

  # ---- Fase 1: descobrir e reservar as portas deste workspace
  while IFS=$'\t' read -r repo main branch base; do
    envf="$ws/$repo/.env"
    if [ -f "$envf" ]; then
      # Só a variável chamada exatamente PORT. Um .env costuma ter outras
      # que terminam em _PORT (MYSQL_DB_PORT=3306) e remapear isso quebraria.
      old=$(sed -nE 's/^PORT=[[:space:]]*"?([0-9]+)"?.*/\1/p' "$envf" | head -1)
      if [ -n "$old" ]; then
        new=$((old + offset))
        rewrite_in_place "$envf" -E "s|^PORT=.*|PORT=$new|"
        map+=("$old $new")
        printf 'port\t%s\t%s\t%s\tenv\n' "$repo" "$old" "$new" >> "$ws/.ports"
      fi
    fi
    tp=$(tool_port "$ws/$repo")
    if [ -n "$tp" ]; then
      old=${tp%%"$(printf '\t')"*}
      flag=${tp##*"$(printf '\t')"}
      new=$((old + offset))
      map+=("$old $new")
      printf 'port\t%s\t%s\t%s\t%s\n' "$repo" "$old" "$new" "$flag" >> "$ws/.ports"
    fi
  done < "$ws/.workspace"

  [ ${#map[@]} -gt 0 ] || return 0

  # ---- Fase 2: reescrever as URLs que apontam para as portas remapeadas
  while IFS=$'\t' read -r repo main branch base; do
    for f in "${ENV_FILES[@]}"; do
      [ -f "$ws/$repo/$f" ] || continue
      for pair in "${map[@]}"; do
        old=${pair% *}
        new=${pair#* }
        # Duas expressões em vez de \b, que o sed do BSD não garante.
        rewrite_in_place "$ws/$repo/$f" -E \
          -e "s|(localhost\|127\.0\.0\.1):$old\$|\1:$new|g" \
          -e "s|(localhost\|127\.0\.0\.1):$old([^0-9])|\1:$new\2|g"
      done
    done
  done < "$ws/.workspace"

  # ---- Fase 3: SPA sem env versionado precisa saber onde está a API
  local apis count
  count=$(awk -F'\t' '$1=="port" && $5=="env"' "$ws/.ports" | wc -l | tr -d ' ')
  apis=$(awk -F'\t' '$1=="port" && $5=="env"{print $4}' "$ws/.ports" | head -1)
  while IFS=$'\t' read -r repo main branch base; do
    tp=$(tool_port "$ws/$repo")
    case $tp in *--port*) ;; *) continue ;; esac # só vite usa VITE_API_URL
    [ -f "$ws/$repo/.env" ] || [ -f "$ws/$repo/.env.local" ] && continue
    if [ "$count" -eq 1 ]; then
      printf 'VITE_API_URL=http://localhost:%s\n' "$apis" > "$ws/$repo/.env.local"
      printf '    %-20s .env.local criado, VITE_API_URL na :%s\n' "$repo" "$apis"
    else
      warn "$repo: não criei o .env.local — $count APIs no workspace, não sei qual é a certa"
    fi
  done < "$ws/.workspace"
}

# Relatório das portas e como subir cada app.
#
# O comando sai do mesmo run_spec que o `start` usa, e não de um texto fixo: o
# repo pode não ter script `dev`, e em yarn 4 com PnP o `npm run` não acha
# binário — anunciar "npm run dev" para todos era mentira em metade deles.
report_ports() {
  local ws=$1 repo old new src cmd spec
  [ -f "$ws/.ports" ] || return 0
  # Sem porta detectada, não imprime cabeçalho vazio.
  awk -F'\t' '$1=="port"' "$ws/.ports" | grep -q . || return 0
  printf '\n    Portas (offset +%s)\n' "$(awk -F'\t' '$1=="offset"{print $2}' "$ws/.ports")"
  while IFS=$'\t' read -r _ repo old new src; do
    spec=$(run_spec "$ws" "$repo")
    cmd=$(printf '%s' "$spec" | cut -f3)
    [ "$(printf '%s' "$spec" | cut -f1)" = blocked ] && cmd="o start recusa: $cmd"
    if [ "$src" = env ]; then
      printf '      %-20s %s → %s   já no .env\n' "$repo" "$old" "$new"
    else
      printf '      %-20s %s → %s   %s\n' "$repo" "$old" "$new" \
        "${cmd:-suba com a flag $src $new}"
    fi
  done < <(awk -F'\t' '$1=="port"' "$ws/.ports")
  printf '      %-20s suba tudo com: workspace start %s\n' '' "${ws##*/}"
}

# ---------------------------------------------------------------- ciclo de vida
#
# status, start e stop: subir e derrubar o que o create provisionou.
#
# Por que entrou: o create dizia uma vez "este repo atende na :3010, com esta
# flag" e a informação sumia na rolagem. Pior, processo esquecido de um
# workspace segurava porta sem ninguém lembrar de onde ele tinha saído.
#
# Sem registro novo: o `.ports` já diz a porta de cada repo e COMO ela é passada
# (`env` ou a flag da ferramenta), e o `.workspace` diz quais repos existem e
# onde está o clone principal de cada um. O único estado que este bloco
# acrescenta é `.logs/<repo>.{log,pid,cmdline}`, derivado e descartável.

RUN_DIR=.logs

tilde() { printf '%s' "$1" | sed "s|$HOME|~|"; }
trim_end() { printf '%s' "$1" | sed 's/[[:space:]]*$//'; }

# Quanto esperar a porta abrir, por tipo de app. Teto único não serve: um
# serverless que faz bundle de todas as funções antes de servir passa de um
# minuto, e o teto do vite reportaria falha falsa só nele.
wait_secs_for() {
  case $1 in
  serverless) printf '%s\n' "${WORKSPACE_WAIT_SERVERLESS:-180}" ;;
  container) printf '%s\n' "${WORKSPACE_WAIT_CONTAINER:-20}" ;;
  *) printf '%s\n' "${WORKSPACE_WAIT:-60}" ;;
  esac
}

# ---- porta
#
# Como testar porta, decidido uma vez: /dev/tcp do próprio bash, nc, ou nada.
# A mensagem de erro é lida com LC_ALL=C porque em pt_BR ela vem traduzida e a
# comparação passaria a depender do idioma da máquina.
PORT_PROBE=''
port_probe_kind() {
  local err
  if [ -z "$PORT_PROBE" ]; then
    err=$(LC_ALL=C bash -c 'exec 3<>/dev/tcp/127.0.0.1/1' 2>&1) || true
    case $err in
    *"not supported"* | *"No such file"*)
      if command -v nc >/dev/null 2>&1; then PORT_PROBE=nc; else PORT_PROBE=none; fi
      ;;
    *) PORT_PROBE=devtcp ;;
    esac
  fi
  printf '%s\n' "$PORT_PROBE"
}

# 0 = aceita conexão, 1 = recusa, 2 = sem como testar.
port_open() {
  local p=$1 h
  case $(port_probe_kind) in
  devtcp)
    for h in 127.0.0.1 localhost; do
      (exec 3<>"/dev/tcp/$h/$p") 2>/dev/null && return 0
    done
    return 1
    ;;
  nc) nc -z 127.0.0.1 "$p" >/dev/null 2>&1 ;;
  *) return 2 ;;
  esac
}

# 0 só quando a porta foi testada e RECUSOU. "Sem como testar" não conta como
# fechada — senão, em máquina sem /dev/tcp e sem nc, o status acusaria app de pé
# como se estivesse mudo.
port_closed() {
  local rc=0
  port_open "$1" || rc=$?
  [ "$rc" = 1 ]
}

# Espera a porta aceitar conexão, desistindo se o processo morrer no caminho.
#   0 = abriu   1 = timeout   2 = o processo morreu   3 = sem como testar porta
#
# É esta espera que separa útil de enfeite: app que morre por env faltando
# "inicia" e desaparece, e sem ela o start reportaria sucesso mentindo.
WAIT_ELAPSED=0
wait_port() {
  local port=$1 secs=$2 pid=${3:-} n=0 lim
  WAIT_ELAPSED=0
  [ "$(port_probe_kind)" = none ] && return 3
  lim=$((secs * 2)) # meia volta por segundo
  while [ "$n" -lt "$lim" ]; do
    port_open "$port" && return 0
    if [ -n "$pid" ] && ! proc_alive "$pid"; then return 2; fi
    sleep 0.5
    n=$((n + 1))
    WAIT_ELAPSED=$((n / 2))
    [ $((n % 8)) -eq 0 ] && printf '.'
  done
  return 1
}

# ---- processo
#
# O que este workspace subiu fica destacado (sessão própria via setsid), com log
# em .logs/<repo>.log e o PID em .logs/<repo>.pid.

proc_alive() { kill -0 "$1" 2>/dev/null; }

# cmdline do processo com os NUL virados em espaço: /proc no Linux, ps no resto.
proc_cmdline() {
  if [ -r "/proc/$1/cmdline" ]; then
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null || true
    printf '\n'
  else
    ps -o args= -p "$1" 2>/dev/null || true
  fi
}

# O processo do .pid é MESMO o que este workspace subiu?
#
# Depois de um reboot o .pid aponta para processo inexistente — ou pior, para um
# número reciclado por outro programa, e aí parar "pelo PID" mataria o programa
# errado. Duas provas independentes: o marcador WORKSPACE_RUN no ambiente, que
# só o start põe e que o exec preserva, e a cmdline gravada no start, para
# quando /proc/<pid>/environ não é legível (PID reciclado por outro usuário, ou
# sistema sem /proc).
pid_is_ours() {
  local pid=$1 mark=$2 saved=$3 blob
  [ -n "$pid" ] || return 1
  proc_alive "$pid" || return 1
  if [ -r "/proc/$pid/environ" ]; then
    blob=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null) || blob=''
    grep -qxF "WORKSPACE_RUN=$mark" <<< "$blob"
    return
  fi
  [ -f "$saved" ] || return 1
  [ "$(proc_cmdline "$pid")" = "$(cat "$saved")" ]
}

# "estado<TAB>pid" do processo de um repo:
#   ours   este workspace subiu e está vivo
#   dead   existe .pid mas o processo já morreu
#   alien  o processo existe e NÃO é nosso — o número foi reciclado
#   none   não existe .pid
#
# `dead` e `alien` são casos diferentes de propósito: o primeiro é rotina
# (fechou o terminal, caiu), o segundo é a armadilha — matar pelo número
# mataria o programa errado.
proc_status() {
  local ws=$1 name=$2 repo=$3 pid=''
  local pidf="$ws/$RUN_DIR/$repo.pid"
  [ -f "$pidf" ] || { printf 'none\t\n'; return 0; }
  pid=$(tr -dc '0-9' < "$pidf") || pid=''
  if pid_is_ours "${pid:-}" "$name/$repo" "$ws/$RUN_DIR/$repo.cmdline"; then
    printf 'ours\t%s\n' "$pid"
  elif [ -n "$pid" ] && proc_alive "$pid"; then
    printf 'alien\t%s\n' "$pid"
  else
    printf 'dead\t%s\n' "$pid"
  fi
}

# Últimas linhas do log, sem as cores que vite e serverless emitem.
log_tail() {
  local f=$1 n=${2:-6} esc
  [ -s "$f" ] || return 0
  esc=$(printf '\033')
  tail -n "$n" "$f" | sed "s|${esc}\\[[0-9;]*[a-zA-Z]||g" | cut -c1-140 |
    sed 's/^/                         /'
  printf '\n' # separa o rabo do log da próxima linha de relatório
}

# ---- o que rodar em cada repo

# Blob dos scripts do package.json, em uma linha.
scripts_blob() {
  [ -f "$1/package.json" ] || return 0
  tr -d '\n' < "$1/package.json" | sed -nE 's/.*"scripts"[^{]*\{([^}]*)\}.*/\1/p'
}

has_script() {
  local blob
  blob=$(scripts_blob "$1")
  case $blob in *"\"$2\":"*) return 0 ;; esac
  return 1
}

# Config do serverless que serve para rodar offline: a primeira que declara o
# plugin. Repo com duas configs é comum e a diferença importa — a serverless.yml
# costuma ser a de deploy e NÃO registra o serverless-offline; quem roda local é
# a serverless-local.yml, que ainda traz stage local e o serverless-localstack.
sls_config() {
  local dir=$1 f
  for f in serverless-local.yml serverless.local.yml serverless-offline.yml serverless.yml; do
    [ -f "$dir/$f" ] || continue
    grep -qE '^[[:space:]]*-[[:space:]]*serverless-offline[[:space:]]*$' "$dir/$f" &&
      { printf '%s\n' "$f"; return 0; }
  done
  return 0
}

# Stage que a config declara, já resolvendo o default do opt:
#   stage: local              → local
#   stage: ${opt:stage, prd}  → prd
#   stage: ${opt:stage}       → vazio (indefinido)
# Vazio também quando não há linha `stage:` — e vazio conta como NÃO local.
sls_stage() {
  local dir=$1 cfg=$2 raw v
  { [ -n "$cfg" ] && [ -f "$dir/$cfg" ]; } || return 0
  raw=$(grep -m1 -E '^[[:space:]]*stage:' "$dir/$cfg" | sed 's/^[^:]*:[[:space:]]*//' | tr -d "\"' ")
  case ${raw:-} in
  '') return 0 ;;
  *'${'*)
    case $raw in
    *,*)
      v=${raw#*,}
      printf '%s\n' "${v%\}*}"
      ;;
    esac
    ;;
  *) printf '%s\n' "$raw" ;;
  esac
}

# A config aponta a AWS para esta máquina? Plugin serverless-localstack ou
# endpoint em loopback bastam. Sem nenhum dos dois, o SDK fala com a AWS real.
sls_local_redirect() {
  local dir=$1 cfg=$2
  { [ -n "$cfg" ] && [ -f "$dir/$cfg" ]; } || return 1
  grep -qE '^[[:space:]]*-[[:space:]]*serverless-localstack[[:space:]]*$' "$dir/$cfg" && return 0
  grep -qE '127\.0\.0\.1|localhost' "$dir/$cfg" && return 0
  return 1
}

# Como subir um repo: "tipo<TAB>porta<TAB>comando".
#   tipo     serverless|vite|node|watch — escolhe o timeout da espera
#            blocked — NÃO sobe, e o terceiro campo é o motivo
#   porta    vazia quando o processo não serve porta (watcher de asset)
#   comando  linha pronta, com a porta remapeada já dentro
# Vazio quando não há o que subir: sem package.json ou sem script dev.
run_spec() {
  local ws=$1 repo=$2 dir line='' port src rp pre sep cfg stage
  dir="$ws/$repo"
  [ -f "$dir/package.json" ] || return 0

  # A flag ganha da variável de ambiente: onde as duas existem, quem manda é a
  # ferramenta — o vite ignora PORT e só obedece --port.
  if [ -f "$ws/.ports" ]; then
    line=$(awk -F'\t' -v r="$repo" '$1=="port" && $2==r && $5!="env" {print; exit}' "$ws/.ports")
    [ -n "$line" ] || line=$(awk -F'\t' -v r="$repo" '$1=="port" && $2==r {print; exit}' "$ws/.ports")
  fi
  port=$(printf '%s' "$line" | cut -f4)
  src=$(printf '%s' "$line" | cut -f5)

  rp=$(pkg_runner "$dir")
  pre=$(printf '%s' "$rp" | cut -f1)
  sep=$(printf '%s' "$rp" | cut -f2)

  case ${src:-} in
  --httpPort)
    # Serverless não precisa de script: a flag vai direto na CLI do plugin.
    #
    # Aqui está a única recusa DURA da skill, sem --force nem variável de
    # ambiente que contorne. Motivo: `serverless offline` no stage de produção
    # resolve nome de tabela, fila e bucket de produção, e com credencial AWS
    # válida na máquina "rodar local" passa a escrever em produção. Quatro dos
    # seis repos serverless daqui declaram `prd`/`production`. Não é risco
    # hipotético: é o default deles.
    #
    # Só sobe o que a própria config PROVA ser local — stage `local` e a AWS
    # apontada para esta máquina. Falta de prova bloqueia (fail closed), e a
    # mensagem diz qual das duas condições faltou.
    cfg=$(sls_config "$dir")
    if [ -z "$cfg" ]; then
      printf 'blocked\t%s\tnenhuma config declara o plugin serverless-offline\n' "$port"
      return 0
    fi
    stage=$(sls_stage "$dir" "$cfg")
    if [ "${stage:-}" != local ]; then
      printf 'blocked\t%s\t%s roda no stage "%s" — resolveria recurso de produção\n' \
        "$port" "$cfg" "${stage:-indefinido}"
      return 0
    fi
    if ! sls_local_redirect "$dir" "$cfg"; then
      printf 'blocked\t%s\t%s não aponta a AWS para esta máquina (sem serverless-localstack nem endpoint em 127.0.0.1)\n' \
        "$port" "$cfg"
      return 0
    fi
    # --stage local explícito, mesmo já sendo o da config: quem lê o comando na
    # tela vê em que stage aquilo subiu.
    printf 'serverless\t%s\tnpx serverless offline start --config %s --stage local --httpPort %s\n' \
      "$port" "$cfg" "$port"
    ;;
  --*)
    has_script "$dir" dev || return 0
    printf 'vite\t%s\t%s dev%s %s %s\n' "$port" "$pre" "${sep:+ $sep}" "$src" "$port"
    ;;
  env)
    has_script "$dir" dev || return 0
    printf 'node\t%s\t%s dev\n' "$port" "$pre"
    ;;
  *)
    # Sem porta: watcher de asset (babel --watch + sass -w, e afins).
    # Sobe e reporta rodando, sem porta para esperar.
    has_script "$dir" dev || return 0
    printf 'watch\t\t%s dev\n' "$pre"
    ;;
  esac
}

# ---- docker: opcional, e só o que o compose do repo declara
#
# O script era bash puro (só `command -v`), então docker é dependência nova e
# entra como a detecção de editor: sem o binário, a parte de container é pulada
# em silêncio. Com o binário e sem daemon, avisa uma vez — silêncio aí esconderia
# o motivo de o container do repo não ter subido.
DOCKER_STATE=''
docker_ok() {
  if [ -z "$DOCKER_STATE" ]; then
    if ! command -v docker >/dev/null 2>&1; then
      DOCKER_STATE=0
    elif docker ps -q >/dev/null 2>&1; then
      DOCKER_STATE=1
      docker_ps_cache # aquece no shell de cima: quem consulta roda em subshell
    else
      DOCKER_STATE=0
      warn "docker instalado mas o daemon não responde — nenhum container foi tocado"
    fi
  fi
  [ "$DOCKER_STATE" = 1 ]
}

# Um `docker ps` serve todas as consultas: a máquina tem mais de mil containers
# (os executores de lambda do localstack ficam para trás), e perguntar serviço
# por serviço ao compose custava um segundo por workspace.
DOCKER_PS=''
docker_ps_cache() {
  [ -n "$DOCKER_PS" ] && return 0
  DOCKER_PS=$(docker ps -a --format \
    '{{.Names}}|{{.State}}|{{.Label "com.docker.compose.project"}}|{{.Label "com.docker.compose.service"}}|{{.Label "com.docker.compose.project.working_dir"}}|{{.ID}}' \
    2>/dev/null) || DOCKER_PS=''
  return 0
}

# Depois de subir ou remover container, a foto está velha.
docker_ps_refresh() {
  DOCKER_PS=''
  docker_ps_cache
}

# Mensagem de erro do docker em uma linha legível. O corte preserva o FIM: a
# causa está lá ("Bind for 0.0.0.0:3306 failed: port is already allocated"),
# enquanto o começo é sempre o mesmo boilerplate.
docker_err() {
  local m
  m=$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -1 |
    sed -E 's/^Error response from daemon: //; s/failed to set up container networking: //; s/ *\([0-9a-f]{12,}\)//g')
  if [ ${#m} -gt 150 ]; then printf '…%s' "${m: -150}"; else printf '%s' "$m"; fi
}

# Nome de projeto do compose: minúsculo e sem caractere estranho, porque o
# compose recusa o resto — o workspace `cobranca-RCS` vira `cobranca-rcs`.
compose_proj() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_-]/-/g'; }

# Serviços do compose de um repo: "svc|build ou image|container_name|porta".
#
# Quem tem `build:` é o código do repo — este workspace pode servir o dele, a
# partir do worktree. Quem só tem `image:` (mysql, valkey, localstack) é infra
# com estado, compartilhada, e nunca sobe do worktree.
#
# Separador `|` e não TAB porque aqui há campo vazio (serviço sem
# container_name, serviço sem porta publicada) e TAB é caractere de espaço do
# IFS: com ele, `read` colapsa os vazios e a porta cai na coluna do nome.
#
# Parser mínimo em awk e indent-agnóstico de propósito: compose escrito com 4
# espaços é tão comum quanto com 2.
compose_services() {
  local f=$1
  [ -f "$f" ] || return 0
  awk '
    /^[[:space:]]*#/ { next }
    /^services:[[:space:]]*$/ { ins = 1; next }
    ins && /^[^[:space:]]/   { ins = 0 }
    !ins { next }
    { match($0, /^[[:space:]]*/); ind = RLENGTH }
    ind == 0 { next }
    { line = $0; sub(/^[[:space:]]*/, "", line) }
    (svcind == 0 || ind == svcind) && line ~ /^[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      if (svcind == 0) svcind = ind
      cur = line; sub(/:.*$/, "", cur); order[++n] = cur; inports = 0; next
    }
    cur == "" { next }
    ind > svcind {
      if (line ~ /^build:/)          { build[cur] = 1; inports = 0; next }
      if (line ~ /^image:/)          { v = line; sub(/^image:[[:space:]]*/, "", v); image[cur] = v; inports = 0; next }
      if (line ~ /^container_name:/) { v = line; sub(/^container_name:[[:space:]]*/, "", v); gsub(/["\047[:space:]]/, "", v); cname[cur] = v; inports = 0; next }
      if (line ~ /^ports:/)          { inports = 1; next }
      if (line ~ /^[A-Za-z0-9_.-]+:/) { inports = 0; next }
      if (inports && line ~ /^-/) {
        v = line; sub(/^-[[:space:]]*/, "", v); gsub(/["\047]/, "", v)
        if (hp[cur] == "" && v ~ /^[0-9]+:/) { sub(/:.*$/, "", v); hp[cur] = v }
      }
    }
    END { for (i = 1; i <= n; i++) { s = order[i]; printf "%s|%s|%s|%s\n", s, (build[s] ? "build" : "image"), cname[s], hp[s] } }
  ' "$f"
}

# "estado<TAB>projeto<TAB>working_dir<TAB>id" do container de um serviço, ou vazio.
#
# Com container_name o nome é chave GLOBAL — é justamente ele que impede dois
# workspaces de subirem o mesmo container, então a busca é pelo nome. Sem
# container_name, a chave é o par projeto+serviço, que é como o compose nomeia.
svc_container() {
  local proj=$1 svc=$2 cname=$3
  docker_ps_cache
  awk -F'|' -v c="$cname" -v p="$proj" -v s="$svc" '
    (c != "" && $1 == c) || (c == "" && $3 == p && $4 == s) {
      printf "%s\t%s\t%s\t%s\n", ($2 == "running" ? "running" : "stopped"), $3, $5, $6
      exit
    }' <<< "$DOCKER_PS"
}

# Garante a infra do repo de pé, sempre a do CHECKOUT PRINCIPAL e nunca uma
# segunda instância. Imprime um token por serviço ("ac-db ✓", "valkey ↑").
#
# Subir infra do worktree seria pior que inútil: o volume do ac-db é
# `../dumps/mysql/data` relativo ao compose, que dentro do workspace apontaria
# para uma pasta vazia — banco novo em cima de 322 MB de dump abandonados.
INFRA_NOTES=()
ensure_infra() {
  local main=$1 svc=$2 cname=$3 proj st err
  proj=$(compose_proj "${main##*/}")
  st=$(svc_container "$proj" "$svc" "$cname")
  if [ "$(printf '%s' "$st" | cut -f1)" = running ]; then
    printf '%s ✓' "$svc"
    return 0
  fi
  if err=$(docker compose --project-directory "$main" -f "$main/docker-compose.yml" \
    up -d --no-deps --no-recreate "$svc" 2>&1); then
    printf '%s ↑' "$svc"
    docker_ps_refresh
  else
    printf '%s ✗' "$svc"
    INFRA_NOTES+=("$svc não subiu: $(docker_err "$err")")
  fi
  return 0
}

# Sobe o serviço de código do repo a partir do WORKTREE, com o nome do workspace
# como projeto do compose. Uma linha de relatório; != 0 se não subiu.
start_build_svc() {
  local ws=$1 name=$2 repo=$3 main=$4 svc=$5 cname=$6 hostport=$7 force=$8
  local dir="$ws/$repo" proj st state wdir cid err img src
  proj=$(compose_proj "$name")
  st=$(svc_container "$proj" "$svc" "$cname")
  state=$(printf '%s' "$st" | cut -f1)
  wdir=$(printf '%s' "$st" | cut -f3)
  cid=$(printf '%s' "$st" | cut -f4)

  # container_name é global: se outro workspace (ou o checkout principal) está
  # SERVINDO com ele, subir por cima derrubaria o dele em silêncio — daí a recusa.
  #
  # Container parado é outra história: ele só está segurando o nome, e o compose
  # do dono recria quando precisar (o estado dele mora em volume, não no
  # container). Recusar aí travaria todo primeiro start, porque container
  # antigo parado é o caso comum.
  if [ -n "$state" ] && [ "$wdir" != "$dir" ]; then
    if [ "$state" = running ] && [ "$force" -eq 0 ]; then
      printf '      %-18s ✗ %s está de pé com %s — libere ou use --force\n' \
        '' "${cname:-$svc}" "$(tilde "${wdir:-outro projeto}")"
      return 1
    fi
    if [ "$state" = running ]; then
      printf '      %-18s %s assumido de %s (--force)\n' '' "${cname:-$svc}" "$(tilde "${wdir:-outro projeto}")"
    else
      printf '      %-18s %s parado de %s removido para liberar o nome\n' \
        '' "${cname:-$svc}" "$(tilde "${wdir:-outro projeto}")"
    fi
    docker rm -f "$cid" >/dev/null 2>&1 || true
    docker_ps_refresh
    state=''
  fi

  if [ "$state" = running ]; then
    printf '      %-18s %s já de pé%s\n' '' "$svc" "${hostport:+ → :$hostport}"
    url_add "$repo ($svc)" "$hostport"
    return 0
  fi

  # A imagem do compose é nomeada pelo projeto, então com o workspace como
  # projeto o primeiro start construiria uma imagem nova — no ac-app são 7,65 GB
  # e minutos de build, por workspace, porque o Dockerfile dá `COPY . .` no repo
  # inteiro. A tag reaproveita a imagem do checkout principal: custa zero disco
  # (é outro nome para a mesma imagem) e serve o código do worktree do mesmo
  # jeito, que vem do bind mount e não da imagem. O que vem da imagem é o
  # `vendor` (volume anônimo) — que é justamente o que se quer compartilhar.
  img="$proj-$svc"
  src="$(compose_proj "${main##*/}")-$svc"
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    if [ "$src" != "$img" ] && docker image inspect "$src" >/dev/null 2>&1 &&
      docker tag "$src" "$img" >/dev/null 2>&1; then
      printf '      %-18s %s: imagem de %s reaproveitada\n' '' "$svc" "$src"
    else
      printf '      %-18s %s: construindo a imagem (primeira vez, demora)\n' '' "$svc"
    fi
  fi
  if err=$(docker compose --project-directory "$dir" -f "$dir/docker-compose.yml" -p "$proj" \
    up -d --no-deps "$svc" 2>&1); then
    docker_ps_refresh
    if [ -n "$hostport" ] && wait_port "$hostport" "$(wait_secs_for container)"; then
      printf '      %-18s %s ↑ de pé → :%s\n' '' "$svc" "$hostport"
      url_add "$repo ($svc)" "$hostport"
    elif [ -n "$hostport" ]; then
      printf '      %-18s %s ↑ subiu, mas :%s ainda não responde\n' '' "$svc" "$hostport"
    else
      printf '      %-18s %s ↑ de pé\n' '' "$svc"
    fi
    return 0
  fi
  printf '      %-18s ✗ %s não subiu: %s\n' '' "$svc" "$(docker_err "$err")"
  return 1
}

# Sobe o processo do repo destacado: sessão própria (setsid), log e PID no
# .logs/, e a espera da porta antes de reportar sucesso.
#
# O PID vem do próprio processo (`echo $$` antes do exec), não do `$!`: o setsid
# se bifurca quando não é líder de grupo, e aí o `$!` seria o pai que morre na
# hora, deixando o processo de verdade sem número conhecido. Escrito antes do
# exec e preservado por ele, o número é o do líder da sessão — o que faz
# `kill -- -PID` alcançar a árvore inteira (npm, filho, watcher).
start_process() {
  local ws=$1 name=$2 repo=$3 kind=$4 port=$5 cmd=$6 nowait=${7:-0}
  local dir="$ws/$repo" logs="$ws/$RUN_DIR" pid='' i rc
  local pidf script mark="$name/$repo"
  mkdir -p "$logs"
  pidf="$logs/$repo.pid"
  rm -f "$pidf"
  : > "$logs/$repo.log" # log por start: senão o rabo do erro traz o de ontem

  script="export WORKSPACE_RUN='$mark'; echo \$\$ > '$pidf'; cd '$dir' || exit 1; exec $cmd"
  if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "$script" >> "$logs/$repo.log" 2>&1 < /dev/null &
  else
    # macOS não traz setsid. O processo ainda fica destacado (o script sai e ele
    # é reparentado), só não vira líder de sessão — e aí o stop mata pelo PID em
    # vez do grupo, o que alcança menos filhos.
    bash -c "$script" >> "$logs/$repo.log" 2>&1 < /dev/null &
  fi

  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -s "$pidf" ] && break
    sleep 0.1
  done
  pid=$(tr -dc '0-9' < "$pidf" 2>/dev/null) || pid=''
  if [ -z "$pid" ]; then
    printf '✗ não consegui lançar (veja %s/%s.log)\n' "$RUN_DIR" "$repo"
    return 1
  fi
  # A cmdline só passa a ser a do app depois do exec, e é ela que o stop compara
  # quando o /proc/<pid>/environ não é legível. Enquanto ainda for o texto do
  # lançador (que contém WORKSPACE_RUN=), o exec não aconteceu: espera.
  for i in 1 2 3 4 5 6; do
    sleep 0.2
    proc_cmdline "$pid" > "$logs/$repo.cmdline"
    grep -q 'WORKSPACE_RUN=' "$logs/$repo.cmdline" || break
  done

  if [ -z "$port" ] || [ "$nowait" = 1 ]; then
    # Sem porta não há o que esperar, mas morrer na largada é comum (env
    # faltando), então confirma que ainda está vivo antes de dizer que subiu.
    sleep 1
    if proc_alive "$pid"; then
      if [ "$nowait" = 1 ]; then
        printf 'subiu   pid %s (porta não confirmada)\n' "$pid"
      else
        printf 'rodando (sem porta)   pid %s\n' "$pid"
      fi
      return 0
    fi
    printf '✗ morreu na largada — fim do log:\n'
    log_tail "$logs/$repo.log"
    return 1
  fi

  wait_port "$port" "$(wait_secs_for "$kind")" "$pid" && rc=0 || rc=$?
  case $rc in
  0) printf '✓ de pé em %ss   pid %s\n' "$WAIT_ELAPSED" "$pid" ;;
  2)
    printf '✗ o processo morreu em %ss — fim do log:\n' "$WAIT_ELAPSED"
    log_tail "$logs/$repo.log"
    return 1
    ;;
  3) printf 'subiu   pid %s (sem como testar a porta nesta máquina)\n' "$pid" ;;
  *)
    printf '✗ :%s não abriu em %ss (o processo continua vivo, pid %s) — fim do log:\n' \
      "$port" "$WAIT_ELAPSED" "$pid"
    log_tail "$logs/$repo.log"
    return 1
    ;;
  esac
  return 0
}

# ---- start

# Infra que os repos escolhidos declaram, antes dos apps: backend sem mysql sobe
# e morre, e a espera de porta acusaria como falha do app.
# O `ensure_infra` roda no shell de cima, sem captura: ele mexe em estado global
# (a foto do docker, as notas de erro) e dentro de `$(...)` isso se perderia.
start_infra() {
  local ws=$1 repo main svc tipo cname _p any=0 i
  local -a repos=("${@:2}") svcs=() cnames=()
  docker_ok || return 0
  [ ${#repos[@]} -gt 0 ] || return 0
  for repo in "${repos[@]}"; do
    main=$(awk -F'\t' -v r="$repo" '$1==r{print $2; exit}' "$ws/.workspace")
    [ -n "$main" ] && [ -f "$main/docker-compose.yml" ] || continue
    svcs=()
    cnames=()
    while IFS='|' read -r svc tipo cname _p; do
      [ "$tipo" = image ] || continue
      svcs+=("$svc")
      cnames+=("$cname")
    done < <(compose_services "$main/docker-compose.yml")
    [ ${#svcs[@]} -gt 0 ] || continue
    if [ "$any" -eq 0 ]; then
      any=1
      printf '    %-20s ' 'infra compartilhada'
    else
      printf '    %-20s ' ''
    fi
    for i in "${!svcs[@]}"; do
      [ "$i" -gt 0 ] && printf '   '
      ensure_infra "$main" "${svcs[$i]}" "${cnames[$i]}"
    done
    printf '\n'
  done
  return 0
}

# O que ficou de pé servindo HTTP, para o bloco "abra:" no fim do start — o
# número da porta já apareceu linha por linha, mas o que ele quer no fim é o
# endereço pronto para clicar. Entra só o que é do workspace: app com a porta
# remapeada e container de código com porta publicada. Infra compartilhada fica
# fora, que ela não é de um workspace só.
START_URLS=()
url_add() {
  local label=$1 port=$2
  [ -n "$port" ] || return 0
  START_URLS+=("$label"$'\t'"http://localhost:$port")
}

# Sobe um repo: o processo dele e, quando o código do repo é servido por
# container, o serviço de build do compose a partir do worktree.
start_repo() {
  local ws=$1 name=$2 repo=$3 force=$4
  local dir="$ws/$repo" spec kind port cmd st pid rc=0 up=0 main
  main=$(awk -F'\t' -v r="$repo" '$1==r{print $2; exit}' "$ws/.workspace")
  spec=$(run_spec "$ws" "$repo")
  kind=$(printf '%s' "$spec" | cut -f1)
  port=$(printf '%s' "$spec" | cut -f2)
  cmd=$(printf '%s' "$spec" | cut -f3)

  if [ "$kind" = blocked ]; then
    # Recusa dura: não existe flag que faça o start subir isto.
    printf '    %-20s %-6s ✗ não subo: %s\n' "$repo" "${port:+:$port}" "$cmd"
    rc=1
  elif [ -n "$cmd" ]; then
    st=$(proc_status "$ws" "$name" "$repo")
    pid=$(printf '%s' "$st" | cut -f2)
    if [ "$(printf '%s' "$st" | cut -f1)" = ours ]; then
      printf '    %-20s %-6s já de pé   pid %s\n' "$repo" "${port:+:$port}" "$pid"
      up=1
    elif [ -n "$port" ] && port_open "$port"; then
      # Porta ocupada e não é nosso processo: subir por cima daria app que não
      # liga (ou pior, vite pulando calado para a porta seguinte).
      if [ "$force" -eq 0 ]; then
        printf '    %-20s :%s ✗ porta ocupada por processo de fora — libere ou use --force\n' \
          "$repo" "$port"
        rc=1
      else
        printf '    %-20s :%s ⚠  ocupada, subindo mesmo assim (--force)   %s\n' "$repo" "$port" "$cmd"
        printf '      %-18s ' ''
        if start_process "$ws" "$name" "$repo" "$kind" "$port" "$cmd" 1; then up=1; else rc=1; fi
      fi
    else
      printf '    %-20s %-6s %s\n' "$repo" "${port:+:$port}" "$cmd"
      printf '      %-18s ' ''
      if start_process "$ws" "$name" "$repo" "$kind" "$port" "$cmd"; then up=1; else rc=1; fi
    fi
  fi
  [ "$up" -eq 1 ] && url_add "$repo" "$port"

  if [ "$kind" != blocked ] && [ -z "$cmd" ]; then
    if [ -f "$dir/docker-compose.yml" ] && docker_ok; then
      printf '    %-20s sem processo para subir, só container\n' "$repo"
    else
      printf '    %-20s nada para subir (sem script dev)\n' "$repo"
    fi
  fi

  # Container de código: só quando o repo não tem processo com porta. Onde há
  # processo, é ele que serve o código com a porta remapeada — o compose publica
  # porta fixa e usa container_name fixo, então serviria um workspace só.
  if docker_ok && [ -f "$dir/docker-compose.yml" ]; then
    local svc tipo cname hp
    while IFS='|' read -r svc tipo cname hp; do
      [ "$tipo" = build ] || continue
      if [ -n "$port" ]; then
        printf '      %-18s compose %s ignorado: o código roda local na :%s\n' '' "$svc" "$port"
        continue
      fi
      start_build_svc "$ws" "$name" "$repo" "$main" "$svc" "$cname" "$hp" "$force" || rc=1
    done < <(compose_services "$dir/docker-compose.yml")
  fi
  return "$rc"
}

cmd_start() {
  local names=() only='' force=0 arg name ws rc=0
  while [ $# -gt 0 ]; do
    case $1 in
    --force) force=1 ;;
    --only)
      shift
      only=${1:-}
      [ -n "$only" ] || die "--only precisa da lista de repos. Ex: --only web,api"
      ;;
    --only=*) only=${1#*=} ;;
    -*) die "flag desconhecida: $1" ;;
    *) names+=("$1") ;;
    esac
    shift
  done
  if [ ${#names[@]} -eq 0 ]; then
    printf '\n  Informe qual subir. Ativos:\n'
    cmd_list
    exit 1
  fi
  [ ${#names[@]} -eq 1 ] || die "start sobe um workspace por vez — para escolher repos use --only"
  name=${names[0]}
  ws="$WS_ROOT/$name"
  [ -f "$ws/.workspace" ] || die "workspace '$name' não existe em $WS_ROOT"

  # Repos a subir: todos, ou os do --only validados antes de subir qualquer um.
  local -a repos=()
  local all missing=()
  all=$(cut -f1 "$ws/.workspace")
  if [ -n "$only" ]; then
    for arg in ${only//,/ }; do
      grep -qxF "$arg" <<< "$all" || missing+=("$arg")
      repos+=("$arg")
    done
    [ ${#missing[@]} -eq 0 ] || die "não está em $name: ${missing[*]} — tem $(printf '%s' "$all" | tr '\n' ' ')"
  else
    while IFS= read -r arg; do [ -n "$arg" ] && repos+=("$arg"); done <<< "$all"
  fi

  printf '\n  %s   start\n\n' "$name"
  INFRA_NOTES=()
  START_URLS=()
  start_infra "$ws" "${repos[@]}"
  for arg in ${INFRA_NOTES[@]+"${INFRA_NOTES[@]}"}; do
    printf '      %-18s ⚠  %s\n' '' "$arg"
  done
  for arg in "${repos[@]}"; do
    start_repo "$ws" "$name" "$arg" "$force" || rc=1
  done
  if [ ${#START_URLS[@]} -gt 0 ]; then
    printf '\n    abra:\n'
    for arg in "${START_URLS[@]}"; do
      printf '      %-22s %s\n' "${arg%%$'\t'*}" "${arg##*$'\t'}"
    done
  fi
  printf '\n    logs em %s/%s/   •   pare com: workspace stop %s\n\n' "$(tilde "$ws")" "$RUN_DIR" "$name"
  [ "$rc" -eq 0 ] || exit 1
}

# ---- stop

# Para o processo e a árvore dele. TERM primeiro (o watcher e o serverless
# fecham limpo), KILL só se sobrar.
stop_process() {
  local ws=$1 name=$2 repo=$3 st pid pgid i
  st=$(proc_status "$ws" "$name" "$repo")
  pid=$(printf '%s' "$st" | cut -f2)
  case $(printf '%s' "$st" | cut -f1) in
  none) return 1 ;;
  dead)
    rm -f "$ws/$RUN_DIR/$repo.pid" "$ws/$RUN_DIR/$repo.cmdline"
    printf '    %-20s já não estava rodando (.pid de processo morto, descartado)\n' "$repo"
    return 1
    ;;
  alien)
    rm -f "$ws/$RUN_DIR/$repo.pid" "$ws/$RUN_DIR/$repo.cmdline"
    printf '    %-20s .pid ignorado: o pid %s agora é de outro programa\n' "$repo" "${pid:-?}"
    return 1
    ;;
  esac

  # Mata o grupo, para levar npm e filhos junto. Só quando o líder do grupo é o
  # próprio PID: se não for, `kill -- -PID` acertaria o grupo de outra pessoa.
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -dc '0-9') || pgid=''
  if [ "$pgid" = "$pid" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
  else
    kill -TERM "$pid" 2>/dev/null || true
  fi
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    proc_alive "$pid" || break
    sleep 0.5
  done
  if proc_alive "$pid"; then
    if [ "$pgid" = "$pid" ]; then kill -KILL -- "-$pid" 2>/dev/null || true; else
      kill -KILL "$pid" 2>/dev/null || true
    fi
    sleep 0.5
    printf '    %-20s processo %s parado à força\n' "$repo" "$pid"
  else
    printf '    %-20s processo %s parado\n' "$repo" "$pid"
  fi
  rm -f "$ws/$RUN_DIR/$repo.pid" "$ws/$RUN_DIR/$repo.cmdline"
  return 0
}

# Remove os containers de código que ESTE workspace criou. Reconhece pelo
# working_dir do compose: só container nascido do worktree é nosso.
#
# Remove em vez de parar porque o container_name é uma chave global — container
# parado continua segurando o nome e o próximo workspace recusaria subir.
stop_build_svcs() {
  local ws=$1 name=$2 repo=$3 dir="$ws/$repo" proj svc tipo cname _p st cid n=0
  docker_ok || return 1
  [ -f "$dir/docker-compose.yml" ] || return 1
  proj=$(compose_proj "$name")
  while IFS='|' read -r svc tipo cname _p; do
    [ "$tipo" = build ] || continue
    st=$(svc_container "$proj" "$svc" "$cname")
    [ -n "$st" ] || continue
    [ "$(printf '%s' "$st" | cut -f3)" = "$dir" ] || continue
    cid=$(printf '%s' "$st" | cut -f4)
    if docker rm -f "$cid" >/dev/null 2>&1; then
      docker_ps_refresh
      printf '    %-20s container %s removido\n' "$repo" "$svc"
      n=$((n + 1))
    else
      warn "$repo: não consegui remover o container $svc"
    fi
  done < <(compose_services "$dir/docker-compose.yml")
  [ "$n" -gt 0 ]
}

# Para tudo que este workspace subiu. A infra com estado nunca é tocada: é
# compartilhada, e derrubar o mysql daqui derrubaria o dos outros workspaces.
stop_workspace() {
  local ws=$1 name=$2 repo n=0
  while IFS=$'\t' read -r repo _ _ _; do
    [ -n "$repo" ] || continue
    stop_process "$ws" "$name" "$repo" && n=$((n + 1))
    stop_build_svcs "$ws" "$name" "$repo" && n=$((n + 1))
  done < "$ws/.workspace"
  [ "$n" -gt 0 ]
}

cmd_stop() {
  local names=() arg missing=()
  for arg in "$@"; do
    case $arg in
    -*) die "flag desconhecida: $arg" ;;
    *) names+=("$arg") ;;
    esac
  done
  if [ ${#names[@]} -eq 0 ]; then
    printf '\n  Informe qual parar. Ativos:\n'
    cmd_list
    exit 1
  fi
  for arg in "${names[@]}"; do
    [ -f "$WS_ROOT/$arg/.workspace" ] || missing+=("$arg")
  done
  [ ${#missing[@]} -eq 0 ] || die "não existe(m) em $WS_ROOT: ${missing[*]}"

  for arg in "${names[@]}"; do
    printf '\n  %s   stop\n\n' "$arg"
    if ! stop_workspace "$WS_ROOT/$arg" "$arg"; then
      printf '    nada estava de pé\n'
    fi
  done
  printf '\n'
}

# ---- status
#
# Leitura pura: não sobe, não para, não cria nada. Sem nome, passa por todos os
# workspaces — é o comando de não esquecer processo rodando.

# Uma linha por repo com o estado do processo e da porta.
status_repo() {
  local ws=$1 name=$2 repo=$3 spec kind port cmd st state pid mark=''
  spec=$(run_spec "$ws" "$repo")
  kind=$(printf '%s' "$spec" | cut -f1)
  port=$(printf '%s' "$spec" | cut -f2)
  cmd=$(printf '%s' "$spec" | cut -f3)
  if [ "$kind" = blocked ]; then
    printf '    %-20s %-7s ✗ o start recusa: %s\n' "$repo" "${port:+:$port}" "$cmd"
    return 0
  fi
  st=$(proc_status "$ws" "$name" "$repo")
  state=$(printf '%s' "$st" | cut -f1)
  pid=$(printf '%s' "$st" | cut -f2)

  if [ "$state" = ours ]; then
    STATUS_PROCS=$((STATUS_PROCS + 1))
    mark="✓ rodando   pid $pid"
    if [ -n "$port" ] && port_closed "$port"; then mark="⚠  vivo mas a :$port não responde   pid $pid"; fi
  elif [ -n "$port" ] && port_open "$port"; then
    mark='⚠  porta ocupada por processo de fora'
  elif [ "$state" = alien ]; then
    mark="✗ parado (o pid $pid do .pid agora é de outro programa)"
  elif [ -n "$cmd" ]; then
    mark='✗ parado'
  else
    mark='—'
  fi
  printf '    %-20s %-7s %s\n' "$repo" "${port:+:$port}" "$mark"
}

# Endpoints dos .env do repo que NÃO são esta máquina: "VAR host" por linha.
#
# Existe porque a skill garante onde o processo roda, não o que ele alcança:
# quem decide isso é o .env que o create copiou. Então o status mostra.
#
# Só o HOST sai, nunca o valor — .env é cheio de credencial. E o filtro é
# conservador de propósito: valor com maiúscula ou `_` está fora, senão um JWT
# (que tem ponto, como domínio) seria lido como hostname e o token apareceria na
# tela. O preço é não enxergar host escrito em MAIÚSCULA; melhor isso que vazar.
nonlocal_endpoints() {
  local dir=$1 f line k v h
  for f in "${ENV_FILES[@]}"; do
    [ -f "$dir/$f" ] || continue
    while IFS= read -r line; do
      case $line in '#'* | '') continue ;; esac
      case $line in *=*) ;; *) continue ;; esac
      k=${line%%=*}
      v=${line#*=}
      v=${v//\"/}
      v=${v//\'/}
      h=''
      case $v in
      *://*)
        h=${v#*://}
        h=${h#*@} # tira usuário:senha do DSN
        h=${h%%/*}
        h=${h%%\?*}
        h=${h%%,*}
        ;;
      *[A-Z_]*) continue ;; # token, chave, base64: não é host
      *.*)
        if [ ${#v} -le 60 ]; then
          case $v in *[!a-z0-9.:-]*) ;; *) h=$v ;; esac
        fi
        ;;
      esac
      [ -n "$h" ] || continue
      case $h in
      localhost* | 127.0.0.1* | 0.0.0.0* | host.docker.internal* | '::1'*) continue ;;
      *[a-z]*) printf '%s→%s\n' "$k" "$h" ;;
      esac
    done < "$dir/$f"
  done | sort -u
}

# Uma linha com os containers do compose do repo, separando código de infra.
#
# Serviço de código de repo que tem porta remapeada não entra: quem serve o
# código ali é o processo local, e o container do compose (porta e nome fixos)
# está fora do jogo — mostrá-lo só faria parecer que o workspace depende dele.
status_docker() {
  local ws=$1 name=$2 repo=$3 main=$4
  local dir="$ws/$repo" proj port svc tipo cname hp st state wdir code='' infra=''
  docker_ok || return 0
  [ -f "$dir/docker-compose.yml" ] || return 0
  proj=$(compose_proj "$name")
  port=$(run_spec "$ws" "$repo" | cut -f2)
  while IFS='|' read -r svc tipo cname hp; do
    if [ "$tipo" = build ]; then
      [ -z "$port" ] || continue
      st=$(svc_container "$proj" "$svc" "$cname")
      state=$(printf '%s' "$st" | cut -f1)
      wdir=$(printf '%s' "$st" | cut -f3)
      if [ "$state" = running ] && [ "$wdir" = "$dir" ]; then
        code="$code$svc ✓${hp:+ :$hp}   "
        STATUS_CONTS=$((STATUS_CONTS + 1))
      elif [ "$state" = running ]; then
        code="$code$svc ⚠ com $(tilde "${wdir:-outro}")   "
      else
        code="$code$svc ✗   "
      fi
    else
      st=$(svc_container "$(compose_proj "${main##*/}")" "$svc" "$cname")
      if [ "$(printf '%s' "$st" | cut -f1)" = running ]; then
        infra="$infra$svc ✓   "
      else
        infra="$infra$svc ✗   "
      fi
    fi
  done < <(compose_services "$dir/docker-compose.yml")
  [ -n "$code" ] && printf '      %-18s código: %s\n' '' "$(trim_end "$code")"
  [ -n "$infra" ] && printf '      %-18s infra:  %s\n' '' "$(trim_end "$infra")"
  return 0
}

STATUS_PROCS=0
STATUS_CONTS=0
cmd_status() {
  local names=() arg d name ws repo main offset ext n
  for arg in "$@"; do
    case $arg in
    -*) die "flag desconhecida: $arg" ;;
    *) names+=("$arg") ;;
    esac
  done
  if [ ${#names[@]} -gt 0 ]; then
    for arg in "${names[@]}"; do
      [ -f "$WS_ROOT/$arg/.workspace" ] || die "workspace '$arg' não existe em $WS_ROOT"
    done
  else
    if [ -d "$WS_ROOT" ]; then
      for d in "$WS_ROOT"/*/; do
        [ -f "${d}.workspace" ] && names+=("$(basename "$d")")
      done
    fi
    if [ ${#names[@]} -eq 0 ]; then
      printf '\n  Nenhum workspace ativo.\n\n'
      return 0
    fi
  fi

  printf '\n'
  for name in "${names[@]}"; do
    ws="$WS_ROOT/$name"
    offset=''
    [ -f "$ws/.ports" ] && offset=$(awk -F'\t' '$1=="offset"{print $2; exit}' "$ws/.ports")
    printf '  %s%s\n' "$name" "${offset:+   offset +$offset}"
    while IFS=$'\t' read -r repo main _ _; do
      [ -n "$repo" ] || continue
      if [ ! -d "$ws/$repo" ]; then
        printf '    %-20s ✗ pasta ausente\n' "$repo"
        continue
      fi
      status_repo "$ws" "$name" "$repo"
      status_docker "$ws" "$name" "$repo" "$main"
      ext=$(nonlocal_endpoints "$ws/$repo")
      if [ -n "$ext" ]; then
        n=$(printf '%s\n' "$ext" | grep -c .)
        printf '      %-18s fora da máquina: %s%s\n' '' \
          "$(printf '%s' "$ext" | head -3 | tr '\n' ' ')" \
          "$([ "$n" -gt 3 ] && printf '(+%s)' "$((n - 3))" || true)"
      fi
    done < "$ws/.workspace"
    printf '\n'
  done

  if [ "$STATUS_PROCS" -eq 0 ] && [ "$STATUS_CONTS" -eq 0 ]; then
    printf '  Nada de pé.\n\n'
  else
    printf '  %s processo(s) e %s container(es) de pé.\n\n' "$STATUS_PROCS" "$STATUS_CONTS"
  fi
}

# ---------------------------------------------------------------- editor
#
# Abre o workspace no editor da pessoa. Três famílias, porque nem todo editor
# entende arquivo multi-root:
#   VSCode e forks (code, cursor, kiro, windsurf, codium) → recebem o .code-workspace
#   zed                                                   → recebe os N caminhos
#   qualquer outro (JetBrains, sublime, custom)           → recebe a pasta do workspace
#
# WORKSPACE_EDITOR manda; sem ela, o primeiro CLI encontrado ganha. O editor
# escolhido é sempre reportado, para nunca ser surpresa em máquina com vários.
EDITOR_CANDIDATES=(code cursor kiro windsurf code-insiders codium zed webstorm idea subl)
EDITOR_CONF="$WS_ROOT/.editor" # legado: migra para o config na primeira leitura

# A escolha do editor morava em $WS_ROOT/.editor. Migra sozinho para não pedir
# a mesma resposta de novo a quem já respondeu.
migrate_editor_conf() {
  local old
  [ -s "$EDITOR_CONF" ] || return 0
  [ -z "$(config_get editor)" ] || { rm -f "$EDITOR_CONF"; return 0; }
  old=$(head -1 "$EDITOR_CONF" | tr -d '[:space:]')
  [ -n "$old" ] && config_set editor "$old"
  rm -f "$EDITOR_CONF"
}

# Editores com CLI disponível na máquina, na ordem de preferência.
detect_editors() {
  local c
  for c in "${EDITOR_CANDIDATES[@]}"; do
    command -v "$c" >/dev/null 2>&1 && printf '%s\n' "$c"
  done
  return 0
}

# Editor em uso e de onde veio: "comando<TAB>origem".
# Precedência: variável de ambiente > escolha salva > primeiro detectado.
resolved_editor() {
  local first saved
  migrate_editor_conf
  saved=$(config_get editor)
  if [ -n "${WORKSPACE_EDITOR:-}" ]; then
    printf '%s\tWORKSPACE_EDITOR\n' "$WORKSPACE_EDITOR"
  elif [ -n "$saved" ]; then
    printf '%s\tescolha salva\n' "$saved"
  else
    first=$(detect_editors | head -1)
    if [ -n "$first" ]; then
      printf '%s\tdetectado\n' "$first"
    else
      printf '\tnenhum\n'
    fi
  fi
}

# editor          → mostra o que está em uso
# editor --list   → candidatos disponíveis (alimenta a caixa de seleção)
# editor <cmd>    → salva a escolha, para nunca mais perguntar
cmd_editor() {
  local arg=${1:-} r
  case $arg in
  --list) detect_editors ;;
  '')
    r=$(resolved_editor)
    printf '\n  Editor: %s (%s)\n\n' "$(printf '%s' "$r" | cut -f1)" "$(printf '%s' "$r" | cut -f2)"
    ;;
  *)
    if [ "$arg" != none ] && ! command -v "$arg" >/dev/null 2>&1; then
      die "'$arg' não está no PATH"
    fi
    config_set editor "$arg"
    printf '\n  Editor salvo: %s\n' "$arg"
    printf '  Para trocar depois: workspace.sh editor <comando>\n\n'
    ;;
  esac
}

launch_editor() {
  local ws=$1 wsfile=$2 cmd
  cmd=$(resolved_editor | cut -f1)

  if [ "$cmd" = none ]; then
    printf '    abra em: %s\n' "$wsfile"
    return 0
  fi

  if [ -z "$cmd" ] || ! command -v "$cmd" >/dev/null 2>&1; then
    warn "${cmd:+editor '$cmd' não está no PATH — }abra em: $wsfile"
    printf '       Escolha o editor com: workspace.sh editor <comando>  (ou "none" para silenciar)\n'
    return 0
  fi

  local -a argv
  case $cmd in
  code | code-insiders | codium | cursor | kiro | windsurf | trae)
    argv=("$wsfile")
    ;;
  zed | zeditor)
    argv=()
    while IFS=$'\t' read -r c _ _ _; do argv+=("$ws/$c"); done < "$ws/.workspace"
    ;;
  *)
    argv=("$ws") # JetBrains e afins abrem a pasta, que já contém os repos
    ;;
  esac

  if "$cmd" "${argv[@]}" >/dev/null 2>&1; then
    printf '    → abrindo no %s\n' "$cmd"
  else
    warn "$cmd não abriu — abra em: $wsfile"
  fi
}

# ---------------------------------------------------------------- open

open_one() {
  # Atribuições separadas de propósito: num único `local` o bash expande a
  # linha inteira antes de aplicar, e "$name" ainda não existiria.
  local name=$1
  local ws="$WS_ROOT/$name"
  local wsfile
  # Regera sempre, em vez de só quando falta a chave. A lista de ignorados
  # depende de quais OUTROS workspaces existem agora, então um arquivo escrito
  # antes da criação do vizinho já está velho. É estado derivado e barato.
  wsfile=$(write_wsfile "$ws" "$name")
  printf '  %s\n' "$name"
  launch_editor "$ws" "$wsfile"
}

cmd_open() {
  local names=() arg missing=()
  for arg in "$@"; do
    case $arg in
    -*) die "flag desconhecida: $arg" ;;
    *) names+=("$arg") ;;
    esac
  done
  if [ ${#names[@]} -eq 0 ]; then
    printf '\n  Informe qual abrir. Ativos:\n'
    cmd_list
    exit 1
  fi
  # Valida todos antes de abrir qualquer um: abrir uma janela e falhar na
  # seguinte deixa o estado pela metade sem ganho nenhum.
  for arg in "${names[@]}"; do
    [ -f "$WS_ROOT/$arg/.workspace" ] || missing+=("$arg")
  done
  [ ${#missing[@]} -eq 0 ] || die "não existe(m) em $WS_ROOT: ${missing[*]}"

  printf '\n'
  for arg in "${names[@]}"; do open_one "$arg"; done
  printf '\n'
  cmd_list
}

# ---------------------------------------------------------------- use
#
# Fixa uma aba de chat numa demanda: imprime o briefing dela e deixa o assistente
# trabalhando só ali. Leitura pura, com uma exceção — grava o CLAUDE.md quando
# falta, para alcançar workspace criado antes desta funcionalidade.
#
# Quem grava o PINO não é este comando, é o hook (pin-hook.sh): ele vê a linha de
# comando e recebe o session_id, que o script não tem como saber. Aqui só se
# imprime; a trava mora no hook, e é ele quem barra edição fora da demanda.

# CLAUDE.md do workspace: o que uma sessão nova precisa saber sem perguntar.
#
# Mora na pasta do workspace, ACIMA dos worktrees. O Claude Code lê os CLAUDE.md
# dos diretórios pai (verificado), então este carrega sozinho em qualquer sessão
# aberta dentro do workspace — e nenhum repositório fica sujo com arquivo que não
# é dele.
#
# Curto de propósito: carrega em TODA sessão daquela pasta, então cada linha
# custa token para sempre. Aqui vai só fato estável; o que muda de hora em hora
# é o .estado.md, que só é lido quando o `use` roda.
write_ws_claude_md() {
  local ws=$1 name=$2 repo base port
  {
    printf '# Workspace %s\n\n' "$name"
    printf 'Ambiente isolado da skill `workspace`. Os repositórios abaixo são git\n'
    printf 'worktrees: mexer neles não encosta no checkout principal nem nas outras\n'
    printf 'demandas.\n\n'
    printf '## Repositórios\n\n'
    while IFS=$'\t' read -r repo _ _ base; do
      [ -n "$repo" ] || continue
      port=''
      [ -f "$ws/.ports" ] &&
        port=$(awk -F'\t' -v r="$repo" '$1=="port" && $2==r{printf " · porta %s", $4}' "$ws/.ports")
      printf -- '- `%s` — base `%s`%s\n' "$repo" "$base" "$port"
    done < "$ws/.workspace"
    printf '\n## Regras\n\n'
    printf -- '- Subir e parar é `workspace.sh start %s` / `stop %s`. Não rode `npm run dev`,\n' "$name" "$name"
    printf -- '  `serverless offline` nem `docker compose up` na mão: as portas aqui são\n'
    printf -- '  remapeadas e quem sabe delas é o script.\n'
    printf -- '- O worktree nasce em detached HEAD. A branch da demanda se cria com\n'
    printf -- '  `git switch -c`, seguindo o `git-conventions.md` do repositório.\n'
    printf -- '- Log de cada app em `.logs/<repo>.log`.\n'
    printf -- '- O estado vivo da demanda (o que já foi feito, o que falta, decisões) fica\n'
    printf -- '  em `.estado.md`, ao lado deste arquivo.\n'
  } > "$ws/CLAUDE.md"
}

# Caderno mais velho que o código? Imprime 'velho', senão nada.
#
# Caderno desatualizado é pior que caderno nenhum: o assistente confia nele e
# parte de premissa vencida. Não dá para consertar sozinho, mas dá para avisar.
estado_stale() {
  local ws=$1 t_estado t_commit=0 t repo
  [ -f "$ws/.estado.md" ] || return 0
  t_estado=$(mtime_of "$ws/.estado.md")
  while IFS=$'\t' read -r repo _ _ _; do
    [ -n "$repo" ] || continue
    t=$(git -C "$ws/$repo" log -1 --format=%ct 2>/dev/null) || t=''
    [ -n "$t" ] && [ "$t" -gt "$t_commit" ] && t_commit=$t
  done < "$ws/.workspace"
  [ "$t_commit" -gt "$t_estado" ] && printf 'velho\n'
  return 0
}

cmd_use() {
  local name=${1:-} ws repo base cur

  case $name in
  '')
    # Sem nome: alimenta a caixa de seleção do chat.
    printf '\n  Escolha a demanda:\n\n'
    cmd_list
    printf '\n'
    return 0
    ;;
  none)
    printf '\n  Aba solta: nenhuma demanda fixada.\n\n'
    return 0
    ;;
  -*) die "flag desconhecida: $name" ;;
  esac

  ws="$WS_ROOT/$name"
  [ -f "$ws/.workspace" ] || die "workspace '$name' não existe em $WS_ROOT"
  # Workspace criado antes desta funcionalidade não tem o briefing; grava agora.
  [ -f "$ws/CLAUDE.md" ] || write_ws_claude_md "$ws" "$name"

  # Sem "fixado neste chat" aqui: quem grava o pino é o hook, que sabe o
  # session_id. O script não tem como saber se a trava está de pé, e afirmar
  # o que não se sabe é o jeito mais rápido de a pessoa confiar numa trava
  # que não existe. O hook confirma; aqui só sai o briefing.
  printf '\n  %s\n' "$name"
  printf '  criado em %s\n\n' "$(date_of "$ws")"

  while IFS=$'\t' read -r repo _ _ base; do
    [ -n "$repo" ] || continue
    if [ ! -d "$ws/$repo" ]; then
      printf '    %-20s %-7s ✗ pasta ausente\n' "$repo" ''
      continue
    fi
    status_repo "$ws" "$name" "$repo"
    cur=$(git -C "$ws/$repo" branch --show-current 2>/dev/null) || cur=''
    [ -n "$cur" ] || cur='sem branch ainda'
    printf '    %-20s %s → %s\n' '' "$base" "$cur"
    printf '    %-20s %s\n' '' "$(tilde "$ws/$repo")"
  done < "$ws/.workspace"

  if [ -f "$ws/.estado.md" ]; then
    printf '\n  Caderno (%s)' "$(date_of "$ws/.estado.md")"
    [ -n "$(estado_stale "$ws")" ] && printf '   ⚠  mais velho que o último commit'
    printf ':\n\n'
    sed 's/^/    /' "$ws/.estado.md"
  else
    printf '\n  Sem caderno ainda. Grave com /workspace note quando a demanda andar.\n'
  fi
  printf '\n'
}

# ---------------------------------------------------------------- create

# Nome livre: menor N cuja pasta não existe e cuja branch não existe em nenhum
# dos repos escolhidos (argumentos = caminhos dos repositórios).
next_name() {
  local n=1 name taken path
  while :; do
    name="ws-$n"
    taken=0
    [ -e "$WS_ROOT/$name" ] && taken=1
    if [ "$taken" -eq 0 ]; then
      for path in "$@"; do
        if git -C "$path" show-ref --verify --quiet "refs/heads/$name"; then
          taken=1
          break
        fi
      done
    fi
    [ "$taken" -eq 0 ] && { echo "$name"; return; }
    n=$((n + 1))
  done
}

# Ref base do repo: origin/HEAD, com fallbacks para repo sem origin/HEAD configurado.
base_ref() {
  local main=$1 ref
  if ref=$(git -C "$main" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
    echo "$ref"
    return
  fi
  for ref in origin/main origin/master main master; do
    if git -C "$main" show-ref --verify --quiet "refs/remotes/$ref" ||
      git -C "$main" show-ref --verify --quiet "refs/heads/$ref"; then
      echo "$ref"
      return
    fi
  done
  echo HEAD
}

CREATED_WORKTREES=()
CREATED_WS_DIR=''
CREATED_NAME=''

rollback() {
  local wt main
  printf '\n  Revertendo — nada fica pela metade.\n'
  for wt in "${CREATED_WORKTREES[@]+"${CREATED_WORKTREES[@]}"}"; do
    main=${wt%%:*}
    git -C "$main" worktree remove --force "${wt#*:}" >/dev/null 2>&1 || true
    git -C "$main" branch -D "$CREATED_NAME" >/dev/null 2>&1 || true
  done
  [ -n "$CREATED_WS_DIR" ] && rm -rf "$CREATED_WS_DIR"
  # Prune só depois de a pasta sumir: com o diretório no lugar o git não
  # considera o registro órfão e o deixa para trás.
  for wt in "${CREATED_WORKTREES[@]+"${CREATED_WORKTREES[@]}"}"; do
    git -C "${wt%%:*}" worktree prune >/dev/null 2>&1 || true
  done
  exit 1
}

cmd_create() {
  local open_editor=1 install=1 ports=1 wsname='' args=() repo
  while [ $# -gt 0 ]; do
    case $1 in
    --no-open) open_editor=0 ;;
    --no-install) install=0 ;;
    --no-ports) ports=0 ;;
    --name | -n)
      shift
      wsname=${1:-}
      [ -n "$wsname" ] || die "--name precisa de um valor"
      ;;
    --name=*) wsname=${1#*=} ;;
    -*) die "flag desconhecida: $1" ;;
    *) args+=("${1//,/ }") ;;
    esac
    shift
  done
  # shellcheck disable=SC2068
  set -- ${args[@]+${args[@]}}
  [ $# -gt 0 ] || die "informe ao menos um repositório. Ex: workspace.sh create api web"

  # ---- Validação: ou vale tudo, ou nada é criado.
  local map invalid=() ambiguous=() paths=() hits n
  ensure_roots
  map=$(discover_repos)
  [ -n "$map" ] || die "nenhum repositório git encontrado em $(printf '%s' "$ROOTS" | sed "s|$HOME|~|g")"
  for repo in "$@"; do
    hits=$(resolve_repo "$repo" "$map")
    n=$(printf '%s\n' "$hits" | grep -c . || true)
    if [ "$n" -eq 0 ]; then
      invalid+=("$repo")
    elif [ "$n" -gt 1 ]; then
      ambiguous+=("$repo → $(printf '%s' "$hits" | sed "s|$HOME|~|" | tr '\n' ' ')")
    else
      # dedupe por caminho, preservando a ordem digitada
      case " ${paths[*]+${paths[*]}} " in *" $hits "*) ;; *) paths+=("$hits") ;; esac
    fi
  done

  if [ ${#invalid[@]} -gt 0 ] || [ ${#ambiguous[@]} -gt 0 ]; then
    {
      printf '\n'
      [ ${#invalid[@]} -eq 0 ] || printf '  ✗ não encontrei em %s: %s\n' \
        "$(printf '%s' "$ROOTS" | sed "s|$HOME|~|g")" "${invalid[*]}"
      if [ ${#ambiguous[@]} -gt 0 ]; then
        printf '  ✗ nome em mais de uma pasta — passe o caminho para desempatar:\n'
        printf '      %s\n' "${ambiguous[@]}"
      fi
      if [ ${#invalid[@]} -gt 0 ]; then
        printf '    Disponíveis: '
        printf '%s\n' "$map" | cut -f1 | sort -u | tr '\n' ' '
        printf '\n'
        # A ferramenta só cria worktree de repo que já está no disco. Quando o
        # nome não existe, o que falta é o clone — dizer isso evita a caçada.
        printf '    Se o repo ainda não está aqui, clone dentro de %s e rode de novo.\n' \
          "$(printf '%s' "$ROOTS" | cut -d: -f1 | sed "s|$HOME|~|")"
      fi
      printf '    Nada foi criado.\n'
    } >&2
    exit 1
  fi

  # Dois repositórios de mesmo nome no mesmo workspace colidiriam na subpasta.
  local dup
  dup=$(printf '%s\n' "${paths[@]}" | sed 's|.*/||' | sort | uniq -d | tr '\n' ' ')
  [ -z "${dup// /}" ] || die "dois repositórios com o mesmo nome no mesmo workspace: $dup"

  # ---- Nome: o informado, validado; senão o menor ws-N livre.
  local name ws
  if [ -n "$wsname" ]; then
    case $wsname in
    *[!A-Za-z0-9._-]*) die "nome inválido: '$wsname' — use apenas letras, números, ponto, hífen e underscore" ;;
    .*) die "nome inválido: '$wsname' — não pode começar com ponto" ;;
    esac
    [ ${#wsname} -le 40 ] || die "nome muito longo: '$wsname' (máximo 40 caracteres)"
    [ ! -e "$WS_ROOT/$wsname" ] || die "já existe um workspace chamado '$wsname' — derrube com 'down $wsname' ou escolha outro nome"
    printf '%s\n' "$map" | cut -f1 | grep -qxF "$wsname" &&
      die "'$wsname' é o nome de um repositório — escolha outro nome para o workspace"
    name=$wsname
  else
    name=$(next_name "${paths[@]}")
  fi

  mkdir -p "$WS_ROOT"
  ws="$WS_ROOT/$name"
  CREATED_NAME=$name
  CREATED_WS_DIR=$ws
  trap rollback ERR INT TERM

  mkdir -p "$ws"
  : > "$ws/.workspace"
  printf '\n  %s\n\n' "$name"

  local main base f copied
  for main in "${paths[@]}"; do
    repo=${main##*/}
    git -C "$main" fetch --quiet origin 2>/dev/null || warn "$repo: fetch falhou, usando as refs locais"
    base=$(base_ref "$main")

    # --detach: o worktree fica no código da base sem ocupar a branch, para que
    # vários workspaces possam partir da mesma main. A branch da demanda é criada
    # depois, dentro do worktree, com git switch -c.
    if ! git -C "$main" worktree add --quiet --detach "$ws/$repo" "$base" 2>"$ws/.err"; then
      printf '    %-20s ✗ worktree falhou: %s\n' "$repo" "$(head -1 "$ws/.err")" >&2
      rollback
    fi
    CREATED_WORKTREES+=("$main:$ws/$repo")
    printf '%s\t%s\t%s\t%s\n' "$repo" "$main" '-' "$base" >> "$ws/.workspace"
    printf '    %-20s worktree criado   em %s\n' "$repo" "$base"

    copied=()
    for f in "${ENV_FILES[@]}"; do
      [ -f "$main/$f" ] && { cp "$main/$f" "$ws/$repo/$f"; copied+=("$f"); }
    done
    if [ ${#copied[@]} -gt 0 ]; then
      printf '    %-20s %s copiado\n' '' "${copied[*]}"
    else
      printf '    %-20s sem env versionado para copiar\n' ''
    fi

    if [ "$install" -eq 1 ]; then
      install_deps "$ws/$repo" "$repo"
    fi

    # Outras stacks não são instaladas, mas também não ficam em silêncio.
    if [ ! -f "$ws/$repo/package.json" ]; then
      local other=''
      [ -f "$ws/$repo/go.mod" ] && other='Go'
      { [ -f "$ws/$repo/requirements.txt" ] || [ -f "$ws/$repo/pyproject.toml" ]; } && other="${other:+$other e }Python"
      [ -f "$ws/$repo/composer.json" ] && other="${other:+$other e }PHP"
      [ -n "$other" ] && printf '    %-20s %s: nada instalado, a skill só cuida de Node\n' '' "$other"
    fi
  done

  trap - ERR INT TERM
  rm -f "$ws/.err" # buffer de erro do worktree add, não é para ficar

  # Antes do baseline: o remap escreve .env e pode criar .env.local, e isso é
  # artefato da skill — não pode contar como trabalho dele depois.
  if [ "$ports" -eq 1 ]; then
    remap_ports "$ws" "$(next_offset)"
  fi
  write_baseline "$ws"
  # Depois do remap: o briefing cita as portas, e antes disso elas não existem.
  write_ws_claude_md "$ws" "$name"

  # ---- .code-workspace multi-root
  #
  # Regera TODOS, não só o novo: o worktree que acabou de nascer precisa entrar
  # na lista de ignorados dos workspaces que já existiam, senão a janela deles
  # passa a mostrar este repo no Source Control.
  local wsfile
  refresh_all_wsfiles
  wsfile="$ws/$name.code-workspace"

  if [ "$ports" -eq 1 ]; then
    report_ports "$ws"
  else
    # Sem remap, sobra o aviso de colisão para você trocar na mão.
    local port others
    for main in "${paths[@]}"; do
      repo=${main##*/}
      [ -f "$ws/$repo/.env" ] || continue
      port=$(grep -m1 -E '^PORT=' "$ws/$repo/.env" 2>/dev/null | cut -d= -f2 | tr -d '"[:space:]') || true
      [ -n "${port:-}" ] || continue
      others=$(grep -rl -E "^PORT=$port\$" "$main/.env" "$WS_ROOT"/*/*/.env 2>/dev/null |
        grep -v "^$ws/$repo/\.env\$" |
        sed -e "s|^$main/\.env\$|$repo (principal)|" \
          -e "s|^$WS_ROOT/\([^/]*\)/\([^/]*\)/\.env\$|\1/\2|" | tr '\n' ' ')
      if [ -n "${others// /}" ]; then
        warn "$repo usa PORT=$port, igual a: $others"
        printf '       Troque no .env deste workspace antes de subir o segundo npm run dev.\n'
      fi
    done
  fi

  printf '\n    %s\n' "$wsfile"
  if [ "$open_editor" -eq 1 ]; then
    launch_editor "$ws" "$wsfile"
  fi
  printf '\n  Workspaces ativos:\n'
  cmd_list
}

# ------------------------------------------------------- janela do editor
#
# O `down` fecha a janela que estava com o workspace aberto. Duas peças:
# achar a janela certa e pedir o fechamento.
#
# ACHAR pelo título, não pelo processo. O título do VSCode traz
# "<nome> (Workspace)", porque o arquivo que o `create` gera é
# `<nome>.code-workspace`. Ir pelo processo não funciona: `_NET_WM_PID` é o
# processo principal em TODAS as janelas (uma instância serve várias), e o
# `cwd` de todo filho é o diretório de onde o editor foi lançado, não o
# workspace. O renderer por janela só carrega um UUID interno
# (`--vscode-window-config=vscode:<uuid>`), que não mapeia para o workspace.
#
# PEDIR com `_NET_CLOSE_WINDOW` na raiz — é o que o `wmctrl -c` faz. É pedido
# ao gerenciador de janelas, não `kill`: o editor fecha limpo, respeita o
# hot-exit e **pergunta se houver arquivo não salvo**. Nenhum trabalho se
# perde por este caminho, que é a razão de não matar processo.
#
# Sem instalar nada: `xprop` (x11-utils) e `perl` + `X11::Protocol` já vêm no
# sistema. Faltando qualquer peça — ou sem X11, no Wayland nativo e em sessão
# headless — a função desiste calada. Fechar janela é conveniência; nunca
# motivo para o `down` falhar.

# Classes X11 dos editores suportados. Lista própria, e não EDITOR_CANDIDATES,
# porque a classe não é sempre igual ao comando: codium → vscodium,
# subl → sublime_text, zed → dev.zed.Zed.
EDITOR_WM_CLASS_RE='code|codium|cursor|kiro|windsurf|trae|zed|jetbrains|sublime'

# Ids das janelas de editor abertas no workspace $1, uma por linha.
#
# Só casa o padrão "<nome> (Workspace)", que a própria skill produz. Casar o
# nome solto no título abriria falso positivo grave: um workspace chamado
# `web` casaria com a janela do checkout principal `web` e fecharia a janela
# errada. Editor que abre pasta em vez de .code-workspace
# (JetBrains, Zed) fica de fora de propósito — não vale o risco.
editor_windows_for() {
  local name=$1 w cls title esc re
  [ -n "${DISPLAY:-}" ] || return 0
  command -v xprop >/dev/null 2>&1 || return 0
  esc=$(printf '%s' "$name" | sed 's/[][\\.*^$(){}?+|]/\\&/g')
  # A fronteira à esquerda é obrigatória: sem ela, o nome casa como SUFIXO de
  # outro. O título "fix-web (Workspace)" contém a substring
  # "web (Workspace)", e um workspace chamado `web` fecharia
  # a janela do `fix-web`. O título do VSCode é
  # "[arquivo - ]<nome> (Workspace) - Visual Studio Code", então o nome está no
  # começo ou precedido de separador.
  re="(^|[^[:alnum:]._-])${esc} \\(Workspace\\)"
  for w in $(xprop -root _NET_CLIENT_LIST 2>/dev/null | sed 's/.*# //; s/,//g'); do
    [ -n "$w" ] || continue
    cls=$(xprop -id "$w" WM_CLASS 2>/dev/null) || continue
    printf '%s' "$cls" | grep -qiE "$EDITOR_WM_CLASS_RE" || continue
    title=$(xprop -id "$w" _NET_WM_NAME 2>/dev/null) || continue
    printf '%s' "$title" | grep -qE -- "$re" && printf '%s\n' "$w"
  done
  return 0
}

# Manda _NET_CLOSE_WINDOW para uma janela. Retorna != 0 se nem deu para tentar.
send_close_window() {
  local win=$1 cookie
  perl -MX11::Protocol -e1 >/dev/null 2>&1 || return 1
  # O X11::Auth do módulo não resolve o cookie do Xwayland do mutter (a entrada
  # é family FFFF), então o cookie vem do xauth. Sem ele, tenta sem auth: em
  # servidor permissivo funciona.
  cookie=$(xauth list 2>/dev/null | awk '/MIT-MAGIC-COOKIE-1/{print $3; exit}') || cookie=''
  WS_COOKIE="$cookie" WS_WIN="$win" perl -e '
    use X11::Protocol;
    my @auth = $ENV{WS_COOKIE} ? (["MIT-MAGIC-COOKIE-1", pack("H*", $ENV{WS_COOKIE})]) : ();
    my $X = X11::Protocol->new($ENV{DISPLAY}, @auth);
    my $win = hex($ENV{WS_WIN});
    # SubstructureRedirect|SubstructureNotify = 0x180000. A máscara TEM de ser
    # numérica: em arrayref o módulo aceita sem reclamar e o evento não chega
    # ao gerenciador de janelas — a janela não fecha e nada indica o porquê.
    $X->SendEvent($X->root, 0, 0x180000, $X->pack_event(
      name   => "ClientMessage",
      window => $win,
      type   => $X->atom("_NET_CLOSE_WINDOW"),
      format => 32,
      data   => pack("LLLLL", 0, 2, 0, 0, 0)));   # time=0 (CurrentTime), source=2
    $X->flush;
    $X->GetInputFocus;   # round-trip: garante que o evento saiu antes de sair
  ' >/dev/null 2>&1
}

# Fecha as janelas de editor do workspace $1 e reporta uma linha.
close_editor_windows() {
  local name=$1 w i
  local -a wins=()
  while read -r w; do [ -n "$w" ] && wins+=("$w"); done < <(editor_windows_for "$name")
  [ ${#wins[@]} -gt 0 ] || return 0

  for w in "${wins[@]}"; do
    send_close_window "$w" || {
      warn "janela do editor continua aberta (perl X11::Protocol ausente) — feche com Ctrl+Shift+W"
      return 0
    }
  done

  # Confirma em vez de presumir: se houver arquivo não salvo, o editor abre o
  # diálogo e a janela fica esperando resposta — o que vale dizer.
  for i in 1 2 3 4 5 6; do
    sleep 0.5
    [ -n "$(editor_windows_for "$name")" ] || {
      printf '    janela do editor fechada\n'
      return 0
    }
  done
  warn "a janela do editor não fechou — provavelmente há arquivo não salvo esperando sua resposta"
  return 0
}

# Remove a pasta do workspace, inclusive o que não pertence ao usuário.
#
# LocalStack, MySQL e moto rodam como root e o bind mount deixa arquivo de root
# dentro do worktree (localstack_data é o caso comum). Apagar entrada de
# diretório depende da permissão de escrita no diretório PAI: com um
# localstack_data de root:root o `rm` do usuário não consegue esvaziá-lo, falha,
# e a pasta do workspace inteira sobrevive. Antes esse `rm -rf` era solto, sem
# checagem — então o down anunciava sucesso e deixava a pasta para trás.
#
# Quem escreveu como root foi um container; então é um container que apaga, com
# o mesmo uid. Sem sudo, sem pedir senha. Se ainda assim sobrar, falha alto.
remove_ws_dir() {
  local ws=$1 name=$2 left
  rm -rf "$ws" 2>/dev/null || true
  [ -e "$ws" ] || return 0

  if docker info >/dev/null 2>&1; then
    warn "$name: resta conteúdo de root (dado de container) — removendo por container"
    docker run --rm -v "$(dirname "$ws")":/parent "$CLEAN_IMAGE" \
      rm -rf "/parent/$(basename "$ws")" >/dev/null 2>&1 || true
    [ -e "$ws" ] || return 0
  fi

  left=$(find "$ws" ! -user "$(id -un)" -printf '        %u:%g %p\n' 2>/dev/null | head -3 || true)
  {
    printf '\n  ✗ %s: a pasta não pôde ser removida.\n' "$name"
    [ -n "$left" ] && printf '      Resta conteúdo de outro usuário:\n%s\n' "$left"
    printf '      Apague com: sudo rm -rf %s\n' "$ws"
  } >&2
  return 1
}

# ---------------------------------------------------------------- down

cmd_down() {
  local names=() force=0 keep_editor=0 arg missing=() failed=0
  # WORKSPACE_CLOSE_EDITOR=0 desliga de vez, para quem não quer o comportamento.
  [ "${WORKSPACE_CLOSE_EDITOR:-1}" = 0 ] && keep_editor=1
  for arg in "$@"; do
    case $arg in
    --force) force=1 ;;
    --keep-editor) keep_editor=1 ;;
    -*) die "flag desconhecida: $arg" ;;
    *) names+=("$arg") ;;
    esac
  done

  if [ ${#names[@]} -eq 0 ]; then
    printf '\n  Informe qual derrubar. Ativos:\n'
    cmd_list
    exit 1
  fi
  # Nome errado aborta antes de remover qualquer coisa.
  for arg in "${names[@]}"; do
    [ -f "$WS_ROOT/$arg/.workspace" ] || missing+=("$arg")
  done
  [ ${#missing[@]} -eq 0 ] || die "não existe(m) em $WS_ROOT: ${missing[*]}"

  # Cada workspace é independente: um que recusa não impede os outros.
  for arg in "${names[@]}"; do
    down_one "$arg" "$force" "$keep_editor" || failed=1
  done
  printf '\n  Workspaces ativos:\n'
  cmd_list
  [ "$failed" -eq 0 ] || exit 1
}

down_one() {
  local name=$1 force=$2 keep_editor=${3:-0}
  local ws="$WS_ROOT/$name"

  # ---- Guarda: nada é apagado se houver trabalho não salvo ou não integrado.
  # O fetch é necessário: sem ele, uma branch mergeada no remoto ainda parece
  # pendente aqui, e o down recusaria à toa.
  local problems=() broken=() repo main branch base cur dirty ahead
  while IFS=$'\t' read -r repo main branch base; do
    [ -d "$ws/$repo" ] || continue
    # Worktree com link quebrado não tem o que proteger — não pode travar o down.
    if ! git -C "$ws/$repo" rev-parse --git-dir >/dev/null 2>&1; then
      broken+=("$repo")
      continue
    fi
    git -C "$main" fetch --quiet origin 2>/dev/null || warn "$repo: fetch falhou, usando as refs locais"
    dirty=$(new_dirt "$ws" "$repo")
    cur=$(git -C "$ws/$repo" branch --show-current 2>/dev/null) || cur=''
    ahead=$(git -C "$ws/$repo" log --oneline "$base..HEAD" 2>/dev/null | wc -l)
    [ -n "$dirty" ] && problems+=("$repo: $(printf '%s\n' "$dirty" | wc -l) arquivo(s) não commitado(s) — modificados ou novos")
    [ "$ahead" -gt 0 ] && problems+=("$repo: $ahead commit(s) em '${cur:-HEAD detached}' que não estão em $base")
  done < "$ws/.workspace"

  if [ ${#problems[@]} -gt 0 ] && [ "$force" -eq 0 ]; then
    {
      printf '\n  ✗ %s tem trabalho que seria perdido:\n' "$name"
      printf '      %s\n' "${problems[@]}"
      printf '\n    %s não foi removido. Integre (superpowers:finishing-a-development-branch)\n' "$name"
      printf '    ou rode de novo com --force para descartar.\n'
    } >&2
    return 1
  fi

  [ ${#broken[@]} -eq 0 ] || warn "worktree quebrado (removendo de qualquer forma): ${broken[*]}"

  printf '\n  Derrubando %s\n\n' "$name"

  # Primeiro para o que o start subiu: sem isto sobra processo órfão segurando a
  # porta do workspace que acabou de deixar de existir — e ninguém mais tem o
  # .pid para achá-lo.
  stop_workspace "$ws" "$name" || true

  # Antes de remover os worktrees: a janela solta os arquivos e não se vê a
  # tela piscando com as pastas faltando.
  [ "$keep_editor" -eq 1 ] || close_editor_windows "$name"

  local -a mains=()
  while IFS=$'\t' read -r repo main branch base; do
    cur=$(git -C "$ws/$repo" branch --show-current 2>/dev/null) || cur=''
    # A guarda já aprovou a remoção; se o remove normal recusar (arquivo não
    # rastreado, por exemplo), força — senão sobra registro órfão.
    git -C "$main" worktree remove "$ws/$repo" >/dev/null 2>&1 ||
      git -C "$main" worktree remove --force "$ws/$repo" >/dev/null 2>&1 || true
    mains+=("$main")
    printf '    %-20s worktree removido' "$repo"
    # "Mergeada" é medido contra a ref base do workspace, não contra o HEAD do
    # repo principal — que vive numa branch de trabalho e faria toda branch
    # parecer pendente.
    if [ -z "$cur" ]; then
      printf '   nenhuma branch foi criada\n'
    elif git -C "$main" merge-base --is-ancestor "$cur" "$base" 2>/dev/null; then
      git -C "$main" branch -D "$cur" >/dev/null 2>&1 || true
      printf '   branch %s apagada (já está em %s)\n' "$cur" "$base"
    elif [ "$force" -eq 1 ]; then
      git -C "$main" branch -D "$cur" >/dev/null 2>&1 || true
      printf '   branch %s descartada\n' "$cur"
    else
      printf '   branch %s mantida (ainda não está em %s)\n' "$cur" "$base"
    fi
  done < "$ws/.workspace"

  local removed=0
  remove_ws_dir "$ws" "$name" && removed=1
  # O prune vem DEPOIS de apagar a pasta: enquanto o diretório existe, o git
  # não considera o registro órfão e não limpa nada. Roda mesmo que a remoção
  # tenha falhado — o registro de worktree já saiu de qualquer forma.
  for main in "${mains[@]}"; do
    git -C "$main" worktree prune >/dev/null 2>&1 || true
  done
  [ "$removed" -eq 1 ] || return 1
}

# ---------------------------------------------------------------- prune
#
# Botão de pânico: limpa registro de worktree órfão em todos os repositórios e
# aponta pasta de workspace quebrada. Serve para quando alguém apaga a pasta na
# mão em vez de usar o down.
cmd_prune() {
  local map out found=0 d
  ensure_roots
  map=$(discover_repos)
  printf '\n  Procurando registro órfão de worktree\n\n'
  while IFS=$'\t' read -r name path; do
    # -v relata em stderr, não em stdout: sem o 2>&1 o relatório se perde e o
    # prune parece não ter achado nada.
    out=$(git -C "$path" worktree prune --dry-run -v 2>&1) || out=''
    [ -n "$out" ] || continue
    found=1
    git -C "$path" worktree prune >/dev/null 2>&1 || true
    printf '    %-28s %s registro(s) removido(s)\n' "$name" "$(printf '%s\n' "$out" | grep -c .)"
  done <<< "$map"
  [ "$found" -eq 1 ] || printf '    Nenhum registro órfão.\n'

  # Pasta em WORKSPACES_ROOT sem .workspace não é workspace — é resto.
  # E workspace cujo worktree perdeu o link precisa de down --force.
  if [ -d "$WS_ROOT" ]; then
    local repo _x bad
    for d in "$WS_ROOT"/*/; do
      [ -d "$d" ] || continue
      if [ ! -f "${d}.workspace" ]; then
        # Sem .workspace o down recusa o nome, então é aqui que a pasta sai.
        # Acontece com down interrompido e com resto de versão antiga da skill.
        printf '\n    ⚠  %s não tem .workspace — resto de execução interrompida.\n' "$(basename "$d")"
        remove_ws_dir "${d%/}" "$(basename "$d")" &&
          printf '       pasta removida\n'
        continue
      fi
      bad=''
      while IFS=$'\t' read -r repo _x _x _x; do
        [ -d "${d}${repo}" ] || continue
        git -C "${d}${repo}" rev-parse --git-dir >/dev/null 2>&1 || bad="${bad:+$bad }$repo"
      done < "${d}.workspace"
      if [ -n "$bad" ]; then
        printf '\n    ⚠  %s tem worktree quebrado: %s\n' "$(basename "$d")" "$bad"
        printf '       Remova com: workspace.sh down %s --force\n' "$(basename "$d")"
      fi
    done
  fi

  # Pino de aba de chat: o hook grava um arquivo por sessão, e sessão não avisa
  # quando morre. Sai o pino de workspace que não existe mais e o que passou de
  # duas semanas — sessão viva por tanto tempo não acontece, e pino velho só
  # ocupa espaço.
  if [ -d "$WS_ROOT/.pins" ]; then
    local pin alvo n=0
    for pin in "$WS_ROOT"/.pins/*; do
      [ -f "$pin" ] || continue
      alvo=$(head -1 "$pin" 2>/dev/null | tr -d '[:space:]')
      if [ ! -f "$WS_ROOT/$alvo/.workspace" ] || [ -n "$(find "$pin" -mtime +14 2>/dev/null)" ]; then
        rm -f "$pin"
        n=$((n + 1))
      fi
    done
    [ "$n" -gt 0 ] && printf '\n    %s pino(s) de chat sem dono removido(s)\n' "$n"
  fi

  printf '\n  Workspaces ativos:\n'
  cmd_list
}

# ---------------------------------------------------------------- setup
#
# Único comando interativo da ferramenta. Os outros nunca perguntam: falham com
# instrução, porque rodam sob agente e sob CI, onde esperar resposta é travar.
cmd_setup() {
  local found n ans sel p ok=() ws
  [ -t 0 ] || die "setup precisa de terminal interativo.
       Fora dele: export WORKSPACE_ROOTS=/caminho/dos/repos"

  printf '\n  Onde ficam seus repositórios?\n\n'
  found=$(detect_roots)
  n=$(printf '%s\n' "$found" | grep -c . || true)
  if [ "$n" -gt 0 ]; then
    printf '%s\n' "$found" | sed "s|$HOME|~|" | nl -w6 -s'  '
    printf '\n  Número, ou um caminho (vários separados por ":"): '
  else
    printf '  Não achei nenhuma pasta de código conhecida.\n'
    printf '  Digite o caminho (vários separados por ":"): '
  fi
  read -r ans
  [ -n "$ans" ] || die "nada escolhido — config não foi alterado"

  case $ans in
  '' | *[!0-9]*) sel="$ans" ;;
  *) sel=$(printf '%s\n' "$found" | sed -n "${ans}p") ;;
  esac
  [ -n "$sel" ] || die "opção inválida — config não foi alterado"

  local IFS=':'
  # shellcheck disable=SC2086
  set -- $sel
  unset IFS
  for p in "$@"; do
    p=${p/#\~/$HOME}
    [ -d "$p" ] || die "não existe: $p — config não foi alterado"
    ok+=("$p")
  done
  config_set roots "$(printf '%s:' "${ok[@]}" | sed 's/:$//')"

  printf '\n  Onde criar os workspaces? [%s] ' "$(printf '%s' "$WS_ROOT" | sed "s|$HOME|~|")"
  read -r ws
  if [ -n "$ws" ]; then
    ws=${ws/#\~/$HOME}
    config_set workspaces_root "$ws"
  fi

  printf '\n  Config gravado em %s\n' "$(printf '%s' "$CONFIG_FILE" | sed "s|$HOME|~|")"
  printf '  Confira com: workspace doctor\n\n'
}

# ---------------------------------------------------------------- doctor
#
# Diz o que falta na máquina e o comando que resolve. Existe para que instalar
# em máquina alheia não vire suporte por mensagem: a pessoa roda, lê e resolve.
cmd_doctor() {
  local ok='✓' bad='✗' opt='·' r map total ed src claude_dir settings

  printf '\n  workspace %s\n\n' "$VERSION"

  printf '  Essencial\n'
  printf '    %s bash %s\n' "$ok" "$BASH_VERSION"
  # Quem chegou aqui no Windows está no WSL (o resto foi recusado na partida),
  # e vale confirmar em voz alta: é o ponto em que mais se erra na instalação.
  if [ -r /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
    printf '    %s WSL — é o caminho certo no Windows\n' "$ok"
    case "$(pwd -P 2>/dev/null)" in
    /mnt/[a-z]/*)
      printf '    %s você está num disco do Windows (/mnt/...) — lento e com problema de\n' "$bad"
      printf '        permissão. Mantenha repositórios e workspaces dentro do WSL (~/).\n'
      ;;
    esac
  fi
  if command -v git >/dev/null 2>&1; then
    printf '    %s git %s\n' "$ok" "$(git --version | awk '{print $3}')"
  else
    printf '    %s git não está no PATH — instale antes de qualquer coisa\n' "$bad"
  fi
  if command -v workspace >/dev/null 2>&1; then
    printf '    %s workspace no PATH\n' "$ok"
  else
    printf '    %s workspace fora do PATH — adicione: export PATH="$HOME/.local/bin:$PATH"\n' "$bad"
  fi

  printf '\n  Configuração\n'
  if [ -f "$CONFIG_FILE" ]; then
    printf '    %s config em %s\n' "$ok" "$(printf '%s' "$CONFIG_FILE" | sed "s|$HOME|~|")"
  else
    printf '    %s sem config — será criado no primeiro uso, ou rode: workspace setup\n' "$opt"
  fi
  # Resolução própria, não-fatal: o ensure_roots morre quando não sabe, e o
  # doctor precisa justamente relatar esse caso em vez de morrer junto.
  local found n
  if [ -n "${WORKSPACE_ROOTS:-}" ]; then
    ROOTS="$WORKSPACE_ROOTS"
  else
    ROOTS=$(config_get roots)
    if [ -z "$ROOTS" ]; then
      found=$(detect_roots)
      n=$(printf '%s\n' "$found" | grep -c . || true)
      [ "$n" -eq 1 ] && ROOTS="$found"
    fi
  fi
  if [ -n "$ROOTS" ]; then
    printf '    %s repos em %s\n' "$ok" "$(printf '%s' "$ROOTS" | sed "s|$HOME|~|g")"
    map=$(discover_repos)
    total=$(printf '%s\n' "$map" | grep -c . || true)
    if [ "$total" -gt 0 ]; then
      printf '    %s %s repositórios encontrados\n' "$ok" "$total"
    else
      printf '    %s nenhum repositório git ali dentro — confira com: workspace setup\n' "$bad"
    fi
  else
    printf '    %s não sei onde ficam seus repos — rode: workspace setup\n' "$bad"
  fi
  if [ -d "$WS_ROOT" ] && [ -w "$WS_ROOT" ]; then
    printf '    %s workspaces em %s\n' "$ok" "$(printf '%s' "$WS_ROOT" | sed "s|$HOME|~|")"
  elif [ -e "$WS_ROOT" ]; then
    printf '    %s %s existe mas não é gravável\n' "$bad" "$(printf '%s' "$WS_ROOT" | sed "s|$HOME|~|")"
  else
    printf '    %s workspaces em %s (criado no primeiro create)\n' "$opt" "$(printf '%s' "$WS_ROOT" | sed "s|$HOME|~|")"
  fi
  r=$(resolved_editor)
  ed=$(printf '%s' "$r" | cut -f1)
  src=$(printf '%s' "$r" | cut -f2)
  if [ -n "$ed" ]; then
    printf '    %s editor: %s (%s)\n' "$ok" "$ed" "$src"
  else
    printf '    %s nenhum editor detectado — o create só imprime o caminho. Escolha com: workspace editor <cmd>\n' "$opt"
  fi

  printf '\n  Opcional\n'
  if command -v docker >/dev/null 2>&1; then
    printf '    %s docker — sobe repo que só tem compose, e limpa dado de container no down\n' "$ok"
  else
    printf '    %s sem docker — repo que só tem compose não sobe, e o down pode não limpar dado de container\n' "$opt"
  fi
  case $(port_probe_kind) in
  none) printf '    %s sem /dev/tcp e sem nc — o start não confirma que a porta abriu\n' "$opt" ;;
  *) printf '    %s teste de porta disponível — o start confirma que o app subiu\n' "$ok" ;;
  esac
  if command -v setsid >/dev/null 2>&1; then
    printf '    %s setsid — o stop alcança os processos filhos\n' "$ok"
  else
    printf '    %s sem setsid (normal no macOS) — o stop mata pelo PID e alcança menos filhos\n' "$opt"
  fi
  if [ -n "${DISPLAY:-}" ] && command -v xprop >/dev/null 2>&1; then
    printf '    %s xprop — o down fecha a janela do editor\n' "$ok"
  else
    printf '    %s sem xprop/X11 — o down não fecha a janela do editor (feche na mão)\n' "$opt"
  fi

  claude_dir="$HOME/.claude"
  settings="$claude_dir/settings.json"
  printf '\n  Claude Code (opcional)\n'
  if [ ! -d "$claude_dir" ]; then
    printf '    %s Claude Code não instalado — a ferramenta funciona igual pelo terminal\n' "$opt"
  else
    if [ -f "$claude_dir/skills/workspace/SKILL.md" ]; then
      printf '    %s skill instalada (/workspace no chat)\n' "$ok"
    else
      printf '    %s skill não instalada — rode o install.sh de novo para adicioná-la\n' "$opt"
    fi
    if [ -f "$settings" ] && grep -q 'pin-hook.sh' "$settings" 2>/dev/null; then
      printf '    %s hooks ligados (fixação da aba)\n' "$ok"
    else
      printf '    %s hooks não ligados — `use` dá o briefing, mas sem travar a aba\n' "$opt"
    fi
  fi
  printf '\n'
}

# ---------------------------------------------------------------- update

self_path() {
  local p=${BASH_SOURCE[0]}
  case $p in
  /*) printf '%s\n' "$p" ;;
  *) printf '%s\n' "$PWD/$p" ;;
  esac
}

# Baixa por cima de si mesmo. Só troca depois de provar que o que chegou é um
# script válido: rede que devolve página de erro não pode virar binário quebrado
# no PATH de ninguém.
cmd_update() {
  local self tmp new
  command -v curl >/dev/null 2>&1 || die "curl não está no PATH"
  self=$(self_path)
  [ -w "$self" ] || die "sem permissão de escrita em $self"

  tmp=$(mktemp)
  curl -fsSL "$RAW_URL/workspace.sh" -o "$tmp" 2>/dev/null ||
    { rm -f "$tmp"; die "não consegui baixar de $RAW_URL"; }
  head -1 "$tmp" | grep -q '^#!/usr/bin/env bash' ||
    { rm -f "$tmp"; die "o que baixou não parece o script — nada foi trocado"; }
  bash -n "$tmp" 2>/dev/null ||
    { rm -f "$tmp"; die "o script baixado não passou na checagem de sintaxe — nada foi trocado"; }

  new=$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)
  if [ "$new" = "$VERSION" ]; then
    rm -f "$tmp"
    printf '\n  Já está na última versão (%s)\n\n' "$VERSION"
    return 0
  fi
  cat "$tmp" > "$self" # por cima, para preservar permissão e inode
  rm -f "$tmp"
  printf '\n  Atualizado: %s → %s\n' "$VERSION" "$new"

  # A camada Claude Code sai do mesmo repo e envelhece junto. Atualizar só o
  # comando deixaria a SKILL.md descrevendo uma versão que não é mais esta.
  local skill="$HOME/.claude/skills/workspace" f t n=0
  if [ -d "$skill" ]; then
    for f in SKILL.md pin-hook.sh statusline.sh; do
      [ -f "$skill/$f" ] || continue
      t=$(mktemp)
      if curl -fsSL "$RAW_URL/claude/$f" -o "$t" 2>/dev/null && [ -s "$t" ]; then
        cat "$t" > "$skill/$f"
        n=$((n + 1))
      fi
      rm -f "$t"
    done
    [ "$n" -gt 0 ] && printf '  Skill do Claude Code: %s arquivo(s) atualizado(s)\n' "$n"
  fi
  printf '\n'
}

# ---------------------------------------------------------------- main

sub=${1:-list}
[ $# -gt 0 ] && shift
case $sub in
create) cmd_create "$@" ;;
open) cmd_open "$@" ;;
use) cmd_use "$@" ;;
status) cmd_status "$@" ;;
start) cmd_start "$@" ;;
stop) cmd_stop "$@" ;;
down) cmd_down "$@" ;;
top) cmd_top "$@" ;;
repos) cmd_repos ;;
editor) cmd_editor "$@" ;;
baseline)
  # Regrava o baseline: usar quando o workspace foi criado antes desta
  # funcionalidade, ou depois de instalar algo de propósito.
  [ $# -gt 0 ] || die "baseline precisa do nome do workspace"
  for arg in "$@"; do
    [ -f "$WS_ROOT/$arg/.workspace" ] || die "workspace '$arg' não existe em $WS_ROOT"
  done
  printf '\n'
  for arg in "$@"; do
    write_baseline "$WS_ROOT/$arg"
    printf '  Baseline regravado para %s\n' "$arg"
  done
  printf '\n'
  ;;
prune) cmd_prune ;;
setup) cmd_setup ;;
doctor) cmd_doctor ;;
update | --update) cmd_update ;;
version | --version | -v) printf '%s\n' "$VERSION" ;;
list) cmd_overview ;;
help | --help | -h) cmd_help ;;
*) die "subcomando desconhecido: $sub — rode 'workspace help'" ;;
esac
