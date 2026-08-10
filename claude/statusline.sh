#!/usr/bin/env bash
# Statusline de Claude Code — https://code.claude.com/docs/en/statusline
#
# Claude ejecuta este script en CADA repintado de la interfaz y le pasa por
# stdin un JSON con el estado de la sesion. Lo que imprimimos en stdout es la
# linea que aparece bajo el cuadro de entrada.
#
# Para verla sin arrancar Claude:  ./statusline-demo.sh
#
# Tres reglas mandan sobre todo lo demas:
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
#   3. ANCHO ACOTADO. El payload no dice cuanto mide la terminal, asi que
#      todo lo que puede crecer sin limite (rama, ruta) se trunca. Una
#      statusline que hace wrap se come una linea del chat en cada repintado.
#
# Los colores son ANSI de 16, no hex: asi la linea hereda la paleta del tema
# de Ghostty (Catppuccin Mocha) y sigue cuadrando si algun dia lo cambias.

set -uo pipefail

# Incluir archivos sin trackear en el marcador de "sucio" obliga a git a
# recorrer el arbol entero, que es justo lo caro en repos grandes. Ponlo en
# `normal` si prefieres verlos y tus repos son pequenos.
GIT_UNTRACKED=no

MAX_BRANCH=22   # caracteres antes de truncar
MAX_PATH=30

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
  H5_PCT H5_RESET D7_PCT D7_RESET COST WORKTREE PR_NUM PR_STATE < <(
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
    .worktree.name // "",
    .pr.number // 0,
    .pr.review_state // ""
  ] | map(tostring) | join("\u001f")' 2>/dev/null
)

[ -n "${MODEL:-}" ] || exit 0   # jq fallo o JSON vacio: mejor nada que basura

# --- Paleta ------------------------------------------------------------------
# Ojo con el reset: aqui NUNCA se emite \033[0m. Claude renderiza la statusline
# dentro de su propio estilo (la documenta como "printed using dimmed colors"),
# y un reset total cancelaria ese estilo a mitad de linea, dejando la primera
# mitad atenuada y la segunda no. \033[39m devuelve solo el color de texto al
# por defecto y no toca negrita ni atenuado, asi que compone con lo que sea que
# Claude ponga por fuera. Por lo mismo no se usa negrita: el enfasis se da con
# color, que es reversible sin efectos colaterales.
FG=$'\033[39m'
DIM=$'\033[90m'
GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'
MAGENTA=$'\033[35m'; CYAN=$'\033[36m'

printf -v NOW '%(%s)T' -1 2>/dev/null || NOW=$(date +%s)

OUT=""
add() { [ -n "$OUT" ] && OUT+="${DIM} · ${FG}"; OUT+="$1"; }

# Las funciones de formato dejan el resultado en una global en vez de hacer
# `echo`: llamarlas dentro de $(...) costaria un fork cada una.

# Verde por debajo de 60, ambar a partir de ahi, rojo desde 80: el rojo debe
# aparecer con margen para reaccionar (compactar, abrir sesion nueva), no
# cuando ya te quedaste sin espacio.
level() { local p=${1%%.*}
  if   [ "$p" -ge 80 ]; then C=$RED
  elif [ "$p" -ge 60 ]; then C=$YELLOW
  else                       C=$GREEN; fi; }

# Barra de 8 celdas con resolucion de octavo de celda: los bloques parciales
# (▏▎▍▌▋▊▉) dan 64 pasos en el mismo ancho que 8 daria con celdas enteras, asi
# que la barra se mueve de verdad en vez de saltar de 12 en 12 por ciento.
bar() {
  local p=${1%%.*} w=8 e full rem i
  [ "$p" -lt 0 ] && p=0; [ "$p" -gt 100 ] && p=100
  e=$(( p * w * 8 / 100 ))          # octavos llenos
  full=$(( e / 8 )); rem=$(( e % 8 ))
  BAR=""
  for ((i = 0; i < full; i++)); do BAR+="█"; done
  if [ "$full" -lt "$w" ]; then
    case $rem in
      0) BAR+="░" ;; 1) BAR+="▏" ;; 2) BAR+="▎" ;; 3) BAR+="▍" ;;
      4) BAR+="▌" ;; 5) BAR+="▋" ;; 6) BAR+="▊" ;; 7) BAR+="▉" ;;
    esac
    for ((i = full + 1; i < w; i++)); do BAR+="░"; done
  fi
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

