#!/usr/bin/env bash
# Per-subagent statusline — decorates each row of the agent panel.
#
# This is a different mechanism from the main statusline and far less
# documented, so here is the contract, verified by reading Claude Code 2.1.226:
#
#   INPUT (stdin, a single JSON object):
#     { "columns": <usable width, frame already subtracted>,
#       "tasks": [ { "id", "name", "type", "status", "description", "label",
#                    "startTime",          // epoch, in milliseconds
#                    "model", "effort",
#                    "contextWindowSize",  // may be missing
#                    "tokenCount",
#                    "tokenSamples": [ ... ]   // history, up to 16 samples
#                    "cwd" } ] }
#
#   OUTPUT: JSONL — one {"id": "...", "content": "..."} line per agent.
#     Lines that fail to parse are dropped with an error in the log, so always
#     exit 0 and print nothing when something goes wrong.
#
#   CADENCE: first tick after 300ms, then every 5s, with a 5s timeout.
#
# The interesting field is `tokenSamples`: Claude keeps each agent's usage
# history, so we can draw a sparkline and tell at a glance which one is really
# working and which has been stuck for a while. A bare number cannot tell
# "20k tokens and climbing" from "20k tokens, frozen a minute ago".
#
# Everything happens in a single jq: the input is an array and the work is
# arithmetic over lists, which jq expresses more briefly and runs faster than
# looping in bash with one process per row.
set -uo pipefail

jq -c -r '
  # ── Formatting ─────────────────────────────────────────────────────────────
  def num:
    if . >= 1000000 then "\((. / 100000 | floor) / 10)M"
    elif . >= 1000  then "\(. / 1000 | floor)k"
    else "\(. | floor)" end;

  def dur:
    if   . >= 3600 then "\(. / 3600 | floor)h\((. % 3600) / 60 | floor)m"
    elif . >= 60   then "\(. / 60 | floor)m\(. % 60 | floor)s"
    else "\(. | floor)s" end;

  # Sparkline normalized to its own min and max. What matters is the SHAPE of
  # the curve, not the scale: the absolute figure sits right next to it.
  #
  # A flat series is not discarded, it is drawn flat. An agent that has not
  # moved a token in fifteen minutes is exactly what this panel must expose,
  # and leaving the slot blank would make it indistinguishable from "no data".
  def spark:
    (map(select(type == "number"))) as $v
    | if ($v | length) < 2 then "" else
        ($v | min) as $lo | ($v | max) as $hi
        | if $hi <= $lo then ($v | map("▁") | join(""))
          else $v | map(((. - $lo) * 7 / ($hi - $lo)) | round)
                  | map(["▁","▂","▃","▄","▅","▆","▇","█"][.]) | join("")
          end
      end;

  # ── Palette ────────────────────────────────────────────────────────────────
  # Same rule as the main statusline: never \u001b[0m, only \u001b[39m, so we
  # do not cancel the style Claude applies from the outside.
  "\u001b[90m" as $dim  | "\u001b[39m" as $fg
  | "\u001b[32m" as $green | "\u001b[33m" as $yellow | "\u001b[31m" as $red
  | "\u001b[36m" as $cyan

  | (.columns // 80) as $cols
  | (now * 1000) as $now_ms

  | .tasks[]
  | . as $t
  # startTime arrives in milliseconds; seconds are accepted too in case that
  # changes, since mixing up the units yields absurd durations and no error.
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
  # `name` is the name Claude assigns to an agent on creation (the same one
  # ListAgents shows). It comes from a separate registry, so it is missing for
  # anything that is not a named agent: bash tasks, workflows.
  | (($t.name // "") | if length > 16 then .[0:15] + "…" else . end) as $name

  # ── Composition, most to least important ───────────────────────────────────
  # The panel says WHAT each agent is doing but not WHICH one it is, and with
  # three or four running at once the description is not enough to know who you
  # are addressing when you message one. Hence the name goes first and is never
  # dropped on narrow terminals: it is the only part of this line you can
  # address an agent by.
  | [ (if $name != "" then "\($cyan)\($name)\($fg)" else empty end),
      "\($dim)\($secs | dur)\($fg)",
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
