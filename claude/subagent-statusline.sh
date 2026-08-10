#!/usr/bin/env bash
# Statusline por subagente — decora cada fila del panel de agentes.
#
# Es un mecanismo distinto al de la statusline principal y esta mucho menos
# documentado, asi que el contrato, verificado leyendo Claude Code 2.1.226:
#
#   ENTRADA (stdin, un solo JSON):
#     { "columns": <ancho util ya descontado el marco>,
#       "tasks": [ { "id", "name", "type", "status", "description", "label",
#                    "startTime",          // epoch, en milisegundos
#                    "model", "effort",
#                    "contextWindowSize",  // puede faltar
#                    "tokenCount",
#                    "tokenSamples": [ ... ]   // historico, hasta 16 muestras
#                    "cwd" } ] }
#
#   SALIDA: JSONL — una linea {"id": "...", "content": "..."} por agente.
#     Las lineas que no parseen se descartan con un error en el log, asi que
#     conviene salir siempre con codigo 0 y no imprimir nada si algo falla.
#
#   CADENCIA: primer tick a los 300ms y luego cada 5s, con timeout de 5s.
#
# Lo interesante es `tokenSamples`: Claude guarda el historico de consumo de
# cada agente, asi que se puede dibujar un sparkline y ver de un vistazo cual
# esta trabajando de verdad y cual lleva rato atascado. Un numero suelto no
# distingue "20k tokens y subiendo" de "20k tokens y parado hace un minuto".
#
# Todo se resuelve en un unico jq: la entrada es un array y el trabajo es
# aritmetica sobre listas, que en jq sale mas corto y mas rapido que iterar en
# bash con un proceso por fila.
set -uo pipefail

jq -c -r '
  # ── Formato ────────────────────────────────────────────────────────────────
  def num:
    if . >= 1000000 then "\((. / 100000 | floor) / 10)M"
    elif . >= 1000  then "\(. / 1000 | floor)k"
    else "\(. | floor)" end;

  def dur:
    if   . >= 3600 then "\(. / 3600 | floor)h\((. % 3600) / 60 | floor)m"
    elif . >= 60   then "\(. / 60 | floor)m\(. % 60 | floor)s"
    else "\(. | floor)s" end;

  # Sparkline normalizado a su propio minimo y maximo. Interesa la FORMA de la
  # curva, no la escala: al lado ya va la cifra absoluta.
  #
  # La serie plana no se descarta, se dibuja plana. Un agente que lleva quince
  # minutos sin mover un token es justo lo que este panel tiene que delatar, y
  # dejar el hueco en blanco lo haria indistinguible de "no hay datos".
  def spark:
    (map(select(type == "number"))) as $v
    | if ($v | length) < 2 then "" else
        ($v | min) as $lo | ($v | max) as $hi
        | if $hi <= $lo then ($v | map("▁") | join(""))
          else $v | map(((. - $lo) * 7 / ($hi - $lo)) | round)
                  | map(["▁","▂","▃","▄","▅","▆","▇","█"][.]) | join("")
          end
      end;

  # ── Paleta ─────────────────────────────────────────────────────────────────
  # Mismo criterio que en la statusline principal: nunca \u001b[0m, solo
  # \u001b[39m, para no cancelar el estilo que Claude aplica por fuera.
  "\u001b[90m" as $dim  | "\u001b[39m" as $fg
  | "\u001b[32m" as $green | "\u001b[33m" as $yellow | "\u001b[31m" as $red

  | (.columns // 80) as $cols
  | (now * 1000) as $now_ms

  | .tasks[]
  | . as $t
  # startTime llega en milisegundos; se acepta tambien en segundos por si
  # cambia, porque confundir las unidades da duraciones absurdas y silenciosas.
  | (if ($t.startTime // 0) > 100000000000
       then ($now_ms - $t.startTime) / 1000
       else (($now_ms / 1000) - ($t.startTime // 0)) end
     | if . < 0 then 0 else . end) as $secs
  | ($t.tokenCount // 0) as $tok
  | ($t.contextWindowSize // 0) as $win
  | (if $win > 0 then (($tok / $win) * 100 | floor) else -1 end) as $pct
  | (if   $pct >= 80 then $red
     elif $pct >= 60 then $yellow
     else $green end) as $c
  | (($t.tokenSamples // []) | spark) as $sp

  # ── Composicion, de mas a menos importante ─────────────────────────────────
  # El panel ya dice que hace cada agente; esto anade la telemetria que no se
  # ve: cuanto lleva, cuanto ha gastado y si sigue avanzando.
  | [ "\($dim)\($secs | dur)\($fg)",
      (if $pct >= 0
         then "\($c)\($tok | num)\($fg)\($dim)/\($win | num) \($pct)%\($fg)"
         else "\($dim)\($tok | num) tok\($fg)" end),
      (if $sp != "" and $cols >= 44 then "\($dim)\($sp)\($fg)" else empty end),
      (if ($t.effort // "") != "" and $cols >= 60
         then "\($dim)\($t.effort)\($fg)" else empty end)
    ]
  | join(" ")
  | { id: $t.id, content: . }
' 2>/dev/null || exit 0
