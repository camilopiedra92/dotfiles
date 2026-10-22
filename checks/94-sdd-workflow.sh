# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: bin/sdd-step.sh bin/sdd-pass.py claude/speckit/* containers/worker/*
# covers: checks/sdd/bundle.py checks/sdd/standins/*

# ── Routed Spec Kit: the workflow ────────────────────────────────────────────
printf '\n%sRouted Spec Kit: the workflow%s\n' "$DIM" "$OFF"

# The routing defaults are a valid table, and the workflow agrees with them:
# every agent step's timeout is its row's max_timeout plus 300, so the
# dispatcher's own limit always fires first (research R11), and the workflow
# names no model, effort or permission (contracts/workflow.md).
WF_SPEC_PY="$(uv tool dir 2> /dev/null)/specify-cli/bin/python"
wf_static() {
  check-jsonschema --schemafile claude/speckit/schemas/routing-table.schema.json claude/speckit/routing.yml > /dev/null 2>&1 || {
    echo "claude/speckit/routing.yml does not match routing-table.schema.json:"
    check-jsonschema --schemafile claude/speckit/schemas/routing-table.schema.json claude/speckit/routing.yml 2>&1 | tail -5
    return 1
  }
  "$WF_SPEC_PY" -I - claude/speckit/routing.yml claude/speckit/sdd-routed.yml bin/sdd-pass.py << 'PY'
import re, sys, yaml
rows = yaml.safe_load(open(sys.argv[1]))["phases"]
text = open(sys.argv[2]).read()
wf = yaml.safe_load(text)
bad = []
def walk(steps):
    for s in steps:
        yield s
        for key in ("then", "else", "steps"):
            yield from walk(s.get(key) or [])
seen = set()
for s in walk(wf["steps"]):
    run = s.get("run", "")
    m = re.search(r'"\$SDD_STEP" (agent ([a-z-]+)|implement)\b', run)
    if not m:
        continue
    phases = [m.group(2)] if m.group(2) else ["implement-sonnet", "implement-deepseek"]
    for phase in phases:
        seen.add(phase)
        want = rows[phase]["max_timeout"] + 300
        if s.get("timeout") != want:
            bad.append("step %s: timeout %s, its row %s wants %s" % (s["id"], s.get("timeout"), phase, want))
import ast
tree = ast.parse(open(sys.argv[3]).read())
verify_limit = next(n.value.value for n in tree.body if isinstance(n, ast.Assign)
                    and getattr(n.targets[0], "id", "") == "VERIFY_TIMEOUT")
for s in walk(wf["steps"]):
    if re.search(r'"\$SDD_STEP" verify\b', s.get("run", "")) and s.get("timeout") != verify_limit + 300:
        bad.append("step %s: timeout %s, verify's limit %s wants %s" % (s["id"], s.get("timeout"), verify_limit, verify_limit + 300))
missing = set(rows) - seen
if missing:
    bad.append("no step runs the rows %s" % sorted(missing))
# Each implementer runs Spec Kit's own implement command, in its agent's
# spelling: Claude's skill, pi's prompt from Spec Kit's pi integration.
for phase, want in (("implement-sonnet", "/speckit-implement"), ("implement-deepseek", "/speckit.implement")):
    if rows[phase]["prompt"].split()[0] != want:
        bad.append("%s runs %r, not Spec Kit's %s" % (phase, rows[phase]["prompt"], want))
for word in ("claude-", "deepseek-", "--model", "--effort", "dontAsk", "allow"):
    if word in text:
        bad.append("the workflow names %r; models, effort and permissions belong to the routing table" % word)
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
}
if command -v check-jsonschema > /dev/null 2>&1 && [ -x "$WF_SPEC_PY" ]; then
  check "routing.yml is a valid table, and every workflow step's timeout is its row's max_timeout plus 300" wf_static
else
  skip "routing.yml is a valid table, and every workflow step's timeout is its row's max_timeout plus 300" "check-jsonschema or specify-cli"
fi

