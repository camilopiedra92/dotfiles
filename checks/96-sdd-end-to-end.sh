# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Routed Spec Kit: end to end ──────────────────────────────────────────────
printf '\n%sRouted Spec Kit: end to end%s\n' "$DIM" "$OFF"

# The real sdd-run driving the real Spec Kit engine through the real
# routing.yml, sdd-routed.yml and profiles — only the container runtime, the
# agents and the Keychain are stand-ins (checks/sdd/standins). Checks 94 and
# 95 each test one half against a fixture of the other; this is where the two
# halves meet: step ids, the run id, the gates' inputs, the stuck stops, the
# messages the owner reads (quickstart 1, 2, 5).
e2e() {
  local tmp status=0 out rid dot=$PWD
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  local d=$tmp/dotfiles sa=$tmp/standins repo=$tmp/repo f=specs/001-probe
  mkdir -p "$d/bin" "$d/claude/speckit" "$d/containers" "$tmp/dbin" "$tmp/home"
  cp "$dot"/bin/sdd-run.sh "$dot"/bin/sdd-run.py "$dot"/bin/sdd-step.sh "$dot"/bin/sdd-pass.py "$dot"/bin/sdd-egress-proxy.py "$d/bin/"
  cp "$dot/claude/config-guard.sh" "$d/claude/"
  cp -R "$dot/claude/speckit/schemas" "$dot/claude/speckit/profiles" "$d/claude/speckit/"
  cp "$dot/claude/speckit/routing.yml" "$dot/claude/speckit/sdd-routed.yml" "$d/claude/speckit/"
  cp "$dot/claude/speckit/brief.md" "$dot/claude/speckit/pi-models.json" "$dot/claude/speckit/egress-registries.txt" "$d/claude/speckit/"
  cp -R "$dot/containers/worker" "$d/containers/"
  cp -R "$dot/checks/sdd/standins" "$sa"
  # The real engine, not check 95's stand-in for it.
  rm -f "$sa/specify"
  ln -s agent "$sa/claude" && ln -s agent "$sa/pi"
  mkdir -p "$sa/secrets"
  printf 'sk-ant-oat01-FAKEclaude' > "$sa/secrets/claude-oauth"
  printf 'sk-FAKEdeepseek' > "$sa/secrets/deepseek-api"
  cp "$dot/containers/worker/inventory.txt" "$sa/inventory.out"
  ln -s "$d/bin/sdd-run.sh" "$tmp/dbin/sdd-run"
  ln -s "$d/bin/sdd-step.sh" "$tmp/dbin/sdd-step"
  ln -s "$(command -v check-jsonschema)" "$tmp/dbin/check-jsonschema"
  ln -s "$(command -v specify)" "$tmp/dbin/specify"
  mkdir -p "$repo/.specify/workflows/sdd-routed" "$repo/src"
  cp "$d/claude/speckit/sdd-routed.yml" "$repo/.specify/workflows/sdd-routed/workflow.yml"
  (
    cd "$repo" || exit 1
    git init -q -b main
    printf 'print(1)\n' > src/app.py
    # As `specify init` leaves it: feature.json is each worktree's own state.
    printf 'feature.json\n' > .specify/.gitignore
    # A check that never passes: three rounds, then the stop.
    printf '#!/bin/sh\necho "FAIL the probe"\nexit 1\n' > check-app.sh
    chmod +x check-app.sh
    git add -A && git -c user.name=t -c user.email=t@t commit -qm base
    git config sdd.check ./check-app.sh
    git config user.name owner && git config user.email owner@example.com
  ) || return 1

  fx() { mkdir -p "$sa/fixture/by/$1" && printf '%s' "$sa/fixture/by/$1"; }
  answer() { # key text [structured]
    printf '{"type":"result","is_error":false,"result":"%s","structured_output":%s,"permission_denials":[],"total_cost_usd":0.01,"modelUsage":{}}\n' \
      "$2" "${3:-null}" > "$(fx "$1")/result.json"
  }
  writes() { # key path content
    mkdir -p "$(fx "$1")/edits/$(dirname "$2")"
    printf '%s' "$3" > "$(fx "$1")/edits/$2"
  }
  answer speckit-specify "specified"
  writes speckit-specify "$f/spec.md" "# Spec"
  writes speckit-specify "$f/checklists/requirements.md" "- [x] ok"
  writes speckit-specify .specify/feature.json "{\"feature_directory\":\"$f\"}"
  answer speckit-clarify "asked" '{"questions":0}'
  answer speckit-plan "planned"
  writes speckit-plan "$f/plan.md" "# Plan"
  answer speckit-checklist "checked"
  writes speckit-checklist "$f/checklists/quality.md" "- [x] ok"
  answer speckit-analyze "the analysis"
  answer speckit-tasks "tasked"
  writes speckit-tasks "$f/tasks.md" "- [ ] T001 do it"
  answer speckit-implement "implemented"
  writes speckit-implement src/app.py "print(2)"

  sr() { (cd "$repo" && HOME="$tmp/home" PATH="$sa:$tmp/dbin:/usr/bin:/bin:/usr/sbin:/sbin" sdd-run "$@" 2>&1); }

  # 1. Start: the run pauses at the spec's checkpoint and says how to answer it.
  out=$(sr start "a probe feature") || fail "start: exited non-zero: $out"
  rid=$(printf '%s' "$out" | sed -n 's/.*sdd-run resume \([A-Za-z0-9_-]*\) .*/\1/p' | head -1)
  [ -n "$rid" ] || {
    echo "start: printed no resume command: $out"
    return 1
  }
  printf '%s' "$out" | grep -qF "paused at review_spec: sdd-run resume $rid approve|reject" ||
    fail "start: not paused at review_spec with its options: $out"
  # The worker image is prepared by sdd-run, its inventory checked, before
  # the proxy and before any agent pass (contracts/workflow.md).
  /usr/bin/python3 -I -c '
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
ready = next((i for i, c in enumerate(calls) if c[:2] == ["container", "run"] and "/usr/local/lib/sdd/inventory.sh" in c), None)
proxy = next((i for i, c in enumerate(calls) if c[:2] == ["container", "run"] and any("sdd-egress-proxy.py" in a for a in c)), None)
agent = next((i for i, c in enumerate(calls) if c[:2] == ["container", "run"] and "claude" in c), None)
sys.exit(0 if ready is not None and proxy is not None and agent is not None and ready < proxy < agent
         else "start: the image was not checked before the proxy, or the proxy not up before the first pass: %s %s %s" % (ready, proxy, agent))
' "$sa/calls.jsonl" || status=1
  # 2. Each checkpoint answered.
  out=$(sr resume "$rid" approve) || fail "resume spec: $out"
  printf '%s' "$out" | grep -qF "paused at review_plan" || fail "resume spec: not paused at review_plan: $out"
  # 3. Implementation never passes its check: three rounds, then the stop,
  # named, with the two commands that answer it and the step's own message.
  out=$(sr resume "$rid" approve) && fail "resume plan: exited 0 at a stop: $out"
  printf '%s' "$out" | grep -qF "stopped at" || fail "fix stuck: not reported as a stop: $out"
  printf '%s' "$out" | grep -qF "sdd-run resume $rid retry" || fail "fix stuck: retry not named: $out"
  printf '%s' "$out" | grep -qF "sdd-run abort $rid" || fail "fix stuck: abort not named: $out"
  printf '%s' "$out" | grep -qF "after 3 passes" || fail "fix stuck: the step's own message is not shown: $out"
  local implements
  implements=$(grep -c '"/speckit-implement' "$sa/agents.jsonl" 2> /dev/null || echo 0)
  [ "$implements" -eq 3 ] || fail "fix stuck: $implements implement passes before the stop, wanted 3"
  # 4. retry buys exactly one more round, then the run stops again.
  out=$(sr resume "$rid" retry) && fail "retry: exited 0 although the round failed again: $out"
  implements=$(grep -c '"/speckit-implement' "$sa/agents.jsonl" 2> /dev/null || echo 0)
  [ "$implements" -eq 4 ] || fail "retry: $implements implement passes, wanted exactly one more (4)"
  printf '%s' "$out" | grep -qF "sdd-run resume $rid retry" || fail "retry: the second stop does not name retry: $out"
  # 5. abort finishes the run.
  out=$(sr abort "$rid") || fail "abort: $out"
  [ -f "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)/sdd/$rid/finished.json" ] ||
    fail "abort: no finished.json"
  return "$status"
}
if command -v specify > /dev/null 2>&1 && command -v check-jsonschema > /dev/null 2>&1; then
  check "sdd-run drives the real workflow from start through its checkpoints, a stuck fix, one retry and an abort" e2e
else
  skip "sdd-run drives the real workflow from start through its checkpoints, a stuck fix, one retry and an abort" "specify or check-jsonschema"
fi
