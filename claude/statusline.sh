#!/usr/bin/env bash
# Claude Code statusline — https://code.claude.com/docs/en/statusline
#
# Claude runs this script on EVERY repaint of the interface, passing the
# session state as JSON on stdin. Whatever we print on stdout becomes the
# line (or lines) shown under the input box.
#
# To see it without launching Claude:  ./statusline-demo.sh
#
# ── Design notes ─────────────────────────────────────────────────────────────
#
#   1. FAST. Since it runs on every repaint, any slowness shows up as lag
#      while typing. macOS ships bash 3.2 and each `$(command)` costs ~5ms of
#      fork, so this uses bash's own expansions wherever possible. Only three
#      external processes in total: jq, git and date.
#
#   2. CHROME ON TOP, DATA BELOW. The first line is identity: who you are,
#      where you are, on which branch. It changes rarely and can afford
#      decoration. The second one is gauges: context, limits, cost. There
#      color is an alarm, not an ornament, which is why it sits on a clean
#      background: if everything is color-filled, the red of a 90% context no
#      longer stands out.
#
#   3. BOUNDED WIDTH. The payload does not say how wide the terminal is, so
#      everything that can grow without limit (branch, path) gets truncated.
#      A statusline that wraps eats one line of chat on every repaint.
#
#   4. NEVER \033[0m. See the long note in the palette section.
#
# Colors are 16-color ANSI, not hex: that way the line inherits the palette of
# the Ghostty theme (Catppuccin Mocha) and still matches if you ever change it.

set -uo pipefail

# ── Settings ─────────────────────────────────────────────────────────────────
# Read from the environment when present, so statusline-demo.sh can render the
# variants without touching this file.
STYLE=${STYLE:-powerline} # powerline | minimal  (look of the identity line)
LINES=${LINES:-2}         # 2 | 1                (1 = all together, short terminals)

# Counting untracked files toward the "dirty" marker forces git to walk the
# whole tree, which is the expensive part in large repos. Set it to `normal` if
# you would rather see them and your repos are small.
GIT_UNTRACKED=no

MAX_BRANCH=22 # characters before truncating
MAX_PATH=30

# --- A single jq for everything coming from the JSON -------------------------
# Fields verified against the real Claude Code 2.1.226 payload.
# Percentages already arrive on a 0-100 scale; resets_at is epoch seconds.
# `// -1` marks "this value did not arrive" (jq only treats null/false as
# missing, so a legitimate 0 is preserved).
#
# Fields are separated with \037 (US, "unit separator") rather than a tab: for
# `read` a tab is whitespace, so two in a row count as one and a single empty
# field in the middle would shift everything after it.
#
# jq reads the script's stdin directly and `read` consumes its output through
# process substitution: that saves us a `cat` and a temporary file.
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
  ] | map(tostring) | join("\u001f")' 2> /dev/null
  )

[ -n "${MODEL:-}" ] || exit 0 # jq failed or empty JSON: better nothing than junk

# --- Palette -----------------------------------------------------------------
# Mind the reset: this NEVER emits \033[0m. Claude renders the statusline
# inside its own style (documented as "printed using dimmed colors"), and a
# full reset would cancel it mid-line, leaving the first half dimmed and the
# second half not. We use selective resets instead: \033[39m restores the
# foreground and \033[49m the background, neither touches bold or dim, so they
# compose with whatever Claude wraps around us. For the same reason there is no
# bold: emphasis comes from color, which is reversible without side effects.
FG=$'\033[39m'
BG=$'\033[49m'
DIM=$'\033[90m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'

# Powerline separators. They need a Nerd Font (here, JetBrainsMono Nerd Font)
# and are written as literal characters because bash 3.2 does not expand \u
# inside $'...'.
#
# The thick one separates different colors. The thin one is needed when two
# segments share a background: there the thick one would be drawn in the same
# color as the background it falls on, would be invisible, and the two segments
# would read as one.
PL=''
PL_THIN=''

printf -v NOW '%(%s)T' -1 2> /dev/null || NOW=$(date +%s)

# --- Helpers -----------------------------------------------------------------
# The formatting functions leave their result in a global instead of echoing
# it: calling them inside $(...) would cost one fork each.

# Green below 60, amber from there, red from 80: red must show up with enough
# margin to react (compact, open a new session), not once you have already run
# out of room.
level() {
  local p=${1%%.*}
  if [ "$p" -ge 80 ]; then
    C=$RED
  elif [ "$p" -ge 60 ]; then
    C=$YELLOW
  else C=$GREEN; fi
}