# El dato que de verdad decide si paras o sigues no es el porcentaje gastado,
# sino si el ritmo actual te deja llegar a la renovacion. Como conocemos el
# largo de la ventana y cuando se renueva, sabemos cuando empezo, y de ahi sale
# el consumo proyectado al final del periodo. El rayo avisa de que a este ritmo
# te quedas sin limite antes de tiempo, que es accionable mucho antes de que el
# porcentaje se ponga rojo por si solo.
burn() {
  local pct=${1%%.*} reset=${2%%.*} window=$3 elapsed
  BURN=""
  [ "$reset" -gt 0 ] 2>/dev/null || return
  elapsed=$(( NOW - (reset - window) ))
  # Al principio de la ventana cualquier proyeccion es ruido: con un 3% de
  # periodo transcurrido, un solo mensaje ya extrapola a "te lo acabas".
  [ "$elapsed" -gt $(( window / 10 )) ] || return
  [ $(( pct * window / elapsed )) -gt 100 ] && BURN="⚡"
}

# Con la ventana de 1M, "1000k" se lee mal justo cuando mas cifras hay en
# pantalla. A partir del millon se pasa a M con un decimal, y sin el decimal
# cuando es exacto: 1M, 1.3M.
k() { local n=${1%%.*} whole tenth
  if [ "$n" -ge 1000000 ]; then
    whole=$(( n / 1000000 )); tenth=$(( (n % 1000000) / 100000 ))
    if [ "$tenth" -eq 0 ]; then K="${whole}M"; else K="${whole}.${tenth}M"; fi
  elif [ "$n" -ge 1000 ]; then K="$(( n / 1000 ))k"
  else K="$n"; fi; }

# --- Modelo y esfuerzo -------------------------------------------------------
seg="${MAGENTA}󰚩 ${MODEL}${FG}"
[ -n "$EFFORT" ] && seg+="${DIM}:${EFFORT}${FG}"
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
# Se recorta por la izquierda: en una ruta larga lo que te ubica es el final.
[ ${#LOC} -gt $MAX_PATH ] && LOC="…${LOC: -$(( MAX_PATH - 1 ))}"
add "${CYAN} ${LOC}${FG}"

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
  # Las ramas con prefijo de ticket se van a 40 caracteres sin despeinarse.
  [ ${#BRANCH} -gt $MAX_BRANCH ] && BRANCH="${BRANCH:0:$(( MAX_BRANCH - 1 ))}…"
  seg="${MAGENTA} ${BRANCH}${FG}"
  [ "$DIRTY" = 1 ] && seg+="${YELLOW}*${FG}"
  # Commits de diferencia con el remoto: lo unico del estado de git que suele
  # sorprenderte a mitad de sesion.
  if [ -n "$AB" ]; then
    ahead=${AB%% *}; behind=${AB##* }
    [ "$ahead" != "+0" ] && seg+="${DIM}⇡${ahead#+}${FG}"
    [ "$behind" != "-0" ] && seg+="${DIM}⇣${behind#-}${FG}"
  fi
  add "$seg"
fi
[ -n "$WORKTREE" ] && add "${DIM}⑂ ${WORKTREE}${FG}"

# --- Pull request ------------------------------------------------------------
# Solo aparece si la rama tiene PR abierto. El color es el estado de revision:
# que te hayan pedido cambios mientras trabajas es justo lo que quieres saber
# sin cambiar de ventana.
if [ "$PR_NUM" != "0" ]; then
  case $PR_STATE in
    approved)          c=$GREEN ;;
    changes_requested) c=$RED ;;
    *)                 c=$DIM ;;
  esac
  add "${c} #${PR_NUM}${FG}"
fi

# --- Contexto ----------------------------------------------------------------
# Lo mas accionable de la linea: cuando esto llega al rojo toca /compact o
# abrir sesion nueva antes de que Claude empiece a olvidar el principio.
if [ "${CTX_PCT%%.*}" -ge 0 ] 2>/dev/null; then
  level "$CTX_PCT"; bar "$CTX_PCT"
  k "$CTX_IN"; used=$K
  k "$CTX_MAX"; total=$K
  add "${C}${BAR} ${CTX_PCT%%.*}%${FG}${DIM} ${used}/${total}${FG}"
fi

# --- Limites de uso ----------------------------------------------------------
# Solo aparecen si la API ya los ha reportado: llegan en las cabeceras de la
# respuesta, asi que al arrancar la sesion todavia no estan.
limit() {
  local label=$1 pct=$2 reset=$3 window=$4 s
  [ "${pct%%.*}" -ge 0 ] 2>/dev/null || return
  level "$pct"; until_reset "$reset"; burn "$pct" "$reset" "$window"
  printf -v s '%s%s%s%s%.0f%%%s' "$DIM" "$label" "$FG" "$C" "$pct" "$FG"
  [ -n "$BURN" ] && s+="${YELLOW}${BURN}${FG}"
  [ -n "$REL" ] && s+="${DIM}↻${REL}${FG}"
  add "$s"
}
limit "5h " "$H5_PCT" "$H5_RESET" 18000
limit "7d " "$D7_PCT" "$D7_RESET" 604800

# --- Coste de la sesion ------------------------------------------------------
printf -v cost '%s$%.2f%s' "$DIM" "$COST" "$FG"
add "$cost"

printf '%s' "$OUT"
