# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: claude/*statusline*

# ── Statusline behaviour ─────────────────────────────────────────────────────
# These are pure functions from a JSON payload to a line of text, which makes
# them the one thing here that can be tested properly.
printf '\n%sStatusline%s\n' "$DIM" "$OFF"

check "demo renders" bash -c './claude/statusline-demo.sh > /dev/null'

# A freshly opened session has no context and no limits yet. Printing a broken
# line there is worse than printing a short one.
minimal_payload() {
  local out
  out=$(echo '{"model":{"display_name":"Opus 5"},"cwd":"/tmp"}' | ./claude/statusline.sh)
  case "$out" in
    *"Opus 5"*) return 0 ;;
    *)
      echo "model missing from a minimal payload: $out"
      return 1
      ;;
  esac
}
check "minimal payload still renders the model" minimal_payload

# Garbage in must mean nothing out, never a half-rendered line: Claude prints
# whatever we emit, junk included.
invalid_json_is_silent() {
  local out
  out=$(echo 'not json' | ./claude/statusline.sh)
  [ -z "$out" ] || {
    echo "emitted output for invalid JSON: $out"
    return 1
  }
}
check "invalid json produces no output" invalid_json_is_silent

subagent_rows() {
  local payload out
  payload='{"columns":80,"tasks":[
    {"id":"a","name":"brisk-otter","type":"local_agent","status":"running",
     "startTime":1,"model":"claude-opus-5","contextWindowSize":200000,
     "tokenCount":48000,"tokenSamples":[1,2,3]},
    {"id":"b","type":"local_bash","status":"running","startTime":1,"tokenCount":0}]}'
  out=$(echo "$payload" | ./claude/subagent-statusline.sh)

  [ "$(echo "$out" | wc -l | tr -d ' ')" = 2 ] || {
    echo "expected 2 rows, got: $out"
    return 1
  }
  echo "$out" | jq -e . > /dev/null || {
    echo "not valid JSONL: $out"
    return 1
  }
  echo "$out" | jq -e 'has("id") and has("content")' > /dev/null || return 1

  # The name is the only part of the row you can address an agent by, so its
  # absence is a regression worth failing on.
  echo "$out" | head -1 | jq -e '.content | contains("brisk-otter")' > /dev/null ||
    {
      echo "agent name missing from the row"
      return 1
    }

  # A task without a name must still render, not vanish.
  echo "$out" | tail -1 | jq -e '.content | length > 0' > /dev/null ||
    {
      echo "unnamed task rendered empty"
      return 1
    }
}
check "subagent rows are valid jsonl with the agent name" subagent_rows