# The workflow, run by the real Spec Kit engine (FR-025) against the
# stand-ins of checks/sdd/standins: the container runtime runs each pass in
# the export, the agents answer from per-prompt fixtures, the Keychain is
# fake. sdd-run is not used here (its own checks drive it); the engine is
# started as sdd-run starts it, with SDD_RUN_DIR, SDD_STEP and
# SPECKIT_WORKFLOW_RUN_ID exported.
WF_TMP=''
wf_fresh() {
  [ -n "$WF_TMP" ] || WF_TMP=$(mktemp -d) || return 1
  rm -rf "$WF_TMP/case" && mkdir -p "$WF_TMP/case" || return 1
  local c=$WF_TMP/case dot=$PWD
  WF_C=$c WF_REPO=$c/repo WF_SA=$c/standins WF_F=specs/001-probe
  cp -R "$dot/checks/sdd/standins" "$WF_SA"
  ln -s agent "$WF_SA/claude" && ln -s agent "$WF_SA/pi"
  mkdir -p "$WF_SA/secrets" "$c/home" "$WF_REPO/src"
  printf '%s' sk-ant-oat01-FAKEclaudeTOKEN0123456789 > "$WF_SA/secrets/claude-oauth"
  printf '%s' sk-FAKEdeepseekKEY0123456789 > "$WF_SA/secrets/deepseek-api"
  (
    cd "$WF_REPO" || exit 1
    git init -q -b main
    printf 'print(1)\n' > src/app.py
    # As `specify init` leaves it: feature.json is each worktree's own state.
    mkdir -p .specify && printf 'feature.json\n' > .specify/.gitignore
    printf '#!/bin/sh\necho checking\nexit 0\n' > check-app.sh
    chmod +x check-app.sh
    git add -A && git -c user.name=t -c user.email=t@t commit -qm base
    git config user.name owner && git config user.email owner@example.com
  ) || return 1
  "$WF_SPEC_PY" -I -c 'import json, sys, yaml; json.dump(yaml.safe_load(open(sys.argv[1])), open(sys.argv[2], "w"))' \
    "$dot/claude/speckit/routing.yml" "$c/rows.json" || return 1
  WF_RUN=$(python3 -I "$dot/checks/sdd/bundle.py" "$c" "$dot" "$c/rows.json") || return 1
  printf '{"run_id":"run1","pid":%s,"started":"x","base":"%s"}\n' "$$" \
    "$(git -C "$WF_REPO" rev-parse HEAD)" > "$WF_RUN/lock.json"
  printf '{"implement":"sonnet"}\n' > "$WF_RUN/optin.json"
  # sdd-run prepares the image before the workflow starts, since the egress
  # proxy runs on it; the bundle records its tag (bundle.py writes one).
  cp "$dot/containers/worker/inventory.txt" "$WF_SA/inventory.out"
  # Every agent succeeds by default, each with what its phase writes.
  wf_result speckit-specify "specified"
  wf_edit speckit-specify "$WF_F/spec.md" "# Spec"
  wf_edit speckit-specify "$WF_F/checklists/requirements.md" "- [x] ok"
  wf_edit speckit-specify .specify/feature.json "{\"feature_directory\":\"$WF_F\"}"
  wf_result speckit-clarify.1 "asked" '{"questions":0}'
  wf_result speckit-plan "planned"
  wf_edit speckit-plan "$WF_F/plan.md" "# Plan"
  wf_result speckit-checklist "checked"
  wf_edit speckit-checklist "$WF_F/checklists/quality.md" "- [ ] ok"
  wf_result checklist-review "reviewed"
  wf_edit checklist-review "$WF_F/checklists/quality.md" "- [x] ok (verified in spec.md)"
  wf_result speckit-analyze "the analysis"
  wf_result speckit-tasks "tasked"
  wf_edit speckit-tasks "$WF_F/tasks.md" "- [ ] T001 do it
- [ ] T002 do more"
  wf_result speckit-implement "implemented"
  wf_edit speckit-implement src/app.py "print(2)"
  wf_result review "reviewed" '{"findings":[{"severity":"LOW","text":"a nit"}],"done":["T001"]}'
  wf_result speckit-converge "converged" '{"outcome":"converged","findings":[]}'
}
wf_fx() { mkdir -p "$WF_SA/fixture/by/$1" && printf '%s' "$WF_SA/fixture/by/$1"; }
wf_result() { # key text [structured]
  printf '{"type":"result","is_error":false,"result":"%s","structured_output":%s,"permission_denials":[],"total_cost_usd":0.01,"modelUsage":{}}\n' \
    "$2" "${3:-null}" > "$(wf_fx "$1")/result.json"
}
wf_edit() { # key path content
  local d
  d=$(wf_fx "$1")/edits
  mkdir -p "$d/$(dirname "$2")"
  printf '%s\n' "$3" > "$d/$2"
}
wf_start() { (cd "$WF_REPO" && HOME=$WF_C/home SDD_RUN_DIR=$WF_RUN SDD_STEP=$WF_DOT/bin/sdd-step.sh \
  SPECKIT_WORKFLOW_RUN_ID=run1 specify workflow run "$WF_DOT/claude/speckit/sdd-routed.yml" -i "spec=a probe feature" "$@" 2>&1); }
wf_resume() { (cd "$WF_REPO" && HOME=$WF_C/home SDD_RUN_DIR=$WF_RUN SDD_STEP=$WF_DOT/bin/sdd-step.sh \
  SPECKIT_WORKFLOW_RUN_ID=run1 specify workflow resume run1 "$@" 2>&1); }
