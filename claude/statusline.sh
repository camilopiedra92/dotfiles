#!/usr/bin/env bash
# Statusline de Claude Code — https://code.claude.com/docs/en/statusline
#
# Claude ejecuta este script en CADA repintado de la interfaz y le pasa por
# stdin un JSON con el estado de la sesion. Lo que imprimimos en stdout es la
# linea que aparece bajo el cuadro de entrada.
#
# Dos reglas mandan sobre todo lo demas:
#
#   1. RAPIDO. Al correr en cada repintado, cualquier lentitud se nota como
#      lag al escribir. macOS trae bash 3.2 y cada `$(comando)` cuesta ~5ms de
#      fork, asi que aqui se usan expansiones del propio bash siempre que se
#      puede. Solo hay tres procesos externos en total: jq, git y date.
#
#   2. EL COLOR ES UNA ALARMA, NO DECORACION. Si todo se pinta de colores,
#      nada destaca. Lo normal va en gris y el color solo aparece cuando algo
#      pide atencion (contexto llenandose, limite cerca del tope).
#
# Los colores son ANSI de 16, no hex: asi la linea hereda la paleta del tema
# de Ghostty (Catppuccin Mocha) y sigue cuadrando si algun dia lo cambias.

set -uo pipefail

# Incluir archivos sin trackear en el marcador de "sucio" obliga a git a
# recorrer el arbol entero, que es justo lo caro en repos grandes. Ponlo en
# `normal` si prefieres verlos y tus repos son pequenos.
GIT_UNTRACKED=no

# --- Un unico jq para todo lo que viene del JSON -----------------------------
# Campos verificados contra el payload real de Claude Code 2.1.226.
# Los porcentajes ya llegan en escala 0-100; resets_at es epoch en segundos.
# `// -1` marca "este dato no vino" (jq solo trata null/false como ausente,
# asi que un 0 legitimo se conserva).
#
# Los campos se separan con \037 (US, "unit separator") y no con tabulador:
# para `read` el tabulador es whitespace, asi que dos seguidos cuentan como uno
# y un campo vacio en medio desplazaria todo lo que viene detras.
#
# jq lee el stdin del script directamente y `read` consume su salida por
# sustitucion de proceso: asi nos ahorramos un `cat` y un archivo temporal.
IFS=$'\037' read -r MODEL EFFORT CWD PROJDIR CTX_PCT CTX_IN CTX_MAX \
  H5_PCT H5_RESET D7_PCT D7_RESET COST WORKTREE < <(
  jq -r '[
    .model.display_name // "?",
    .effort.level // "",
    .workspace.current_dir // .cwd // "",
    .workspace.project_dir // "",
    .context_window.used_percentage // -1,
    .context_window.total_input_tokens // 0,
    .context_window.context_window_size // 0,
    .rate_limits.five_hour.used_percentage // -1,
    .rate_limits.five_hour.resets_at // 0,
    .rate_limits.seven_day.used_percentage // -1,
    .rate_limits.seven_day.resets_at // 0,
    .cost.total_cost_usd // 0,
    .worktree.name // ""
  ] | map(tostring) | join("\u001f")' 2>/dev/null
)

[ -n "${MODEL:-}" ] || exit 0   # jq fallo o JSON vacio: mejor nada que basura

# --- Paleta ------------------------------------------------------------------
R=$'\033[0m'; DIM=$'\033[90m'; B=$'\033[1m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
MAGENTA=$'\033[35m'; CYAN=$'\033[36m'

printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=$(date +%s)

OUT=""
add() { [ -n "$OUT" ] && OUT+="${DIM} · ${R}"; OUT+="$1"; }

# Las funciones de formato dejan el resultado en una global en vez de hacer
# `echo`: llamarlas dentro de $(...) costaria un fork cada una.

# Verde por debajo de 60, ambar a partir de ahi, rojo desde 80: el rojo debe
# aparecer con margen para reaccionar (compactar, abrir sesion nueva), no
# cuando ya te quedaste sin espacio.
level() { local p=${1%%.*}
  if   [ "$p" -ge 80 ]; then C=$RED
  elif [ "$p" -ge 60 ]; then C=$YELLOW
  else                       C=$GREEN; fi; }

# Barra de 8 celdas. Redondea al medio para que un 1% no se vea vacio del todo
# ni un 99% completo.
bar() {
  local p=${1%%.*} w=8 f i
  f=$(( (p * w + 50) / 100 )); [ "$f" -gt "$w" ] && f=$w; [ "$f" -lt 0 ] && f=0
  BAR=""
  for ((i = 0; i < w; i++)); do
    if [ "$i" -lt "$f" ]; then BAR+="█"; else BAR+="░"; fi
  done
}

