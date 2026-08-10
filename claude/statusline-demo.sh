#!/usr/bin/env bash
# Renderiza las dos statuslines con payloads de ejemplo, sin arrancar Claude.
#
# Existe por dos motivos. Uno, iterar sobre el diseno: reiniciar Claude para
# ver el efecto de mover un color es un ciclo demasiado lento. Y dos, los
# escenarios interesantes (limite al 95%, contexto en rojo, PR con cambios
# pedidos, un subagente atascado) no se pueden provocar a voluntad, asi que la
# unica forma de haberlos visto antes de que ocurran de verdad es simularlos.
#
# Las marcas de tiempo se calculan relativas a ahora, si no las cuentas atras
# saldrian siempre vencidas.
#
# Uso:  ./statusline-demo.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SL="$HERE/statusline.sh"
SUB="$HERE/subagent-statusline.sh"
NOW=$(date +%s)
NOW_MS=$(( NOW * 1000 ))

title() { printf '\n\033[1;34m══ %s\033[0m\n\n' "$1"; }
show()  { printf '\033[90m%s\033[39m\n' "$1"; "$SL" <<<"$2"; printf '\n\n'; }

# Payloads reutilizados en las dos variantes de estilo.
P_NORMAL="{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$(dirname "$HERE")\"},
  \"effort\":{\"level\":\"high\"},\"cost\":{\"total_cost_usd\":1.23},
  \"context_window\":{\"total_input_tokens\":84213,\"context_window_size\":200000,\"used_percentage\":42},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":18,\"resets_at\":$((NOW + 7800))},
    \"seven_day\":{\"used_percentage\":31,\"resets_at\":$((NOW + 250000))}}
}"

title "statusline principal — estilo powerline (el configurado)"

show "sesion recien abierta — sin contexto ni limites todavia" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Sonnet 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$HERE\"},
  \"cost\":{\"total_cost_usd\":0},
  \"context_window\":{\"total_input_tokens\":0,\"context_window_size\":200000,\"used_percentage\":null}
}"

show "trabajo normal" "$P_NORMAL"

show "ritmo insostenible — el rayo avisa antes de que el % se ponga rojo" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$HERE\"},
  \"effort\":{\"level\":\"high\"},\"cost\":{\"total_cost_usd\":4.10},
  \"context_window\":{\"total_input_tokens\":96000,\"context_window_size\":200000,\"used_percentage\":48},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":55,\"resets_at\":$((NOW + 10800))},
    \"seven_day\":{\"used_percentage\":22,\"resets_at\":$((NOW + 400000))}}
}"

show "todo al limite — contexto y ventana de 5h en rojo" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Opus 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$(dirname "$HERE")\"},
  \"effort\":{\"level\":\"max\"},\"cost\":{\"total_cost_usd\":18.70},
  \"context_window\":{\"total_input_tokens\":186000,\"context_window_size\":200000,\"used_percentage\":93},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":95,\"resets_at\":$((NOW + 900))},
    \"seven_day\":{\"used_percentage\":68,\"resets_at\":$((NOW + 400000))}}
}"

show "worktree + PR con cambios pedidos" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Fable 5\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$HERE\"},
  \"cost\":{\"total_cost_usd\":0.42},
  \"context_window\":{\"total_input_tokens\":25000,\"context_window_size\":200000,\"used_percentage\":13},
  \"worktree\":{\"name\":\"feat-statusline\"},
  \"pr\":{\"number\":142,\"url\":\"x\",\"review_state\":\"changes_requested\"},
  \"rate_limits\":{\"five_hour\":{\"used_percentage\":7,\"resets_at\":$((NOW + 15000))}}
}"

show "ventana de 1M de contexto" "{
  \"cwd\":\"$HERE\",\"model\":{\"display_name\":\"Opus 5 (1M)\"},
  \"workspace\":{\"current_dir\":\"$HERE\",\"project_dir\":\"$HERE\"},
  \"effort\":{\"level\":\"xhigh\"},\"cost\":{\"total_cost_usd\":7.55},
  \"context_window\":{\"total_input_tokens\":310000,\"context_window_size\":1000000,\"used_percentage\":31},
  \"rate_limits\":{
    \"five_hour\":{\"used_percentage\":61,\"resets_at\":$((NOW + 5400))},
    \"seven_day\":{\"used_percentage\":88,\"resets_at\":$((NOW + 90000))}}
}"

title "las otras variantes (STYLE y LINES en el script)"

printf '\033[90mSTYLE=minimal\033[39m\n'; STYLE=minimal "$SL" <<<"$P_NORMAL"; printf '\n\n'
printf '\033[90mLINES=1 STYLE=powerline\033[39m\n'; LINES=1 "$SL" <<<"$P_NORMAL"; printf '\n\n'
printf '\033[90mLINES=1 STYLE=minimal\033[39m\n'; LINES=1 STYLE=minimal "$SL" <<<"$P_NORMAL"; printf '\n\n'

title "statusline por subagente (panel de agentes)"

# Este script escupe JSONL, que es lo que Claude consume. Para verlo como se
# vera en pantalla hay que extraer el campo content y dejar que el terminal
# interprete los escapes, que es justo lo que hace el bucle.
"$SUB" <<EOF | jq -r '"  \(.id)  \(.content)"'
{"columns":80,"tasks":[
 {"id":"explore  ","label":"Explorar auth","status":"running","startTime":$((NOW_MS - 134000)),
  "model":"claude-opus-5","effort":"high","contextWindowSize":200000,"tokenCount":18400,
  "tokenSamples":[200,900,2400,5100,8800,12000,15200,18400]},
 {"id":"tests    ","label":"Correr tests","status":"running","startTime":$((NOW_MS - 4300000)),
  "model":"claude-sonnet-5","contextWindowSize":200000,"tokenCount":172000,
  "tokenSamples":[160000,168000,171000,171500,171800,172000]},
 {"id":"atascado ","label":"Sin avanzar","status":"running","startTime":$((NOW_MS - 900000)),
  "model":"claude-opus-5","contextWindowSize":200000,"tokenCount":41000,
  "tokenSamples":[41000,41000,41000,41000,41000,41000]},
 {"id":"recien   ","label":"Recien lanzado","status":"running","startTime":$((NOW_MS - 2000)),
  "tokenCount":120,"tokenSamples":[120]}
]}
EOF

printf '\n\033[90mel tercero lleva 15m sin mover un token: el sparkline plano lo delata\033[39m\n'

title "escala de la barra"

# Rampa de 0 a 100. Es la unica forma de ver si los bloques parciales avanzan
# de forma pareja o si hay saltos feos en algun tramo.
for p in $(seq 0 5 100); do
  raw=$(printf '{"model":{"display_name":"x"},"cwd":"/tmp","context_window":
        {"total_input_tokens":0,"context_window_size":1,"used_percentage":%d}}' "$p" | "$SL")
  clean=$(printf '%s' "$raw" | sed $'s/\033\\[[0-9;]*m//g')
  gauge=${clean%% ${p}%*}          # recorta desde " NN%" hacia el final
  printf '  %3d%%  %s\n' "$p" "${gauge: -8}"
done
printf '\n'