# Observed with Spec Kit 1.2.2 (2026-10-21): a completed run keeps its last
# step as current_step_id, and a step inside a loop is named
# <loop>:<step>:<iteration>, e.g. fix_loop:fix_stuck:2.
wf_state() { # prints "<status> <current step id>"
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["status"], d.get("current_step_id"))' \
    "$WF_REPO/.specify/workflows/runs/run1/state.json" 2> /dev/null || echo "none none"
}
wf_calls() { # prompt keys of the agent calls, in order
  python3 -I -c '
import json, re, sys
for line in open(sys.argv[1]):
    a = json.loads(line)
    argv = a["argv"]
    prompt = argv[argv.index("-p") + 1] if a["agent"] == "claude" else argv[-1]
    print(re.match(r"\W*([A-Za-z0-9-]+)", prompt).group(1).lower())
' "$WF_SA/agents.jsonl" 2> /dev/null
}
WF_DOT=$PWD

# A whole feature through every phase with every checkpoint answered up
# front (each gate occurs once): quickstart 1, FR-001, FR-002, FR-021,
# FR-026, FR-028.
wf_dispatch() {
  local out status=0
  wf_fresh || return 1
  out=$(wf_start -i spec_verdict=approve -i plan_verdict=approve -i done_verdict=approve)
  case "$(wf_state)" in "completed "*) ;; *)
    echo "the run did not complete: $(wf_state)"
    printf '%s\n' "$out" | tail -15
    return 1
    ;;
  esac
  python3 -I - "$WF_SA/agents.jsonl" "$WF_SA/calls.jsonl" << 'PY' || status=1
import json, re, sys
agents = [json.loads(l) for l in open(sys.argv[1])]
calls = [json.loads(l) for l in open(sys.argv[2])]
bad = []
def key(a):
    argv = a["argv"]
    p = argv[argv.index("-p") + 1] if a["agent"] == "claude" else argv[-1]
    return re.match(r"\W*([A-Za-z0-9-]+)", p).group(1).lower()
order = [key(a) for a in agents]
# Spec Kit's own order (analyze compares spec, plan and tasks, so it follows
# tasks), with the owner's fresh review of each checklist before tasks.
want = ["speckit-specify", "speckit-clarify", "speckit-plan", "speckit-checklist", "checklist-review",
        "speckit-tasks", "speckit-analyze", "speckit-implement", "review", "speckit-converge"]
if order != want:
    bad.append("agent calls %s, wanted %s (verify makes none)" % (order, want))
models = {"speckit-tasks": "claude-sonnet-5-5", "speckit-implement": "claude-sonnet-5-5"}
for a in agents:
    argv, k = a["argv"], key(a)
    def val(flag):
        return argv[argv.index(flag) + 1] if flag in argv else None
    if val("--model") != models.get(k, "claude-opus-5-5"):
        bad.append("%s ran on %s" % (k, val("--model")))
    if val("--effort") != "medium":
        bad.append("%s ran at effort %s" % (k, val("--effort")))
    for flag, v in (("--permission-mode", "dontAsk"), ("--permission-prompts", "none"),
                    ("--setting-sources", "project"), ("--settings", "/bundle/profile.json"),
                    ("--output-format", "json")):
        if val(flag) != v:
            bad.append("%s: %s is %s, not %s" % (k, flag, val(flag), v))
    if "--strict-mcp-config" not in argv or val("--mcp-config") != '{"mcpServers":{}}':
        bad.append("%s: MCP servers not shut out" % k)
    if ("--json-schema" in argv) != (k in ("speckit-clarify", "review", "speckit-converge")):
        bad.append("%s: --json-schema %s" % (k, "given" if "--json-schema" in argv else "missing"))
    if "--resume" in argv or "--continue" in argv:
        bad.append("%s resumed a session" % k)
# Inside the container the agents may use the shell (research R27): the
# container, its firewall, the proxy and the judge are the boundary. The
# phases that only read get no Edit or Write.
impl = next(a for a in agents if key(a) == "speckit-implement")
if not impl["profile"] or '"Bash"' not in impl["profile"]:
    bad.append("the implementer cannot use the shell: %s" % impl["profile"])
reader = next(a for a in agents if key(a) == "review")
if not reader["profile"] or '"Bash"' not in reader["profile"] or '"Edit"' in reader["profile"] or '"Write"' in reader["profile"]:
    bad.append("a reading phase is not the shell without Edit or Write: %s" % reader["profile"])
# Spec Kit's scripts find the feature through SPECIFY_FEATURE_DIRECTORY,
# since the export has no git branch to name it (contracts/pass.md).
if impl["env"].get("SPECIFY_FEATURE_DIRECTORY") != "/work/specs/001-probe":
    bad.append("the implementer was not told SPECIFY_FEATURE_DIRECTORY: %r" % impl["env"].get("SPECIFY_FEATURE_DIRECTORY"))