# Cuanto falta para que el limite se renueve. En unidades gruesas a proposito:
# saber si faltan "2h" o "3d" cambia lo que haces; los minutos exactos no.
until_reset() {
  local t=${1%%.*} d; REL=""
  [ "$t" -gt 0 ] 2>/dev/null || return
  d=$(( t - NOW )); [ "$d" -lt 0 ] && d=0
  if   [ "$d" -ge 86400 ]; then REL="$(( d / 86400 ))d"
  elif [ "$d" -ge 3600  ]; then REL="$(( d / 3600  ))h"
  else                          REL="$(( d / 60    ))m"; fi
}

k() { local n=${1%%.*}
  if [ "$n" -ge 1000 ]; then K="$(( n / 1000 ))k"; else K="$n"; fi; }

# --- Modelo y esfuerzo -------------------------------------------------------
seg="${MAGENTA}${B}󰚩 ${MODEL}${R}"
[ -n "$EFFORT" ] && seg+="${DIM}:${EFFORT}${R}"
add "$seg"

# --- Ubicacion ---------------------------------------------------------------
# Dentro de un proyecto muestra la ruta relativa a su raiz (`repo/src/api`).
# El path absoluto completo no aporta: ya sabes donde vives.
CWD=${CWD:-$PWD}
if [ -n "$PROJDIR" ] && [ "$CWD" != "$PROJDIR" ] && [[ "$CWD" == "$PROJDIR"/* ]]; then
  LOC="${PROJDIR##*/}/${CWD#"$PROJDIR"/}"
else
  LOC="${CWD##*/}"
fi
add "${CYAN}${B} ${LOC}${R}"

# --- Git ---------------------------------------------------------------------
# Una sola llamada da rama, estado y distancia con el remoto. La salida se
# parsea con `case` de bash, sin sed ni grep: son dos forks que no hacen falta.
# --no-optional-locks evita que este script escriba en .git y pelee con el git
# que corras tu a mano.
BRANCH=""; OID=""; AB=""; DIRTY=0
while IFS= read -r line; do
  case $line in
    '# branch.head '*) BRANCH=${line#'# branch.head '} ;;
    '# branch.oid '*)  OID=${line#'# branch.oid '} ;;
    '# branch.ab '*)   AB=${line#'# branch.ab '} ;;
    [12u?]*)           DIRTY=1 ;;
  esac
done < <(git --no-optional-locks status --porcelain=v2 --branch \
           "--untracked-files=$GIT_UNTRACKED" 2>/dev/null)

# En detached HEAD git reporta "(detached)" como rama; ahi el hash corto dice mas.
[ "$BRANCH" = "(detached)" ] && BRANCH=${OID:0:7}

if [ -n "$BRANCH" ]; then
  seg="${MAGENTA} ${BRANCH}${R}"
  [ "$DIRTY" = 1 ] && seg+="${YELLOW}*${R}"
  # Commits de diferencia con el remoto: lo unico del estado de git que suele
  # sorprenderte a mitad de sesion.
  if [ -n "$AB" ]; then
    ahead=${AB%% *}; behind=${AB##* }
    [ "$ahead" != "+0" ] && seg+="${DIM}⇡${ahead#+}${R}"
    [ "$behind" != "-0" ] && seg+="${DIM}⇣${behind#-}${R}"
  fi
  add "$seg"
fi
[ -n "$WORKTREE" ] && add "${DIM}⑂ ${WORKTREE}${R}"

# --- Contexto ----------------------------------------------------------------
# Lo mas accionable de la linea: cuando esto llega al rojo toca /compact o
# abrir sesion nueva antes de que Claude empiece a olvidar el principio.
if [ "${CTX_PCT%%.*}" -ge 0 ] 2>/dev/null; then
  level "$CTX_PCT"; bar "$CTX_PCT"
  k "$CTX_IN"; used=$K
  k "$CTX_MAX"; total=$K
  add "${C}${BAR} ${CTX_PCT%%.*}%${R}${DIM} ${used}/${total}${R}"
fi

# --- Limites de uso ----------------------------------------------------------
# Solo aparecen si la API ya los ha reportado: llegan en las cabeceras de la
# respuesta, asi que al arrancar la sesion todavia no estan.
limit() {
  local label=$1 pct=$2 reset=$3 s
  [ "${pct%%.*}" -ge 0 ] 2>/dev/null || return
  level "$pct"; until_reset "$reset"
  printf -v s '%s%s%s%s%.0f%%%s' "$DIM" "$label" "$R" "$C" "$pct" "$R"
  [ -n "$REL" ] && s+="${DIM}↻${REL}${R}"
  add "$s"
}
limit "5h " "$H5_PCT" "$H5_RESET"
limit "7d " "$D7_PCT" "$D7_RESET"

# --- Coste de la sesion ------------------------------------------------------
printf -v cost '%s$%.2f%s' "$DIM" "$COST" "$R"
add "$cost"

printf '%s' "$OUT"
