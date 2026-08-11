#!/usr/bin/env bash
# Renders both statuslines with sample payloads, without launching Claude.
#
# It exists for two reasons. One, iterating on the design: restarting Claude to
# see the effect of moving a color is far too slow a loop. And two, the
# interesting scenarios (limit at 95%, context in red, PR with changes
# requested, a stuck subagent) cannot be triggered at will, so simulating them
# is the only way to have seen them before they actually happen.
#
# Timestamps are computed relative to now, otherwise the countdowns would
# always render as expired.
#
# Usage:  ./statusline-demo.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SL="$HERE/statusline.sh"
SUB="$HERE/subagent-statusline.sh"
NOW=$(date +%s)
NOW_MS=$(( NOW * 1000 ))

title() { printf '\n\033[1;34m══ %s\033[0m\n\n' "$1"; }
show()  { printf '\033[90m%s\033[39m\n' "$1"; "$SL" <<<"$2"; printf '\n\n'; }

# Payloads reused across both style variants.
P_NORMAL="{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$(dirname "$HERE")\"},
  \"effort\":{\"level\":\"high\"},\"cost\":{\"total_cost_usd\":1.23},
  \"context_window\":{\"total_input_tokens\":84213,\"context_window_size\":200000,\"used_percentage\":42},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":18,\"resets_at\":$((NOW + 7800))},
    \"seven_day\":{\"used_percentage\":31,\"resets_at\":$((NOW + 250000))}}
}"

title "main statusline — powerline style (the configured one)"

show "freshly opened session — no context or limits yet" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Sonnet 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$HERE\"},
  \"cost\":{\"total_cost_usd\":0},
  \"context_window\":{\"total_input_tokens\":0,\"context_window_size\":200000,\"used_percentage\":null}
}"

show "normal work" "$P_NORMAL"

show "unsustainable pace — the bolt warns before the % turns red" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$HERE\"},
  \"effort\":{\"level\":\"high\"},\"cost\":{\"total_cost_usd\":4.10},
  \"context_window\":{\"total_input_tokens\":96000,\"context_window_size\":200000,\"used_percentage\":48},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":55,\"resets_at\":$((NOW + 10800))},
    \"seven_day\":{\"used_percentage\":22,\"resets_at\":$((NOW + 400000))}}
}"

show "everything maxed out — context and 5h window in red" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$(dirname "$HERE")\"},
  \"effort\":{\"level\":\"max\"},\"cost\":{\"total_cost_usd\":18.70},
  \"context_window\":{\"total_input_tokens\":186000,\"context_window_size\":200000,\"used_percentage\":93},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":95,\"resets_at\":$((NOW + 900))},
    \"seven_day\":{\"used_percentage\":68,\"resets_at\":$((NOW + 400000))}}
}"

show "worktree + PR with changes requested" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Fable 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$HERE\"},
  \"cost\":{\"total_cost_usd\":0.42},
  \"context_window\":{\"total_input_tokens\":25000,\"context_window_size\":200000,\"used_percentage\":13},
  \"worktree\":{\"name\":\"feat-statusline\"},
  \"pr\":{\"number\":142,\"url\":\"x\",\"review_state\":\"changes_requested\"},
  \"rate_limits\":{\"five_hour\":{\"used_percentage\":7,\"resets_at\":$((NOW + 15000))}}
}"

show "1M context window" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Opus 5 (1M)\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$HERE\"},
  \"effort\":{\"level\":\"xhigh\"},\"cost\":{\"total_cost_usd\":7.55},
  \"context_window\":{\"total_input_tokens\":310000,\"context_window_size\":1000000,\"used_percentage\":31},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":61,\"resets_at\":$((NOW + 5400))},
    \"seven_day\":{\"used_percentage\":88,\"resets_at\":$((NOW + 90000))}}
}"

title "the other variants (STYLE and LINES in the script)"

printf '\033[90mSTYLE=minimal\033[39m\n'; STYLE=minimal "$SL" <<<"$P_NORMAL"; printf '\n\n'
printf '\033[90mLINES=1 STYLE=powerline\033[39m\n'; LINES=1 "$SL" <<<"$P_NORMAL"; printf '\n\n'
printf '\033[90mLINES=1 STYLE=minimal\033[39m\n'; LINES=1 STYLE=minimal "$SL" <<<"$P_NORMAL"; printf '\n\n'

title "per-subagent statusline (agent panel)"

# This script spits out JSONL, which is what Claude consumes. To see it as it
# will look on screen we extract the content field and let the terminal
# interpret the escapes, which is exactly what the pipe below does.
"$SUB" <<EOF | jq -r '"  \(.id)  \(.content)"'
{"columns":80,"tasks":[
 {"id":"explore  ","name":"brisk-otter","label":"Explore auth","status":"running","startTime":$((NOW_MS - 134000)),
  "model":"claude-opus-5","effort":"high","contextWindowSize":200000,"tokenCount":18400,
  "tokenSamples":[200,900,2400,5100,8800,12000,15200,18400]},
 {"id":"tests    ","name":"calm-badger","label":"Run tests","status":"running","startTime":$((NOW_MS - 4300000)),
  "model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":172000,
  "tokenSamples":[160000,168000,171000,171500,171800,172000]},
 {"id":"stuck    ","name":"quiet-heron","label":"Not moving","status":"running","startTime":$((NOW_MS - 900000)),
  "model":"claude-opus-5","contextWindowSize":200000,"tokenCount":41000,
  "tokenSamples":[41000,41000,41000,41000,41000,41000]},
 {"id":"fresh    ","name":"eager-marten","label":"Just launched","status":"running","startTime":$((NOW_MS - 2000)),
  "tokenCount":120,"tokenSamples":[120]}
]}
EOF

printf '\n\033[90mthe third one has not moved a token in 15m: the flat sparkline exposes it\033[39m\n'

title "bar scale"

# A ramp from 0 to 100. It is the only way to see whether the partial blocks
# advance evenly or there are ugly jumps somewhere along the way.
for p in $(seq 0 5 100); do
  raw=$(printf '{"model":{"display_name":"x"},"cwd":"/tmp","context_window":
        {"total_input_tokens":0,"context_window_size":1,"used_percentage":%d}}' "$p" | "$SL")
  clean=$(printf '%s' "$raw" | sed $'s/\033\\[[0-9;]*m//g')
  gauge=${clean%% ${p}%*}          # trim from " NN%" to the end
  printf '  %3d%%  %s\n' "$p" "${gauge: -8}"
done
printf '\n'