review = next(a for a in agents if key(a) == "review")
p = review["argv"][review["argv"].index("-p") + 1]
if "/input/diff.patch" not in p or "weakened test" not in p:
    bad.append("review's prompt does not read /input/diff.patch or make a weakened test blocking")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  python3 -I - "$WF_REPO/$WF_F" "$WF_RUN/usage.jsonl" << 'PY' || status=1
import json, os, sys
f, usage = sys.argv[1], sys.argv[2]
bad = []
for name in ("review.json", "converge.json", "implement.json", "verify.json", "route.json", "phases.json", "clarify.json"):
    if not os.path.exists(os.path.join(f, ".sdd", name)):
        bad.append("no .sdd/%s" % name)
done = [d["phase"] for d in json.load(open(os.path.join(f, ".sdd", "phases.json")))["done"]] if os.path.exists(os.path.join(f, ".sdd", "phases.json")) else []
if done != ["specify", "plan", "tasks", "build"]:
    bad.append("phases.json records %s" % done)
if not os.path.exists(os.path.join(f, "analysis.md")) or open(os.path.join(f, "analysis.md")).read() != "the analysis":
    bad.append("analysis.md is not analyze's text")
tasks = open(os.path.join(f, "tasks.md")).read()
if "- [X] T001" not in tasks or "- [ ] T002" not in tasks:
    bad.append("mark did not mark exactly what review listed: %r" % tasks)
lines = [json.loads(l) for l in open(usage)]
starts = [l for l in lines if l["event"] == "start"]
ends = [l for l in lines if l["event"] == "end"]
if len(starts) != 10 or len(ends) != 10 or any(l["run"] != "run1" for l in lines):
    bad.append("usage.jsonl: %d starts, %d ends, runs %s" % (len(starts), len(ends), sorted({l["run"] for l in lines})))
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  return "$status"
}

# specify may create exactly one feature directory, which
# .specify/feature.json names (contracts/routing.md); and a pass with no
# worker image fails rather than build inside its limit (FR-028).
wf_specify_judge() {
  local out case
  for case in two-directories feature-json-elsewhere; do
    wf_fresh || return 1
    case $case in
      two-directories) wf_edit speckit-specify specs/002-other/spec.md "# Other" ;;
      feature-json-elsewhere) wf_edit speckit-specify .specify/feature.json '{"feature_directory":"specs/009-elsewhere"}' ;;
    esac
    out=$(wf_start)
    [ "$(wf_state)" = "failed specify" ] || {
      echo "specify with $case was not refused: $(wf_state)"
      return 1
    }
    [ ! -d "$WF_REPO/specs" ] || {
      echo "specify with $case applied something: $(find "$WF_REPO/specs" | head -3)"
      return 1
    }
  done
  wf_fresh || return 1
  mkdir -p "$WF_REPO/.specify" "$WF_REPO/$WF_F"
  printf '{"feature_directory":"%s"}\n' "$WF_F" > "$WF_REPO/.specify/feature.json"
  rm -f "$WF_RUN/worker.json"
  if out=$(cd "$WF_REPO" && SDD_RUN_DIR=$WF_RUN "$WF_DOT/bin/sdd-step.sh" agent plan 2>&1); then
    echo "a pass ran with no worker image recorded"
    return 1
  fi
  printf '%s' "$out" | grep -q "prepare-worker" || {
    echo "the refusal does not point at prepare-worker: $out"
    return 1
  }
  ! grep -q '"build"' "$WF_SA/calls.jsonl" 2> /dev/null || {
    echo "the pass built the image inside its limit"
    return 1
  }
}

# Checkpoints (FR-004): with no TTY the run pauses at each gate, which names
# the command that answers it; approve goes on, reject aborts.
wf_gates() {
  local out gate
  wf_fresh || return 1
  out=$(wf_start)
  [ "$(wf_state)" = "paused review_spec" ] || {
    echo "the run did not pause at review_spec: $(wf_state)"
    printf '%s\n' "$out" | tail -8
    return 1
  }
  grep -q "sdd-run resume" "$WF_DOT/claude/speckit/sdd-routed.yml" || {
    echo "no gate names the sdd-run resume command"
    return 1
  }
  local verdict state next
  for gate in "spec_verdict paused review_plan" "plan_verdict paused review_done" "done_verdict completed build_done"; do
    read -r verdict state next <<< "$gate"
    out=$(wf_resume -i "$verdict=approve")
    case "$(wf_state)" in "$state $next") ;; *)
      echo "approving $verdict did not lead to $next: $(wf_state)"
      printf '%s\n' "$out" | tail -8
      return 1
      ;;
    esac
  done
  for gate in spec_verdict plan_verdict done_verdict; do
    wf_fresh || return 1
    out=$(wf_start)
    case $gate in
      plan_verdict) out=$(wf_resume -i spec_verdict=approve) ;;
      done_verdict) out=$(wf_resume -i spec_verdict=approve) && out=$(wf_resume -i plan_verdict=approve) ;;
    esac
    out=$(wf_resume -i "$gate=reject")
    case "$(wf_state)" in failed* | aborted*) ;; *)
      echo "rejecting $gate did not abort: $(wf_state)"
      return 1
      ;;
    esac
  done
}

