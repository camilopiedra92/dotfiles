# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: bin/sdd-run.sh bin/sdd-run.py bin/sdd-step.sh bin/sdd-pass.py bin/sdd-egress-proxy.py
# covers: claude/speckit/* claude/config-guard.sh containers/worker/* checks/sdd/standins/*

# ── Routed Spec Kit: end to end ──────────────────────────────────────────────
printf '\n%sRouted Spec Kit: end to end%s\n' "$DIM" "$OFF"

# The real sdd-run driving the real Spec Kit engine through the real
# routing.yml, sdd-routed.yml and profiles — only the container runtime, the
# agents and the Keychain are stand-ins (checks/sdd/standins). Checks 94 and
# 95 each test one half against a fixture of the other; this is where the two
# halves meet: step ids, the run id, the gates' inputs, the stuck stops, the
# messages the owner reads (quickstart 1, 2, 5).
# A scratch dotfiles copy, stand-ins, a repository and default agent fixtures,
# in $tmp (the caller's); $1 is the check command's script. Sets d, sa, repo, f.
e2e_fresh() {
  local check=$1 dot=$PWD
  d=$tmp/dotfiles sa=$tmp/standins repo=$tmp/repo f=specs/001-probe
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
    printf '%s' "$check" > check-app.sh
    chmod +x check-app.sh
    git add -A && git -c user.name=t -c user.email=t@t commit -qm base
    git config sdd.check ./check-app.sh
    git config user.name owner && git config user.email owner@example.com
  ) || return 1
}
fx() { mkdir -p "$sa/fixture/by/$1" && printf '%s' "$sa/fixture/by/$1"; }
answer() { # key text [structured]
  printf '{"type":"result","is_error":false,"result":"%s","structured_output":%s,"permission_denials":[],"total_cost_usd":0.01,"modelUsage":{}}\n' \
    "$2" "${3:-null}" > "$(fx "$1")/result.json"
}
writes() { # key path content
  mkdir -p "$(fx "$1")/edits/$(dirname "$2")"
  printf '%s' "$3" > "$(fx "$1")/edits/$2"
}
# The default fixtures: every phase answers; an implementer that tries
# something different each round (one that changed nothing would fail).
e2e_fixtures() {
  answer speckit-specify "specified"
  writes speckit-specify "$f/spec.md" "# Spec"
  writes speckit-specify "$f/checklists/requirements.md" "- [x] ok"
  writes speckit-specify .specify/feature.json "{\"feature_directory\":\"$f\"}"
  answer speckit-clarify "asked" '{"questions":0}'
  answer speckit-plan "planned"
  writes speckit-plan "$f/plan.md" "# Plan"
  answer speckit-checklist "checked"
  writes speckit-checklist "$f/checklists/quality.md" "- [x] ok"
  answer checklist-review "reviewed"
  answer speckit-analyze "the analysis"
  answer speckit-tasks "tasked"
  writes speckit-tasks "$f/tasks.md" "- [ ] T001 do it"
  # An implementer that tries something different each round and never
  # satisfies the check (one that changed nothing would fail at once).
  local round
  for round in 1 2 3 4 5 6 7; do
    answer "speckit-implement.$round" "implemented"
    writes "speckit-implement.$round" src/app.py "print($round + 1)"
  done
}
# The run id the last sdd-run output names.
e2e_rid() { printf '%s' "$1" | sed -n 's/.*sdd-run: run \([0-9a-f]\{12\}\).*/\1/p' | head -1; }
# sdd-run as the owner runs it, from $E2E_IN (another worktree) or the repository.
sr() { (cd "${E2E_IN:-$repo}" && HOME="$tmp/home" PATH="$sa:$tmp/dbin:/usr/bin:/bin:/usr/sbin:/sbin" sdd-run "$@" 2>&1); }

