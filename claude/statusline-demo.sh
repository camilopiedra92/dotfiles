#!/usr/bin/env bash
# Renderiza la statusline con payloads de ejemplo, sin arrancar Claude Code.
#
# Existe por dos motivos. Uno, iterar sobre el diseno: reiniciar Claude para
# ver el efecto de mover un color es un ciclo demasiado lento. Y dos, los
# escenarios interesantes (limite al 95%, contexto en rojo, PR con cambios
# pedidos) no se pueden provocar a voluntad, asi que la unica forma de haberlos
# visto antes de que ocurran de verdad es simularlos.
#
# Los `resets_at` se calculan relativos a ahora, si no las cuentas atras
# saldrian siempre vencidas.
#
# Uso:  ./statusline-demo.sh
set -uo pipefail

SL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/statusline.sh"
NOW=$(date +%s)

show() {
  printf '\033[90m%s\033[39m\n  ' "$1"
  "$SL" <<<"$2"
  printf '\n\n'
}

show "sesion recien abierta — sin contexto ni limites todavia" '{
  "cwd":"/Users/piedrac/Development","model":{"display_name":"Sonnet 5"},
  "workspace":{"current_dir":"/Users/piedrac/Development","project_dir":"/Users/piedrac/Development"},
  "cost":{"total_cost_usd":0},
  "context_window":{"total_input_tokens":0,"context_window_size":200000,"used_percentage":null}
}'

show "trabajo normal" "{
  \"cwd\":\"$PWD\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$PWD\",\"project_dir\":\"$PWD\"},
  \"effort\":{\"level\":\"high\"},\"cost\":{\"total_cost_usd\":1.23},
  \"context_window\":{\"total_input_tokens\":84213,\"context_window_size\":200000,\"used_percentage\":42},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":18,\"resets_at\":$((NOW + 7800))},
    \"seven_day\":{\"used_percentage\":31,\"resets_at\":$((NOW + 250000))}}
}"

show "ritmo insostenible — el rayo avisa antes de que el % se ponga rojo" "{
  \"cwd\":\"$PWD\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$PWD\",\"project_dir\":\"$PWD\"},
  \"effort\":{\"level\":\"high\"},\"cost\":{\"total_cost_usd\":4.10},
  \"context_window\":{\"total_input_tokens\":96000,\"context_window_size\":200000,\"used_percentage\":48},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":55,\"resets_at\":$((NOW + 10800))},
    \"seven_day\":{\"used_percentage\":22,\"resets_at\":$((NOW + 400000))}}
}"

show "todo al limite — contexto y ventana de 5h en rojo" "{
  \"cwd\":\"$PWD/ghostty\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$PWD/ghostty\",\"project_dir\":\"$PWD\"},
  \"effort\":{\"level\":\"max\"},\"cost\":{\"total_cost_usd\":18.70},
  \"context_window\":{\"total_input_tokens\":186000,\"context_window_size\":200000,\"used_percentage\":93},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":95,\"resets_at\":$((NOW + 900))},
    \"seven_day\":{\"used_percentage\":68,\"resets_at\":$((NOW + 400000))}}
}"

show "worktree + PR con cambios pedidos + rama larga que se trunca" "{
  \"cwd\":\"$PWD\",\"model\":{\"display_name\":\"Fable 5\"},
  \"workspace\":{\"current_dir\":\"$PWD\",\"project_dir\":\"$PWD\"},
  \"cost\":{\"total_cost_usd\":0.42},
  \"context_window\":{\"total_input_tokens\":25000,\"context_window_size\":200000,\"used_percentage\":13},
  \"worktree\":{\"name\":\"feat-statusline\"},
  \"pr\":{\"number\":142,\"url\":\"x\",\"review_state\":\"changes_requested\"},
  \"rate_limits\":{\"five_hour\":{\"used_percentage\":7,\"resets_at\":$((NOW + 15000))}}
}"

show "ventana de 1M de contexto" "{
  \"cwd\":\"$PWD\",\"model\":{\"display_name\":\"Opus 5 (1M)\"},
  \"workspace\":{\"current_dir\":\"$PWD\",\"project_dir\":\"$PWD\"},
  \"effort\":{\"level\":\"xhigh\"},\"cost\":{\"total_cost_usd\":7.55},
  \"context_window\":{\"total_input_tokens\":310000,\"context_window_size\":1000000,\"used_percentage\":31},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":61,\"resets_at\":$((NOW + 5400))},
    \"seven_day\":{\"used_percentage\":88,\"resets_at\":$((NOW + 90000))}}
}"

# Rampa de 0 a 100. Es la unica forma de ver si los bloques parciales avanzan
# de forma pareja o si hay saltos feos en algun tramo.
printf '\033[90mescala de la barra:\033[39m\n'
for p in $(seq 0 5 100); do
  raw=$(printf '{"model":{"display_name":"x"},"cwd":"/tmp","context_window":
        {"total_input_tokens":0,"context_window_size":1,"used_percentage":%d}}' "$p" | "$SL")
  clean=$(printf '%s' "$raw" | sed $'s/\033\\[[0-9;]*m//g')
  gauge=${clean%% ${p}%*}          # recorta desde " NN%" hacia el final
  printf '  %3d%%  %s\n' "$p" "${gauge: -8}"
done