# Clarify through a file (FR-005): two questions pause the run at
# answer_clarify and clarify-apply runs once it is approved; none skips both.
wf_clarify() {
  local out
  wf_fresh || return 1
  wf_result speckit-clarify.1 "asked" '{"questions":2}'
  wf_edit speckit-clarify.1 "$WF_F/clarify-questions.md" "1. which? (recommended: this)"
  wf_result speckit-clarify.2 "applied"
  wf_edit speckit-clarify.2 "$WF_F/spec.md" "# Spec, clarified"
  out=$(wf_start)
  [ "$(wf_state)" = "paused answer_clarify" ] || {
    echo "two questions did not pause the run at answer_clarify: $(wf_state)"
    printf '%s\n' "$out" | tail -8
    return 1
  }
  out=$(wf_resume -i clarify_verdict=approve)
  [ "$(wf_state)" = "paused review_spec" ] && [ "$(wf_calls | grep -c '^speckit-clarify$')" -eq 2 ] || {
    echo "clarify-apply did not run after approval: $(wf_state), calls $(wf_calls | tr '\n' ' ')"
    return 1
  }
  grep -qx "# Spec, clarified" "$WF_REPO/$WF_F/spec.md" || {
    echo "clarify-apply's spec was not applied"
    return 1
  }
  wf_fresh || return 1
  out=$(wf_start)
  [ "$(wf_state)" = "paused review_spec" ] && [ "$(wf_calls | grep -c '^speckit-clarify$')" -eq 1 ] || {
    echo "no question still stopped for clarify: $(wf_state), calls $(wf_calls | tr '\n' ' ')"
    return 1
  }
}

# Loops and retries (FR-014, FR-015, FR-017): a check that always fails gives
# three implement passes, then a stop at fix_stuck naming the two commands
# that answer it; a one-shot retry gives exactly one more, then it stops
# again; on a fix round the brief names .sdd/verify.json. A converge that
# never converges gives three passes, then a stop at converge_stuck; retry
# gives one more.
wf_loops() {
  local out n
  # A check that passes on the second pass ends the fix loop there, and a
  # converge that converges on its second pass ends the convergence there:
  # the loop reads its latest pass, not its first.
  wf_fresh || return 1
  printf '#!/bin/sh\ngrep -q "print(1)" src/app.py && exit 1\nexit 0\n' > "$WF_REPO/check-app.sh"
  git -C "$WF_REPO" -c core.hooksPath=/dev/null commit -qam "a check the second pass passes"
  # The first pass changes something that does not satisfy the check (a pass
  # that changed nothing would itself fail, research R27); the second fixes it.
  mkdir -p "$(wf_fx speckit-implement.1)" && cp "$WF_SA/fixture/by/speckit-implement/result.json" "$(wf_fx speckit-implement.1)/"
  wf_edit speckit-implement.1 src/notes.py "# a first attempt"
  wf_result speckit-converge.1 "open" '{"outcome":"tasks_appended","findings":[{"severity":"MEDIUM","text":"more"}]}'
  out=$(wf_start -i spec_verdict=approve -i plan_verdict=approve -i done_verdict=approve)
  case "$(wf_state)" in "completed "*) ;; *)
    echo "a loop that clears on its second pass did not finish: $(wf_state)"
    printf '%s\n' "$out" | tail -10
    return 1
    ;;
  esac
  [ "$(wf_calls | grep -c '^speckit-implement$')" -eq 3 ] && [ "$(wf_calls | grep -c '^speckit-converge$')" -eq 2 ] || {
    echo "passes: $(wf_calls | grep -c '^speckit-implement$') implement (wanted 2, then 1 in the second convergence pass), $(wf_calls | grep -c '^speckit-converge$') converge (wanted 2)"
    return 1
  }
  wf_fresh || return 1
  printf '#!/bin/sh\necho failing\nexit 1\n' > "$WF_REPO/check-app.sh"
  # An implementer that tries something different each round and never
  # satisfies the check (one that changed nothing would fail at once).
  local round
  for round in 1 2 3 4 5; do
    mkdir -p "$(wf_fx speckit-implement.$round)"
    cp "$WF_SA/fixture/by/speckit-implement/result.json" "$(wf_fx speckit-implement.$round)/"
    wf_edit "speckit-implement.$round" src/app.py "print($round + 1)"
  done
  git -C "$WF_REPO" -c core.hooksPath=/dev/null commit -qam "a failing check"
  out=$(wf_start -i spec_verdict=approve -i plan_verdict=approve -i done_verdict=approve)
  n=$(wf_calls | grep -c '^speckit-implement$')
  [[ "$(wf_state)" == "failed fix_loop:fix_stuck:"* ]] && [ "$n" -eq 3 ] || {
    echo "an always-failing check: $n implement passes, $(wf_state); wanted 3 and a stop at fix_stuck"
    printf '%s\n' "$out" | tail -10
    return 1
  }
  # The engine prints only the exit status; the step's message is in the
  # run's state, where sdd-run reads it for the owner.
  out=$(python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); print(d["step_results"][d["current_step_id"]]["output"]["stderr"])' \
    "$WF_REPO/.specify/workflows/runs/run1/state.json")
  if ! printf '%s' "$out" | grep -q "sdd-run resume run1 retry" || ! printf '%s' "$out" | grep -q "sdd-run abort run1"; then
    echo "the stop does not name sdd-run resume run1 retry and sdd-run abort run1: $out"
    return 1
  fi
  python3 -I -c '