# An 8-cell bar with eighth-of-a-cell resolution: the partial blocks
# (▏▎▍▌▋▊▉) give 64 steps in the same width that whole cells would give 8, so
# the bar actually moves instead of jumping 12 percent at a time.
bar() {
  local p=${1%%.*} w=8 e full rem i
  [ "$p" -lt 0 ] && p=0
  [ "$p" -gt 100 ] && p=100
  e=$((p * w * 8 / 100)) # filled eighths
  full=$((e / 8))
  rem=$((e % 8))
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

# How long until the limit resets. Deliberately coarse units: knowing whether
# it is "2h" or "3d" changes what you do; the exact minutes do not.
until_reset() {
  local t=${1%%.*} d
  REL=""
  [ "$t" -gt 0 ] 2> /dev/null || return
  d=$((t - NOW))
  [ "$d" -lt 0 ] && d=0
  if [ "$d" -ge 86400 ]; then
    REL="$((d / 86400))d"
  elif [ "$d" -ge 3600 ]; then
    REL="$((d / 3600))h"
  else REL="$((d / 60))m"; fi
}

# What really decides whether you stop or carry on is not the percentage
# spent, but whether the current pace lets you reach the reset. Since we know
# the window length and when it resets, we know when it started, and from that
# comes the projected usage at the end of the period. The bolt warns that at
# this pace you run out early, which is actionable long before the percentage
# turns red on its own.
burn() {
  local pct=${1%%.*} reset=${2%%.*} window=$3 elapsed
  BURN=""
  [ "$reset" -gt 0 ] 2> /dev/null || return
  elapsed=$((NOW - (reset - window)))
  # Early in the window any projection is noise: at 3% of the period elapsed,
  # a single message already extrapolates to "you will burn through it".
  [ "$elapsed" -gt $((window / 10)) ] || return
  [ $((pct * window / elapsed)) -gt 100 ] && BURN="⚡"
}

# With the 1M window, "1000k" reads badly exactly when there are the most
# digits on screen. From a million on we switch to M with one decimal, and
# without the decimal when it is exact: 1M, 1.3M.
k() {
  local n=${1%%.*} whole tenth
  if [ "$n" -ge 1000000 ]; then
    whole=$((n / 1000000))
    tenth=$(((n % 1000000) / 100000))
    if [ "$tenth" -eq 0 ]; then K="${whole}M"; else K="${whole}.${tenth}M"; fi
  elif [ "$n" -ge 1000 ]; then
    K="$((n / 1000))k"
  else K="$n"; fi
}

# ── Line 1: identity ─────────────────────────────────────────────────────────
# Segments are accumulated first and painted afterwards, because powerline
# needs to know the next segment's color to draw the separator (the triangle
# takes the previous background as foreground and the next one as background;
# that splice is what keeps the seam invisible).
S_BG=()
S_ACC=()
S_INK=()
S_TXT=()
seg() { # seg <background code> <same color as text> <ink on top> <content>
  S_BG+=("$1")
  S_ACC+=("$2")
  S_INK+=("$3")
  S_TXT+=("$4")
}

# --- Model and effort ---
body="󰚩 ${MODEL}"
[ -n "$EFFORT" ] && body+=" ${EFFORT}"
seg 45 35 30 "$body"

# --- Location ---
# Inside a project it shows the path relative to its root (`repo/src/api`).
# The full absolute path adds nothing: you already know where you live.
CWD=${CWD:-$PWD}
if [ -n "$PROJDIR" ] && [ "$CWD" != "$PROJDIR" ] && [[ "$CWD" == "$PROJDIR"/* ]]; then
  LOC="${PROJDIR##*/}/${CWD#"$PROJDIR"/}"
else
  LOC="${CWD##*/}"
fi
# Trimmed from the left: in a long path what locates you is the tail.
[ ${#LOC} -gt $MAX_PATH ] && LOC="…${LOC: -$((MAX_PATH - 1))}"
seg 44 34 30 " ${LOC}"

# --- Git ---
# A single call gives branch, state and distance from the remote. The output is
# parsed with bash `case`, no sed or grep: two forks we do not need.
# --no-optional-locks keeps this script from writing into .git and fighting the
# git you run by hand.
BRANCH=""
OID=""
AB=""
DIRTY=0
while IFS= read -r line; do
  case $line in
    '# branch.head '*) BRANCH=${line#'# branch.head '} ;;
    '# branch.oid '*) OID=${line#'# branch.oid '} ;;
    '# branch.ab '*) AB=${line#'# branch.ab '} ;;
    [12u?]*) DIRTY=1 ;;
  esac
done < <(git --no-optional-locks status --porcelain=v2 --branch \
  "--untracked-files=$GIT_UNTRACKED" 2> /dev/null)

# On detached HEAD git reports "(detached)" as the branch; the short hash says more.
[ "$BRANCH" = "(detached)" ] && BRANCH=${OID:0:7}

if [ -n "$BRANCH" ]; then
  # Branches with a ticket prefix run to 40 characters without breaking a sweat.
  [ ${#BRANCH} -gt $MAX_BRANCH ] && BRANCH="${BRANCH:0:$((MAX_BRANCH - 1))}…"
  body=" ${BRANCH}"
  [ "$DIRTY" = 1 ] && body+="*"
  # Commits of difference with the remote: the one bit of git state that tends
  # to surprise you mid-session.
  if [ -n "$AB" ]; then
    ahead=${AB%% *}
    behind=${AB##* }
    [ "$ahead" != "+0" ] && body+=" ⇡${ahead#+}"
    [ "$behind" != "-0" ] && body+=" ⇣${behind#-}"
  fi
  seg 100 90 37 "$body"
fi

[ -n "$WORKTREE" ] && seg 100 90 37 "⑂ ${WORKTREE}"

# --- Pull request ---
# Only shows up if the branch has an open PR. The color is the review state:
# having changes requested while you work is exactly what you want to know
# without switching windows.
if [ "$PR_NUM" != "0" ]; then
  case $PR_STATE in
    approved) seg 42 32 30 " #${PR_NUM}" ;;
    changes_requested) seg 41 31 30 " #${PR_NUM}" ;;
    *) seg 100 90 37 " #${PR_NUM}" ;;
  esac
fi

# --- Painting line 1 ---
L1=""
n=${#S_BG[@]}
if [ "$STYLE" = powerline ]; then
  for ((i = 0; i < n; i++)); do
    L1+=$'\033['"${S_BG[$i]};${S_INK[$i]}m ${S_TXT[$i]} "
    # The separator inherits the next segment's background; on the last one it
    # returns to the default background, which is what gives it a clean right edge.
    if [ $((i + 1)) -lt "$n" ]; then
      if [ "${S_BG[$i]}" = "${S_BG[$((i + 1))]}" ]; then
        L1+=$'\033['"${S_INK[$i]}m${PL_THIN}"
      else
        L1+=$'\033['"${S_ACC[$i]};${S_BG[$((i + 1))]}m${PL}"
      fi
    else
      L1+="${BG}"$'\033['"${S_ACC[$i]}m${PL}${FG}"
    fi
  done
else
  for ((i = 0; i < n; i++)); do
    [ "$i" -gt 0 ] && L1+="${DIM} · ${FG}"
    L1+=$'\033['"${S_ACC[$i]}m${S_TXT[$i]}${FG}"
  done
fi

# ── Line 2: gauges ───────────────────────────────────────────────────────────
L2=""
add() {
  [ -n "$L2" ] && L2+="${DIM} · ${FG}"
  L2+="$1"
}

# --- Context ---
# The most actionable of all: when this hits red it is time for /compact or a
# new session, before Claude starts forgetting the beginning.
if [ "${CTX_PCT%%.*}" -ge 0 ] 2> /dev/null; then
  level "$CTX_PCT"
  bar "$CTX_PCT"
  k "$CTX_IN"
  used=$K
  k "$CTX_MAX"
  total=$K
  add "${DIM}ctx ${FG}${C}${BAR} ${CTX_PCT%%.*}%${FG}${DIM} ${used}/${total}${FG}"
fi

# --- Usage limits ---
# They only appear once the API has reported them: they arrive in the response
# headers, so at the start of a session they are not there yet.
limit() {
  local label=$1 pct=$2 reset=$3 window=$4 s
  [ "${pct%%.*}" -ge 0 ] 2> /dev/null || return
  level "$pct"
  until_reset "$reset"
  burn "$pct" "$reset" "$window"
  printf -v s '%s%s %s%s%.0f%%%s' "$DIM" "$label" "$FG" "$C" "$pct" "$FG"
  [ -n "$BURN" ] && s+="${YELLOW}${BURN}${FG}"
  [ -n "$REL" ] && s+="${DIM}↻${REL}${FG}"
  add "$s"
}
limit "5h" "$H5_PCT" "$H5_RESET" 18000
limit "7d" "$D7_PCT" "$D7_RESET" 604800

printf -v cost '%s$%.2f%s' "$DIM" "$COST" "$FG"
add "$cost"

# ── Output ───────────────────────────────────────────────────────────────────
# Claude splits stdout on \n, trims each line and drops the empty ones, so
# spacing cannot rely on leading spaces or blank lines.
if [ "$LINES" = 2 ] && [ -n "$L2" ]; then
  printf '%s\n%s' "$L1" "$L2"
elif [ -n "$L2" ]; then
  # On a single line powerline already closes with its triangle and adding a
  # dot behind it looks like dirt; in minimal the separator is needed.
  if [ "$STYLE" = powerline ]; then
    printf '%s %s' "$L1" "$L2"
  else printf '%s%s · %s%s' "$L1" "$DIM" "$FG" "$L2"; fi
else
  printf '%s' "$L1"
fi