e2e() {
  local tmp status=0 out rid d sa repo f
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  # A check that never passes: three rounds, then the stop.
  e2e_fresh '#!/bin/sh
echo "FAIL the probe"
exit 1
' || return 1
  e2e_fixtures
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

# The US1 review's findings (2026-10-21), each against the real engine.
e2e_review() {
  local tmp status=0 out rid d sa repo f common
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fail() {
    echo "$1"
    status=1
  }

  # HIGH 1. A fix loop stuck in the convergence loop's second round is a
  # stop retry answers: the engine names it convergence:fix_loop:<j>:fix_stuck:<i>.
  e2e_fresh "#!/bin/sh
n=\$(cat $tmp/vcount 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > $tmp/vcount
[ \$n -eq 1 ] && exit 0
echo FAIL; exit 1
" || return 1
  e2e_fixtures
  answer review "reviewed" '{"findings":[{"severity":"HIGH","text":"bad"}],"done":[]}'
  answer speckit-converge "open" '{"outcome":"tasks_appended","findings":[{"severity":"HIGH","text":"bad"}]}'
  writes speckit-converge "$f/tasks.md" "- [ ] T001 do it
- [ ] T002 more"
  out=$(sr start "a probe feature")
  rid=$(e2e_rid "$out")
  sr resume "$rid" approve > /dev/null
  out=$(sr resume "$rid" approve)
  printf '%s' "$out" | grep -qF "stopped at convergence:fix_loop:1:fix_stuck:" ||
    fail "nested stop: not reported as a stop at the nested fix_stuck: $(printf '%s' "$out" | tail -2)"
  out=$(sr resume "$rid" retry)
  grep -qF "not stopped at" <<< "$out" && fail "nested retry: refused: $(printf '%s' "$out" | tail -1)"
  printf '%s' "$out" | grep -qF "sdd-run resume $rid retry" || fail "nested retry: the next stop does not name retry: $(printf '%s' "$out" | tail -1)"
  rm -rf "${tmp:?}"/*

  # MEDIUM 3. A run the owner rejects at a checkpoint is finished, its
  # registry link gone, and sdd-run says so.
  e2e_fresh '#!/bin/sh
exit 0
' || return 1
  e2e_fixtures
  out=$(sr start "a probe feature")
  rid=$(e2e_rid "$out")
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
  out=$(sr resume "$rid" reject)
  printf '%s' "$out" | grep -qF "sdd-run: run $rid ended at review_spec: rejected" || fail "reject: no line of sdd-run's own: $out"
  [ -f "$common/sdd/$rid/finished.json" ] || fail "reject: no finished.json"
  [ ! -L "$tmp/home/.local/state/sdd/runs/$rid" ] || fail "reject: the registry link remains"
  rm -rf "${tmp:?}"/*

  # MEDIUM 4. resume from another worktree of the repository refuses, naming
  # the run's own, and leaves the run's lock as it was.
  e2e_fresh '#!/bin/sh
exit 0
' || return 1
  e2e_fixtures
  out=$(sr start "a probe feature")
  rid=$(e2e_rid "$out")
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
  git -C "$repo" worktree add -q "$tmp/wt" -b other 2> /dev/null
  cp "$common/sdd/$rid/lock.json" "$tmp/lock.before"
  out=$(E2E_IN=$tmp/wt sr resume "$rid" approve) && fail "other worktree: resume succeeded"
  printf '%s' "$out" | grep -qF "$repo" || fail "other worktree: the run's worktree is not named: $out"
  cmp -s "$tmp/lock.before" "$common/sdd/$rid/lock.json" || fail "other worktree: the lock was rewritten"
  out=$(sr resume "$rid" approve)
  printf '%s' "$out" | grep -qF "paused at review_plan" || fail "other worktree: the run is no longer resumable from its own: $out"
  rm -rf "${tmp:?}"/*

  # MEDIUM 5. Everything that governs or runs a run is frozen in its bundle:
  # breaking dotfiles' live copies — the pass, the step, the proxy, the
  # schemas, the workflow's version — changes nothing in a paused run.
  e2e_fresh '#!/bin/sh
exit 0
' || return 1
  e2e_fixtures
  out=$(sr start "a probe feature")
  rid=$(e2e_rid "$out")
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
  /usr/bin/python3 -I -c 'import json,sys; t=json.load(open(sys.argv[1]))["sdd-step"]; sys.exit(0 if t.startswith(sys.argv[2]) else "tools.json runs sdd-step from %s, not the bundle" % t)' \
    "$common/sdd/$rid/tools.json" "$common/sdd/$rid/" || status=1
  printf 'raise SystemExit("the live sdd-pass.py ran")\n' > "$d/bin/sdd-pass.py"
  printf 'raise SystemExit("the live proxy ran")\n' > "$d/bin/sdd-egress-proxy.py"
  for s in "$d"/claude/speckit/schemas/*.json; do printf '{"not": {}}\n' > "$s"; done
  sed -i.bak 's/^  version: .*/  version: "9.9.9"/' "$d/claude/speckit/sdd-routed.yml"
  out=$(sr resume "$rid" approve)
  printf '%s' "$out" | grep -qF "paused at review_plan" || fail "frozen: the paused run used dotfiles' live copies: $(printf '%s' "$out" | tail -2)"
  rm -rf "${tmp:?}"/*

  # HIGH 2. start --from works on the feature it names, whatever
  # .specify/feature.json says; and no second run starts in a worktree whose
  # run is not finished.
  e2e_fresh '#!/bin/sh
exit 0
' || return 1
  e2e_fixtures
  answer review "reviewed" '{"findings":[],"done":["T001"]}'
  answer speckit-converge "converged" '{"outcome":"converged","findings":[]}'
  (
    cd "$repo" || exit 1
    mkdir -p "$f/.sdd" specs/002-other
    printf '# Spec\n' > "$f/spec.md"
    printf -- '- [ ] T001 do it\n' > "$f/tasks.md"
    printf '{"schema":"urn:dotfiles:sdd:phases:1","step":"phases","at":"2026-10-21T14:00:00Z","done":[{"phase":"specify","at":"2026-10-21T14:00:00Z"},{"phase":"plan","at":"2026-10-21T14:00:00Z"},{"phase":"tasks","at":"2026-10-21T14:00:00Z"}]}\n' > "$f/.sdd/phases.json"
    printf '# Other\n' > specs/002-other/spec.md
    git add -A && git -c core.hooksPath=/dev/null commit -qm "two features"
    printf '{"feature_directory": "specs/002-other"}' > .specify/feature.json
  )
  out=$(sr start --from "$f")
  rid=$(e2e_rid "$out")
  printf '%s' "$out" | grep -qF "paused at review_done" || fail "from: the run did not reach review_done: $(printf '%s' "$out" | tail -2)"
  # The history captured first: under check.sh's pipefail, `git log | grep -q`
  # fails when grep stops early and git log dies of SIGPIPE.
  local history
  history=$(git -C "$repo" log --format=%s)
  grep -q "002-other" <<< "$history" && fail "from: a phase committed to specs/002-other: $(grep 002-other <<< "$history" | head -2)"
  grep -q "^implement: 001-probe" <<< "$history" || fail "from: no implement commit for $f; the history: $(head -8 <<< "$history" | tr '\n' '|')"
  out=$(sr start "another feature") && fail "second run: started while run $rid is not finished"
  printf '%s' "$out" | grep -qF "$rid" || fail "second run: the unfinished run is not named: $out"
  return "$status"
}
if command -v specify > /dev/null 2>&1 && command -v check-jsonschema > /dev/null 2>&1; then
  check "sdd-run: nested stuck stops, rejected runs finished, its own worktree, frozen code, --from on its feature" e2e_review
else
  skip "sdd-run: nested stuck stops, rejected runs finished, its own worktree, frozen code, --from on its feature" "specify or check-jsonschema"
fi

# The US1 review's second round (2026-10-22), against the real engine and
# the real specify pass: a worktree whose pointer an earlier run left naming
# its feature. specify fails before it writes the pointer; the run is pinned
# to nothing and writes nothing into that feature. Resumed, specify makes the
# run's own feature, which the pass records in the bundle, and the run goes
# on through its checkpoint.
e2e_leftover_pointer() {
  local tmp status=0 out rid d sa repo f common old=specs/009-old
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  e2e_fresh '#!/bin/sh
exit 0
' || return 1
  e2e_fixtures
  # The first specify pass fails: the agent exits 1.
  answer speckit-specify.1 "no"
  printf '1' > "$(fx speckit-specify.1)/exit"
  (
    cd "$repo" || exit 1
    mkdir -p "$old"
    printf '# Old\n' > "$old/spec.md"
    git add -A && git -c core.hooksPath=/dev/null commit -qm "an earlier feature"
    printf '{"feature_directory": "%s"}' "$old" > .specify/feature.json
  )
  common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
  out=$(sr start "a probe feature")
  rid=$(e2e_rid "$out")
  printf '%s' "$out" | grep -qF "failed at specify" || fail "leftover: specify did not fail: $(printf '%s' "$out" | tail -2)"
  [ ! -e "$common/sdd/$rid/feature.json" ] ||
    fail "leftover: pinned before specify wrote the pointer: $(tr -d '\n ' < "$common/sdd/$rid/feature.json")"
  [ ! -e "$repo/$old/.sdd" ] || fail "leftover: the run wrote into $old: $(ls "$repo/$old/.sdd")"
  out=$(sr resume "$rid")
  printf '%s' "$out" | grep -qF "paused at review_spec" || fail "leftover: the resumed specify did not reach review_spec: $(printf '%s' "$out" | tail -2)"
  /usr/bin/python3 -I -c 'import json,os,sys; d=json.load(open(sys.argv[1])) if os.path.exists(sys.argv[1]) else None; sys.exit(0 if d == {"feature_directory": sys.argv[2]} else "leftover: the bundle pins %r, not the feature specify made" % d)' \
    "$common/sdd/$rid/feature.json" "$f" 2>&1 || status=1
  [ -s "$repo/$f/.sdd/routing.json" ] || fail "leftover: no routing.json in $f"
  out=$(sr resume "$rid" approve)
  printf '%s' "$out" | grep -qF "paused at review_plan" || fail "leftover: approve did not reach review_plan: $(printf '%s' "$out" | tail -2)"
  [ ! -e "$repo/$old/.sdd" ] || fail "leftover: the run wrote into $old at last: $(ls "$repo/$old/.sdd")"
  return "$status"
}
if command -v specify > /dev/null 2>&1 && command -v check-jsonschema > /dev/null 2>&1; then
  check "sdd-run: a pointer an earlier run left is never taken for the run's feature" e2e_leftover_pointer
else
  skip "sdd-run: a pointer an earlier run left is never taken for the run's feature" "specify or check-jsonschema"
fi