import json, sys
a = [json.loads(l) for l in open(sys.argv[1])]
impl = [x["argv"][x["argv"].index("-p") + 1] for x in a if x["agent"] == "claude" and "/speckit-implement" in x["argv"][x["argv"].index("-p") + 1]]
# The brief mentions verify.json in general; a fix round says it is one.
fix = [("Fix round:" in p and ".sdd/verify.json" in p) for p in impl]
sys.exit(0 if fix == [False] + [True] * (len(impl) - 1) else "fix rounds by pass: %s; wanted only the first not one" % fix)
' "$WF_SA/agents.jsonl" || return 1
  mkdir -p "$WF_RUN/verdicts" && : > "$WF_RUN/verdicts/retry"
  out=$(wf_resume)
  n=$(wf_calls | grep -c '^speckit-implement$')
  [[ "$(wf_state)" == "failed fix_loop:fix_stuck:"* ]] && [ "$n" -eq 4 ] && [ ! -e "$WF_RUN/verdicts/retry" ] || {
    echo "one retry: $n implement passes, $(wf_state), verdict left: $(ls "$WF_RUN/verdicts")"
    printf '%s\n' "$out" | tail -10
    return 1
  }
  out=$(wf_resume)
  n=$(wf_calls | grep -c '^speckit-implement$')
  [ "$n" -eq 4 ] || {
    echo "a resume with no retry ran $n implement passes, not 4"
    return 1
  }
  wf_fresh || return 1
  wf_result speckit-converge "open" '{"outcome":"tasks_appended","findings":[{"severity":"MEDIUM","text":"more"}]}'
  out=$(wf_start -i spec_verdict=approve -i plan_verdict=approve -i done_verdict=approve)
  n=$(wf_calls | grep -c '^speckit-converge$')
  [[ "$(wf_state)" == "failed convergence:converge_stuck:"* ]] && [ "$n" -eq 3 ] || {
    echo "a converge that never converges: $n passes, $(wf_state); wanted 3 and a stop at converge_stuck"
    printf '%s\n' "$out" | tail -10
    return 1
  }
  mkdir -p "$WF_RUN/verdicts" && : > "$WF_RUN/verdicts/retry"
  out=$(wf_resume)
  n=$(wf_calls | grep -c '^speckit-converge$')
  [[ "$(wf_state)" == "failed convergence:converge_stuck:"* ]] && [ "$n" -eq 4 ] || {
    echo "one converge retry: $n passes, $(wf_state); wanted 4"
    return 1
  }
}

if command -v specify > /dev/null 2>&1 && command -v check-jsonschema > /dev/null 2>&1 && [ -x "$WF_SPEC_PY" ]; then
  check "a routed run goes through every phase on its row's model and effort, contained, and records each outcome" wf_dispatch
  check "specify creates exactly the one directory feature.json names, and no pass builds the image" wf_specify_judge
  check "the run pauses at each checkpoint, approve goes on and reject aborts" wf_gates
  check "clarify goes through a file: questions pause the run, none skips the checkpoint" wf_clarify
  check "fix and converge loops stop after three passes, and a retry buys exactly one more" wf_loops
else
  for name in "a routed run goes through every phase on its row's model and effort, contained, and records each outcome" \
    "specify creates exactly the one directory feature.json names, and no pass builds the image" \
    "the run pauses at each checkpoint, approve goes on and reject aborts" \
    "clarify goes through a file: questions pause the run, none skips the checkpoint" \
    "fix and converge loops stop after three passes, and a retry buys exactly one more"; do
    skip "$name" "specify, check-jsonschema or specify-cli's python"
  done
fi

# .specify/feature.json is Spec Kit's per-worktree state, which its own
# .gitignore keeps out of git (seen in the first real run, 2026-10-21: the
# judge refused it as an ignored path). The run validates the one specify
# wrote and writes it into the worktree itself, as Spec Kit would; it is
# never part of a patch or a commit.
wf_feature_json() {
  wf_fresh || return 1
  local out
  out=$(wf_start)
  [ "$(wf_state)" = "paused review_spec" ] || {
    echo "specify did not finish with feature.json ignored: $(wf_state): $out" | tail -5
    return 1
  }
  [ "$(cat "$WF_REPO/.specify/feature.json" 2> /dev/null)" = "{\"feature_directory\": \"$WF_F\"}" ] || {
    echo "the worktree's .specify/feature.json is not the validated one: $(cat "$WF_REPO/.specify/feature.json" 2> /dev/null)"
    return 1
  }
  [ -z "$(git -C "$WF_REPO" -c core.fsmonitor=false log --all --format=%h -- .specify/feature.json)" ] || {
    echo ".specify/feature.json went into a commit"
    return 1
  }
  [ -n "$(git -C "$WF_REPO" -c core.fsmonitor=false log --format=%h -- "$WF_F/spec.md")" ] || {
    echo "specify's spec.md was not committed"
    return 1
  }
  # Spec Kit's setup-plan.sh rewrites feature.json each time it runs (seen in
  # the real run, 2026-10-21). After specify, every phase runs with Spec Kit's
  # own switch for orchestrators, SPECIFY_FEATURE_NO_PERSIST=1 (issue #4128),
  # so its scripts write nothing there; an agent that still points it at
  # another feature is refused.
  out=$(wf_resume -i spec_verdict=approve)
  /usr/bin/python3 -I -c '
import json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
def key(a):
    argv = a["argv"]
    return argv[argv.index("-p") + 1].split()[0].lstrip("/")
bad = [key(a) for a in calls if (a["env"].get("SPECIFY_FEATURE_NO_PERSIST") == "1") == (key(a) == "speckit-specify")]
sys.exit("SPECIFY_FEATURE_NO_PERSIST is wrong for: %s" % bad if bad else 0)
' "$WF_SA/agents.jsonl" || return 1
  wf_fresh || return 1
  wf_edit speckit-plan .specify/feature.json '{"feature_directory": "specs/009-elsewhere"}'
  out=$(wf_start)
  out=$(wf_resume -i spec_verdict=approve)
  [ "$(wf_state)" = "failed plan" ] || {
    echo "plan pointing feature.json elsewhere was not refused: $(wf_state)"
    return 1
  }
}
if command -v check-jsonschema > /dev/null 2>&1 && command -v specify > /dev/null 2>&1; then
  check "specify's feature.json stays the worktree's own state: validated, written by the run, never committed" wf_feature_json
else
  skip "specify's feature.json stays the worktree's own state: validated, written by the run, never committed" "check-jsonschema or specify"
fi

# sdd-step's own decisions, without the engine.
wf_step() { (cd "$WF_REPO" && SDD_RUN_DIR=$WF_RUN "$WF_DOT/bin/sdd-step.sh" "$@" 2>&1); }
wf_outcome_file() { # step json-fields
  mkdir -p "$WF_REPO/$WF_F/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:%s:1","step":"%s","at":"2026-10-21T14:00:00Z",%s}\n' "$1" "$1" "$2" > "$WF_REPO/$WF_F/.sdd/$1.json"
}
wf_feature() {
  mkdir -p "$WF_REPO/.specify" "$WF_REPO/$WF_F"
  printf '{"feature_directory":"%s"}\n' "$WF_F" > "$WF_REPO/.specify/feature.json"
  printf -- '- [ ] T001 a\n- [ ] T002 b\n- [ ] T003 c\n' > "$WF_REPO/$WF_F/tasks.md"
}

# mark (FR-006): only on verify = pass and review = clear, and only the ids
# review lists.
wf_mark() {
  local out
  wf_fresh || return 1
  wf_feature
  wf_outcome_file verify '"command":"x","exit":1,"tail":"","check_changes":[],"automation_changes":[]'
  wf_outcome_file review '"findings":[],"done":["T002"]'
  if out=$(wf_step mark); then
    echo "marked although verify failed: $out"
    return 1
  fi
  wf_outcome_file verify '"command":"x","exit":0,"tail":"","check_changes":[],"automation_changes":[]'
  wf_outcome_file review '"findings":[{"severity":"HIGH","text":"x"}],"done":["T002"]'
  if out=$(wf_step mark); then
    echo "marked although review was blocking: $out"
    return 1
  fi
  wf_outcome_file review '"findings":[{"severity":"LOW","text":"x"}],"done":["T002","T009"]'
  out=$(wf_step mark) || {
    echo "refused to mark with verify passing and review clear: $out"
    return 1
  }
  [ "$(cat "$WF_REPO/$WF_F/tasks.md")" = "$(printf -- '- [ ] T001 a\n- [X] T002 b\n- [ ] T003 c')" ] || {
    echo "marked other than T002:"
    cat "$WF_REPO/$WF_F/tasks.md"
    return 1
  }
}

# route (FR-010): the opt-in frozen at start decides; not opted in names
# DeepSeek's terms; an opt-in made after start changes nothing.
wf_route() {
  local out
  wf_fresh || return 1
  wf_feature
  printf '{"implement":"deepseek"}\n' > "$WF_RUN/optin.json"
  out=$(wf_step route) && [ "$out" = deepseek ] || {
    echo "opted in at start: printed '$out'"
    return 1
  }
  grep -q '"agent": *"deepseek"' "$WF_REPO/$WF_F/.sdd/route.json" || {
    echo "route.json does not record deepseek"
    return 1
  }
  printf '{"implement":"sonnet"}\n' > "$WF_RUN/optin.json"
  git -C "$WF_REPO" config sdd.implement deepseek
  out=$(wf_step route)
  case "$out" in sonnet*"git config --local sdd.implement deepseek"*"deepseek.com"*"terms"*"privacy"*) ;; *)
    echo "not opted in at start (opted in after): printed '$out'; wanted sonnet and the opt-in line with DeepSeek's terms and privacy policy"
    return 1
    ;;
  esac
  grep -q '"agent": *"sonnet"' "$WF_REPO/$WF_F/.sdd/route.json" || {
    echo "route.json does not record sonnet"
    return 1
  }
}

# stuck: the counting behind the loops, and phase-done's record.
wf_stuck() {
  local out i
  wf_fresh || return 1
  wf_feature
  wf_outcome_file verify '"command":"x","exit":1,"tail":"","check_changes":[],"automation_changes":[]'
  for i in 1 2; do
    out=$(wf_step stuck fix) && [ "$out" = again ] || {
      echo "fix pass $i failed: printed '$out', wanted again"
      return 1
    }
  done
  if out=$(wf_step stuck fix); then
    echo "a third failed pass did not stop: '$out'"
    return 1
  fi
  wf_outcome_file verify '"command":"x","exit":0,"tail":"","check_changes":[],"automation_changes":[]'
  out=$(wf_step stuck fix) && [ "$out" = clear ] || {
    echo "a passing verify printed '$out', not clear"
    return 1
  }
  for i in plan tasks; do
    out=$(wf_step phase-done "$i") || {
      echo "phase-done $i failed: $out"
      return 1
    }
  done
  python3 -I -c 'import json, sys; d = json.load(open(sys.argv[1])); sys.exit([x["phase"] for x in d["done"]] != ["plan", "tasks"])' \
    "$WF_REPO/$WF_F/.sdd/phases.json" || {
    echo "phases.json does not record plan then tasks"
    return 1
  }
}

# The Sonnet implement pass's limit (FR-018): a timeout beyond its row's
# max_timeout is refused before anything runs.
wf_limit() {
  local out
  wf_fresh || return 1
  wf_feature
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$WF_REPO/$WF_F/.sdd-route"
  mkdir -p "$WF_REPO/$WF_F/.sdd" && mv "$WF_REPO/$WF_F/.sdd-route" "$WF_REPO/$WF_F/.sdd/route.json"
  # An image is there, so only the limit can stop the pass.
  printf '{"image":"sdd-worker:0123456789ab"}\n' > "$WF_RUN/worker.json"
  python3 -I -c 'import json, sys; p = sys.argv[1]; d = json.load(open(p)); d["phases"]["implement-sonnet"]["timeout"]["value"] = 4000; json.dump(d, open(p, "w"))' "$WF_RUN/routing.json"
  if out=$(wf_step implement); then
    echo "a timeout beyond max_timeout was run: $out"
    return 1
  fi
  printf '%s' "$out" | grep -q "3600" || {
    echo "the refusal does not name the ceiling: $out"
    return 1
  }
}

if command -v check-jsonschema > /dev/null 2>&1 && [ -x "$WF_SPEC_PY" ]; then
  check "mark marks only what review lists, and only on a passing verify and a clear review" wf_mark
  check "route follows the opt-in frozen at start and names DeepSeek's terms when not opted in" wf_route
  check "stuck counts three passes then stops, clears on a pass; phase-done records each phase" wf_stuck
  check "an implement limit beyond its ceiling is refused, naming it" wf_limit
else
  for name in "mark marks only what review lists, and only on a passing verify and a clear review" \
    "route follows the opt-in frozen at start and names DeepSeek's terms when not opted in" \
    "stuck counts three passes then stops, clears on a pass; phase-done records each phase" \
    "an implement limit beyond its ceiling is refused, naming it"; do
    skip "$name" "check-jsonschema or specify-cli's python"
  done
fi
[ -z "$WF_TMP" ] || rm -rf "$WF_TMP"
