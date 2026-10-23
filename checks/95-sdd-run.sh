# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: bin/sdd-run.sh bin/sdd-run.py bin/sdd-step.sh bin/sdd-pass.py bin/sdd-egress-proxy.py
# covers: claude/speckit/* claude/config-guard.sh containers/worker/* checks/sdd/run-fixture/*
# covers: checks/sdd/standins/*

# ── sdd-run ──────────────────────────────────────────────────────────────────
printf '\n%ssdd-run%s\n' "$DIM" "$OFF"

# Every case runs sdd-run from a scratch copy of the dotfiles it needs — its
# own scripts, the schemas, config-guard, the worker's recipe — with the
# fixture routing table, profiles and workflow of checks/sdd/run-fixture, so
# the checks do not move with the real table. sdd-run finds its dotfiles
# through its own path, as it does when linked from ~/.local/bin. The owner's
# PATH holds the stand-ins (Spec Kit, the container runtime, the Keychain)
# first, and HOME is scratch, so nothing reaches the network, a VM, the real
# Keychain or the owner's run registry.
SR_ROOT=$PWD
SR=

sr_fresh() { # sets SR (scratch), SR_REPO, SR_SA (stand-ins)
  SR=$(mktemp -d) || return 1
  local d=$SR/dotfiles f
  mkdir -p "$d/bin" "$d/claude/speckit" "$d/containers" "$SR/dbin" "$SR/home"
  for f in sdd-run.sh sdd-run.py sdd-step.sh sdd-pass.py sdd-egress-proxy.py; do
    [ -e "$SR_ROOT/bin/$f" ] && cp "$SR_ROOT/bin/$f" "$d/bin/"
  done
  cp "$SR_ROOT/claude/config-guard.sh" "$d/claude/"
  cp -R "$SR_ROOT/claude/speckit/schemas" "$d/claude/speckit/"
  cp -R "$SR_ROOT/checks/sdd/run-fixture/profiles" "$d/claude/speckit/"
  cp "$SR_ROOT/checks/sdd/run-fixture/routing.yml" "$SR_ROOT/checks/sdd/run-fixture/sdd-routed.yml" "$d/claude/speckit/"
  cp "$SR_ROOT/claude/speckit/brief.md" "$SR_ROOT/claude/speckit/pi-models.json" "$SR_ROOT/claude/speckit/egress-registries.txt" "$d/claude/speckit/"
  cp -R "$SR_ROOT/containers/worker" "$d/containers/"
  SR_SA=$SR/standins
  cp -R "$SR_ROOT/checks/sdd/standins" "$SR_SA"
  mkdir -p "$SR_SA/secrets"
  printf 'sk-ant-oat01-FAKEclaude' > "$SR_SA/secrets/claude-oauth"
  printf 'sk-FAKEdeepseek' > "$SR_SA/secrets/deepseek-api"
  cp "$SR_ROOT/containers/worker/inventory.txt" "$SR_SA/inventory.out"
  ln -s "$d/bin/sdd-step.sh" "$SR/dbin/sdd-step"
  ln -s "$d/bin/sdd-run.sh" "$SR/dbin/sdd-run"
  ln -s "$(command -v check-jsonschema)" "$SR/dbin/check-jsonschema"
  SR_REPO=$SR/repo
  mkdir -p "$SR_REPO/.specify/workflows/sdd-routed" "$SR_REPO/specs"
  cp "$d/claude/speckit/sdd-routed.yml" "$SR_REPO/.specify/workflows/sdd-routed/workflow.yml"
  (
    cd "$SR_REPO" || exit 1
    git init -q -b main
    printf '#!/bin/sh\nexit 0\n' > check.sh
    chmod +x check.sh
    git add -A && git -c user.name=t -c user.email=t@t commit -qm base
    git config sdd.check ./check.sh
    git config user.name owner && git config user.email owner@example.com
  ) || return 1
}
# Runs sdd-run as the owner would, from the repository root — or from
# $SR_IN, another worktree. The owner's shell has an effort level set, which
# sdd-run must not pass on.
sr() {
  (cd "${SR_IN:-$SR_REPO}" && CLAUDE_CODE_EFFORT_LEVEL=max HOME="$SR/home" \
    PATH="$SR_SA:$SR/dbin:/usr/bin:/bin:/usr/sbin:/sbin" sdd-run "$@" 2>&1)
}
sr_common() { git -C "$SR_REPO" rev-parse --path-format=absolute --git-common-dir; }
sr_last_id() { # the run id of the last specify call
  /usr/bin/python3 -I -c 'import json,sys; print([json.loads(l) for l in open(sys.argv[1])][-1]["env"].get("SPECKIT_WORKFLOW_RUN_ID",""))' "$SR_SA/specify.jsonl" 2> /dev/null
}
sr_calls() { awk '/"workflow"/ { n++ } END { print n + 0 }' "$SR_SA/specify.jsonl" 2> /dev/null || echo 0; }

# contracts/sdd-run.md, "Prerequisites": each missing one stops start with
# exit 1 and a line naming it, before Spec Kit runs a step (FR-011, FR-021,
# FR-024, US1 AS7).
sdd_run_prereqs() {
  local status=0 out code case
  trap '[ -z "$SR" ] || rm -rf "$SR"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  refused() { # case words...: start must exit 1, run no workflow, and name each word
    local why=$1 word
    shift
    out=$(sr start "a feature") && code=0 || code=$?
    [ "$code" -eq 1 ] || fail "$why: exit $code, wanted 1: $out"
    [ "$(sr_calls)" -eq 0 ] || fail "$why: Spec Kit ran a workflow anyway"
    for word in "$@"; do
      printf '%s' "$out" | grep -qiF -- "$word" || fail "$why: the message does not name '$word': $out"
    done
  }
  for case in old-speckit no-specify no-workflow old-workflow runtime-down no-runtime no-token blank-token \
    no-sdd-step proxy-down no-check no-pi-integration; do
    [ -z "$SR" ] || rm -rf "$SR"
    sr_fresh || return 1
    case $case in
      old-speckit)
        echo "specify 1.2.1" > "$SR_SA/version.txt"
        refused "$case" "1.2.2"
        ;;
      no-specify)
        rm -rf "$SR_REPO/.specify"
        refused "$case" ".specify"
        ;;
      no-workflow)
        rm -rf "$SR_REPO/.specify/workflows/sdd-routed"
        refused "$case" "sdd-routed" "specify workflow add"
        ;;
      old-workflow)
        sed -i.bak 's/version: "1.0.0"/version: "0.9.0"/' "$SR_REPO/.specify/workflows/sdd-routed/workflow.yml"
        refused "$case" "sdd-routed" "0.9.0"
        ;;
      runtime-down)
        : > "$SR_SA/runtime.down"
        refused "$case" "container"
        ;;
      no-runtime)
        rm "$SR_SA/container"
        refused "$case" "container"
        ;;
      no-token)
        rm "$SR_SA/secrets/claude-oauth"
        refused "$case" "claude-oauth"
        ;;
      blank-token)
        : > "$SR_SA/secrets/claude-oauth"
        refused "$case" "claude-oauth"
        ;;
      no-sdd-step)
        rm "$SR/dbin/sdd-step"
        refused "$case" "sdd-step"
        ;;
      proxy-down)
        : > "$SR_SA/proxy.fail"
        refused "$case" "egress proxy"
        ;;
      no-check)
        git -C "$SR_REPO" config --unset sdd.check
        refused "$case" "sdd.check"
        ;;
      # Opted in to DeepSeek, pi runs Spec Kit's own implement command through
      # Spec Kit's pi integration; without it, pi would have no such command.
      no-pi-integration)
        git -C "$SR_REPO" config sdd.implement deepseek
        refused "$case" "specify integration install pi"
        ;;
    esac
  done
  # A stub /usr/bin/python3 (the Command Line Tools absent): sdd-run's own
  # first line checks it, on a copy whose interpreter path names a stub.
  rm -rf "$SR"
  sr_fresh || return 1
  printf '#!/bin/sh\necho "xcode-select: note: no developer tools were found" >&2\nexit 1\n' > "$SR/stub-python3"
  chmod +x "$SR/stub-python3"
  sed "s#/usr/bin/python3#$SR/stub-python3#g" "$SR/dotfiles/bin/sdd-run.sh" > "$SR/dotfiles/bin/sdd-run.sh.new" &&
    mv "$SR/dotfiles/bin/sdd-run.sh.new" "$SR/dotfiles/bin/sdd-run.sh" && chmod +x "$SR/dotfiles/bin/sdd-run.sh"
  refused "stub python3" "python3" "Command Line Tools"
  # With every prerequisite met: Spec Kit runs once, without the owner's
  # effort level, and the effective table lands in the feature's .sdd/.
  rm -rf "$SR"
  sr_fresh || return 1
  # As sdd-pass's specify pass does: the pointer, and the run's own record of it.
  cat > "$SR_SA/specify.sh" << 'SH'
mkdir -p specs/001-x && printf '{"feature_directory":"specs/001-x"}' | tee .specify/feature.json > "$SDD_RUN_DIR/feature.json"
SH
  out=$(sr start "a feature") || fail "all met: failed: $out"
  [ "$(sr_calls)" -eq 1 ] || fail "all met: Spec Kit ran $(sr_calls) workflows"
  grep -q CLAUDE_CODE_EFFORT_LEVEL "$SR_SA/specify.jsonl" && fail "all met: CLAUDE_CODE_EFFORT_LEVEL reached Spec Kit"
  /usr/bin/python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = d["phases"]["plan"]["model"]
sys.exit(0 if v == {"value": "claude-opus-5-5", "layer": "defaults"} else "plan.model recorded as %r" % v)
' "$SR_REPO/specs/001-x/.sdd/routing.json" || fail "all met: .sdd/routing.json does not record plan.model with its layer"
  return "$status"
}
check "sdd-run start stops on each missing prerequisite, names it, and runs nothing" sdd_run_prereqs

# The routing layers (FR-027, contracts/routing.md) and the run bundle.
sdd_run_layers() {
  local status=0 out code id bundle
  trap '[ -z "$SR" ] || rm -rf "$SR"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  sr_fresh || return 1
  mkdir -p "$SR_REPO/.claude"
  printf 'phases:\n  plan:\n    effort: high\n  tasks:\n    timeout: 600\n' > "$SR_REPO/.claude/sdd-routing.yml"
  printf 'phases:\n  plan:\n    effort: xhigh\n' > "$SR_REPO/.claude/sdd-routing.local.yml"
  out=$(sr routing) || fail "routing: failed: $out"
  printf '%s\n' "$out" | grep -qE '^plan +effort +xhigh +local$' || fail "routing: the local layer does not win plan.effort: $out"
  printf '%s\n' "$out" | grep -qE '^plan +model +claude-opus-5-5 +defaults$' || fail "routing: plan.model is not the default's: $out"
  printf '%s\n' "$out" | grep -qE '^tasks +timeout +600 +repository$' || fail "routing: tasks.timeout is not the repository's: $out"
  out=$(sr routing --set plan.effort=max) || fail "routing --set: failed: $out"
  printf '%s\n' "$out" | grep -qE '^plan +effort +max +set$' || fail "routing --set: --set does not win: $out"
  # --set is one run's: typed, frozen in that run's bundle, gone from the next.
  printf '{"status":"paused","current_step_id":"review-spec"}\n' > "$SR_SA/state.json"
  out=$(sr start --set plan.timeout=900 "a feature") || fail "start --set: failed: $out"
  id=$(sr_last_id)
  bundle=$(sr_common)/sdd/$id
  [ -n "$id" ] && [ -d "$bundle" ] || fail "start: no bundle under --git-common-dir for run '$id'"
  /usr/bin/python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
v = d["phases"]["plan"]["timeout"]
sys.exit(0 if v == {"value": 900, "layer": "set"} else "plan.timeout frozen as %r" % v)
' "$bundle/routing.json" || fail "start --set: plan.timeout is not the integer 900 from --set"
  local f
  for f in lock.json optin.json check.json routing.json tools.json profiles/author.json hooks/config-guard.sh worker.json; do
    [ -s "$bundle/$f" ] || fail "start: the bundle lacks $f"
  done
  grep -F '"SDD_RUN_DIR"' "$SR_SA/specify.jsonl" | tail -1 | grep -qF "\"$bundle\"" || fail "start: SDD_RUN_DIR is not the bundle"
  /usr/bin/python3 -I -c '
import json, sys
env = [json.loads(l) for l in open(sys.argv[1])][-1]["env"]
sys.exit(0 if env.get("SDD_STEP") == json.load(open(sys.argv[2]))["sdd-step"] else "SDD_STEP is %r" % env.get("SDD_STEP"))
' "$SR_SA/specify.jsonl" "$bundle/tools.json" || fail "start: SDD_STEP is not the sdd-step tools.json froze"
  out=$(sr routing) || true
  printf '%s\n' "$out" | grep -qE '^plan +timeout +3600 +defaults$' || fail "routing: the --set of an earlier run outlived it: $out"
  # resume reuses the bundle as it is, whatever the layers say now.
  printf '{"status":"completed"}\n' > "$SR_SA/state.json"
  printf 'phases:\n  plan:\n    effort: low\n' > "$SR_REPO/.claude/sdd-routing.local.yml"
  cp "$bundle/routing.json" "$SR/routing.before"
  out=$(sr resume "$id" approve) || fail "resume: failed: $out"
  cmp -s "$SR/routing.before" "$bundle/routing.json" || fail "resume: the bundle's table changed"
  # Refusals name the layer, the phase and the field.
  local bad
  for bad in "nope:effort:high" "plan:agent:pi" "plan:prompt:/x" "plan:writes:[x]" "plan:max_timeout:9" \
    "plan:model:deepseek-flash" "implement-deepseek:model:claude-opus-5-5" "plan:timeout:99999" "plan:color:red"; do
    IFS=: read -r phase field value <<< "$bad"
    printf 'phases:\n  %s:\n    %s: %s\n' "$phase" "$field" "$value" > "$SR_REPO/.claude/sdd-routing.yml"
    out=$(sr routing) && code=0 || code=$?
    [ "$code" -eq 1 ] || fail "layer $bad: exit $code, wanted 1: $out"
    if ! printf '%s' "$out" | grep -qF ".claude/sdd-routing.yml" || ! printf '%s' "$out" | grep -qF "$phase" ||
      ! printf '%s' "$out" | grep -qF "$field"; then
      fail "layer $bad: the refusal does not name the layer, phase and field: $out"
    fi
  done
  rm "$SR_REPO/.claude/sdd-routing.yml"
  out=$(sr routing --set plan.timeout=99999) && code=0 || code=$?
  if [ "$code" -ne 1 ] || ! printf '%s' "$out" | grep -qF 7200; then
    fail "--set beyond max_timeout: not refused naming the ceiling: $out"
  fi
  # --init-local: the local file, excluded through the common dir, once.
  rm -f "$SR_REPO/.claude/sdd-routing.local.yml"
  out=$(sr routing --init-local) || fail "--init-local: failed: $out"
  [ -f "$SR_REPO/.claude/sdd-routing.local.yml" ] || fail "--init-local: no local file"
  out=$(sr routing --init-local) || fail "--init-local again: failed: $out"
  [ "$(grep -cxF .claude/sdd-routing.local.yml "$(sr_common)/info/exclude")" -eq 1 ] ||
    fail "--init-local: the local file is not excluded exactly once"
  [ -z "$(git -C "$SR_REPO" status --porcelain .claude)" ] || fail "--init-local: git sees the local file"
  return "$status"
}
check "routing layers merge field by field, refuse what a layer may not set, and freeze in a bundle resume reuses" sdd_run_layers

# A run's lifecycle (FR-022, contracts/sdd-run.md): the egress proxy lives
# exactly as long as the Spec Kit child, with its heartbeat; the run
# registers and finishes; paused, stuck, dead and restarted runs.
sdd_run_lifecycle() {
  local status=0 out code id bundle
  trap '[ -z "$SR" ] || rm -rf "$SR"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  sr_fresh || return 1
  # While Spec Kit runs, the proxy is up and its heartbeat moves.
  cat > "$SR_SA/specify.sh" << 'SH'
here=$(cd "$(dirname "$0")" && pwd -P)
ls "$here"/running.sdd-*-proxy > "$here/proxy-during" 2> /dev/null
ls -l "$HOME/.local/state/sdd/runs/$SPECKIT_WORKFLOW_RUN_ID" > "$here/link-during" 2> /dev/null
stat -f %m "$SDD_RUN_DIR/admissions/heartbeat" > "$here/beat1"
sleep 3
stat -f %m "$SDD_RUN_DIR/admissions/heartbeat" > "$here/beat2"
SH
  out=$(sr start "a feature") || fail "start: failed: $out"
  id=$(sr_last_id)
  bundle=$(sr_common)/sdd/$id
  [ -s "$SR_SA/proxy-during" ] || fail "proxy: not running while Spec Kit ran"
  ! cmp -s "$SR_SA/beat1" "$SR_SA/beat2" || fail "proxy: the heartbeat did not move during the run"
  ls "$SR_SA"/running.sdd-*-proxy > /dev/null 2>&1 && fail "proxy: still running after Spec Kit exited"
  grep -qx "sdd-$id" "$SR_SA/networks.txt" 2> /dev/null && fail "proxy: the run's network outlived it"
  # Registered for the image pruning, and finished once completed.
  grep -qF "$bundle" "$SR_SA/link-during" 2> /dev/null || fail "registry: no link to the bundle while the run ran"
  [ -s "$bundle/finished.json" ] || fail "finished: a completed run wrote no finished.json"
  [ ! -e "$SR/home/.local/state/sdd/runs/$id" ] || fail "registry: a finished run is still linked"
  # Paused at a gate: exit 0, the gate and the command that answers it.
  rm -f "$SR_SA/specify.sh"
  printf '{"status":"paused","current_step_id":"review-plan"}\n' > "$SR_SA/state.json"
  out=$(sr start "another") && code=0 || code=$?
  id=$(sr_last_id)
  bundle=$(sr_common)/sdd/$id
  [ "$code" -eq 0 ] || fail "paused: exit $code"
  printf '%s' "$out" | grep -qF "sdd-run resume $id" || fail "paused: the resume command is not printed: $out"
  [ ! -e "$bundle/finished.json" ] || fail "paused: a paused run is finished"
  [ -L "$SR/home/.local/state/sdd/runs/$id" ] || fail "paused: a paused run lost its registry link"
  # The verdict binds to the paused gate's input.
  printf '{"status":"completed"}\n' > "$SR_SA/state.json"
  out=$(sr resume "$id" approve) || fail "resume approve: failed: $out"
  tail -1 "$SR_SA/specify.jsonl" | grep -qF '"plan_verdict=approve"' || fail "resume approve: not bound to plan_verdict: $(tail -1 "$SR_SA/specify.jsonl")"
  # Paused outside a gate (Ctrl-C): no verdict, the interrupted step reruns.
  printf '{"status":"paused","current_step_id":"plan"}\n' > "$SR_SA/state.json"
  out=$(sr start "third") || true
  id=$(sr_last_id)
  out=$(sr resume "$id") || fail "resume after Ctrl-C: failed: $out"
  local last
  last=$(tail -1 "$SR_SA/specify.jsonl")
  grep -qF '"-i"' <<< "$last" && fail "resume after Ctrl-C: a verdict was passed"
  tail -1 "$SR_SA/specify.jsonl" | grep -qF "\"resume\", \"$id\"" || fail "resume after Ctrl-C: Spec Kit was not resumed"
  # Stuck: retry writes the one-shot verdict, then resumes; abort finishes.
  # One run at a time in a worktree: the previous run, left paused, is ended first.
  sr abort "$id" > /dev/null
  printf '{"status":"failed","current_step_id":"fix_loop:fix_stuck:2"}\n' > "$SR_SA/state.json"
  out=$(sr start "fourth") || true
  id=$(sr_last_id)
  bundle=$(sr_common)/sdd/$id
  if ! printf '%s' "$out" | grep -qF "sdd-run resume $id retry" || ! printf '%s' "$out" | grep -qF "sdd-run abort $id"; then
    fail "stuck: the two commands that answer it are not named: $out"
  fi
  {
    printf 'seen=%s/retry-seen\n' "$SR_SA"
    cat << 'SH'
cp "$SDD_RUN_DIR/verdicts/retry" "$seen" 2> /dev/null
SH
  } > "$SR_SA/specify.sh"
  # Stuck again after the one more round, as an always-failing check is.
  out=$(sr resume "$id" retry) || fail "retry: failed: $out"
  [ -e "$SR_SA/retry-seen" ] || fail "retry: no one-shot verdict while Spec Kit resumed"
  last=$(tail -1 "$SR_SA/specify.jsonl")
  grep -qF '"-i"' <<< "$last" && fail "retry: retry was passed as an input"
  rm -f "$SR_SA/specify.sh"
  printf 'sdd.run=%s ' "$id" > "$SR_SA/labels.sdd-$id-plan-1"
  out=$(sr abort "$id") || fail "abort: failed: $out"
  grep -q aborted "$bundle/finished.json" 2> /dev/null || fail "abort: not recorded aborted"
  [ ! -e "$SR_SA/labels.sdd-$id-plan-1" ] || fail "abort: the run's container remains"
  # A run whose process died mid-step: Spec Kit still says running and will
  # not resume it; resume says so, names what runs again, and points at
  # start --from; the next start's cleanup finishes it and drops its link.
  printf '{"status":"paused","current_step_id":"plan"}\n' > "$SR_SA/state.json"
  out=$(sr start "fifth") || true
  id=$(sr_last_id)
  bundle=$(sr_common)/sdd/$id
  mkdir -p "$SR_REPO/specs/002-dead/.sdd" "$bundle/passes/plan-1/export"
  # Its specify made specs/002-dead: the pointer, and the bundle's record of it.
  printf '{"feature_directory":"specs/002-dead"}\n' | tee "$SR_REPO/.specify/feature.json" > "$bundle/feature.json"
  : > "$SR_REPO/specs/002-dead/spec.md"
  printf '{"schema":"urn:dotfiles:sdd:phases:1","step":"phases","at":"2026-10-21T14:00:00Z","done":[{"phase":"specify","at":"2026-10-21T14:00:00Z"}]}\n' > "$SR_REPO/specs/002-dead/.sdd/phases.json"
  printf '{"status":"running","current_step_id":"plan"}\n' > "$SR_REPO/.specify/workflows/runs/$id/state.json"
  rm -f "$bundle/finished.json"
  ln -sfn "$bundle" "$SR/home/.local/state/sdd/runs/$id"
  # The lock names a live process that is not the run's (a reused pid).
  /usr/bin/python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["pid"]=int(sys.argv[2]); d["started"]="Thu Jan  1 00:00:00 1970"; json.dump(d,open(p,"w"))' "$bundle/lock.json" "$$"
  out=$(sr resume "$id") && code=0 || code=$?
  [ "$code" -eq 1 ] || fail "dead resume: exit $code"
  printf '%s' "$out" | grep -qF "sdd-run start --from specs/002-dead" || fail "dead resume: start --from not named: $out"
  printf '%s' "$out" | grep -qF "plan, tasks, build" || fail "dead resume: the phases that run again not named: $out"
  local dead=$id
  out=$(sr start "sixth") || true
  [ ! -e "$bundle/passes/plan-1" ] || fail "cleanup: the dead run's exports remain"
  [ -s "$bundle/finished.json" ] || fail "cleanup: the dead run is not finished"
  [ ! -L "$SR/home/.local/state/sdd/runs/$dead" ] || fail "cleanup: the dead run's registry link remains"
  ln -s "$SR/nowhere" "$SR/home/.local/state/sdd/runs/stale1"
  # One run at a time in a worktree: the previous run, left paused, is ended first.
  id=$(sr_last_id)
  sr abort "$id" > /dev/null
  out=$(sr start "seventh") || true
  [ ! -L "$SR/home/.local/state/sdd/runs/stale1" ] || fail "cleanup: a stale registry link remains"
  # start --from: spec.md and the first unfinished phase; refused with none.
  # One run at a time in a worktree: the previous run, left paused, is ended first.
  id=$(sr_last_id)
  sr abort "$id" > /dev/null
  printf '{"status":"completed"}\n' > "$SR_SA/state.json"
  out=$(sr start --from specs/002-dead) || fail "start --from: failed: $out"
  if ! tail -1 "$SR_SA/specify.jsonl" | grep -qF '"spec=specs/002-dead/spec.md"' ||
    ! tail -1 "$SR_SA/specify.jsonl" | grep -qF '"resume_from=plan"'; then
    fail "start --from: not spec.md and resume_from=plan: $(tail -1 "$SR_SA/specify.jsonl")"
  fi
  mkdir -p "$SR_REPO/specs/003-none"
  : > "$SR_REPO/specs/003-none/spec.md"
  out=$(sr start --from specs/003-none) && code=0 || code=$?
  [ "$code" -eq 1 ] || fail "start --from with no finished phase: exit $code: $out"
  # Run ids are unique across repositories: a second repository's run never
  # takes a registered id.
  /usr/bin/python3 -I -c '
import collections, json, sys
calls = [json.loads(l) for l in open(sys.argv[1])]
ids = collections.Counter(c["env"]["SPECKIT_WORKFLOW_RUN_ID"] for c in calls if c["argv"][:2] == ["workflow", "run"])
twice = [i for i, n in ids.items() if n > 1]
sys.exit("run ids: one id started two runs: %s" % twice if twice else 0)
' "$SR_SA/specify.jsonl" || status=1
  return "$status"
}
check "a run's proxy lives as long as Spec Kit, and paused, stuck, dead and restarted runs end as they should" sdd_run_lifecycle

# sdd-run usage (SC-001's counting): per model, every attempt's reported
# cost, failed and resumed ones included; attempts that reported nothing
# listed; pi's tokens priced from the worker's models.json.
# The US1 review's LOWs (2026-10-21): an exclude file without a final newline
# keeps its last line; a layer of the wrong shape is refused, not a traceback;
# aborting a finished run changes nothing and says so.
sdd_run_lows() {
  local status=0 out code exclude id bundle
  trap '[ -z "$SR" ] || rm -rf "$SR"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  sr_fresh || return 1
  exclude=$(sr_common)/info/exclude
  printf '*.tmp' > "$exclude"
  out=$(sr routing --init-local) || fail "init-local: failed: $out"
  grep -qx '\*.tmp' "$exclude" || fail "init-local: the exclude file's last line was changed: $(cat "$exclude")"
  grep -qx '.claude/sdd-routing.local.yml' "$exclude" || fail "init-local: the local layer is not excluded: $(cat "$exclude")"
  local shape
  for shape in 'phases: [plan]' '- plan'; do
    printf '%s\n' "$shape" > "$SR_REPO/.claude/sdd-routing.yml"
    out=$(sr routing) && code=0 || code=$?
    [ "$code" -eq 1 ] || fail "layer '$shape': exit $code, wanted 1"
    grep -q "Traceback" <<< "$out" && fail "layer '$shape': a traceback: $(printf '%s' "$out" | tail -1)"
  done
  rm "$SR_REPO/.claude/sdd-routing.yml"
  printf '{"status":"completed"}\n' > "$SR_SA/state.json"
  out=$(sr start "a feature") || fail "start: failed: $out"
  id=$(sr_last_id)
  bundle=$(sr_common)/sdd/$id
  cp "$bundle/finished.json" "$SR/finished.before"
  out=$(sr abort "$id") || fail "abort of a finished run: failed: $out"
  printf '%s' "$out" | grep -qF "already finished (completed)" || fail "abort of a finished run: not said so: $out"
  cmp -s "$SR/finished.before" "$bundle/finished.json" || fail "abort of a finished run: finished.json changed"
  return "$status"
}
check "sdd-run keeps an exclude file's last line, refuses a malformed layer, and aborts no finished run" sdd_run_lows

# The US1 review's second round (2026-10-22). A feature directory with its
# specify phase finished, for start --from.
sr_feature() { # dir
  mkdir -p "$SR_REPO/$1/.sdd"
  printf '# Spec\n' > "$SR_REPO/$1/spec.md"
  printf '{"schema":"urn:dotfiles:sdd:phases:1","step":"phases","at":"2026-10-22T10:00:00Z","done":[{"phase":"specify","at":"2026-10-22T10:00:00Z"}]}\n' > "$SR_REPO/$1/.sdd/phases.json"
}
sdd_run_review2() {
  local status=0 out code id bundle calls nested
  trap '[ -z "$SR" ] || rm -rf "$SR"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  # N1 (HIGH). A worktree whose pointer an earlier run left naming its
  # feature: a run whose specify fails before writing the pointer is not
  # pinned to that feature, writes nothing into it, and once specify makes
  # its own feature works on that one through the checkpoints.
  sr_fresh || return 1
  printf 'feature.json\n' > "$SR_REPO/.specify/.gitignore"
  sr_feature specs/001-old
  rm -rf "$SR_REPO/specs/001-old/.sdd"
  printf '{"feature_directory":"specs/001-old"}' > "$SR_REPO/.specify/feature.json"
  printf '{"status":"failed","current_step_id":"specify"}\n' > "$SR_SA/state.json"
  out=$(sr start "a new feature") || true
  id=$(sr_last_id)
  bundle=$(sr_common)/sdd/$id
  [ ! -e "$bundle/feature.json" ] || fail "leftover pointer: the run is pinned to $(cat "$bundle/feature.json" | tr -d '\n ') before its specify wrote any"
  [ ! -e "$SR_REPO/specs/001-old/.sdd" ] || fail "leftover pointer: the run wrote into the earlier feature: $(ls "$SR_REPO/specs/001-old/.sdd")"
  # Had it died there, the advice would not send start --from to the earlier feature.
  printf '{"status":"running","current_step_id":"specify"}\n' > "$SR_REPO/.specify/workflows/runs/$id/state.json"
  out=$(sr resume "$id") || true
  grep -qF "start --from specs/001-old" <<< "$out" && fail "leftover pointer: a dead run's advice names the earlier feature: $out"
  grep -qF 'start it anew, sdd-run start "<description>"' <<< "$out" || fail "leftover pointer: a dead run's advice is not to start anew: $out"
  cp "$SR_SA/state.json" "$SR_REPO/.specify/workflows/runs/$id/state.json"
  # As sdd-pass's specify pass does: the pointer, and the run's own record of it.
  cat > "$SR_SA/specify.sh" << 'SH'
mkdir -p specs/002-new && echo x > specs/002-new/spec.md
printf '{"feature_directory":"specs/002-new"}' | tee .specify/feature.json > "$SDD_RUN_DIR/feature.json"
SH
  printf '{"status":"paused","current_step_id":"review-spec"}\n' > "$SR_SA/state.json"
  out=$(sr resume "$id") || fail "leftover pointer: resume after specify failed: $out"
  rm "$SR_SA/specify.sh"
  [ -s "$SR_REPO/specs/002-new/.sdd/routing.json" ] || fail "leftover pointer: no routing.json in the run's own feature"
  printf '{"status":"completed"}\n' > "$SR_SA/state.json"
  out=$(sr resume "$id" approve) || fail "leftover pointer: approve refused: $out"
  tail -1 "$SR_SA/specify.jsonl" | grep -qF '"spec_verdict=approve"' || fail "leftover pointer: approve did not reach Spec Kit"
  [ ! -e "$SR_REPO/specs/001-old/.sdd" ] || fail "leftover pointer: the run wrote into the earlier feature at last"
  rm -rf "$SR"

  # N2a. A resume refuses a pointer moved since the run was pinned, before
  # Spec Kit runs.
  sr_fresh || return 1
  sr_feature specs/002-x
  sr_feature specs/003-y
  printf '{"status":"paused","current_step_id":"review-plan"}\n' > "$SR_SA/state.json"
  out=$(sr start --from specs/002-x) || fail "moved pointer: start --from failed: $out"
  id=$(sr_last_id)
  printf '{"feature_directory":"specs/003-y"}' > "$SR_REPO/.specify/feature.json"
  calls=$(sr_calls)
  out=$(sr resume "$id" approve) && code=0 || code=$?
  [ "$code" -eq 1 ] || fail "moved pointer: resume exit $code, wanted 1: $out"
  [ "$(sr_calls)" -eq "$calls" ] || fail "moved pointer: Spec Kit resumed anyway"
  if ! grep -qF "specs/002-x" <<< "$out" || ! grep -qF "specs/003-y" <<< "$out"; then
    fail "moved pointer: the refusal does not name both features: $out"
  fi

  # N2b. abort from another worktree of the repository refuses, naming the
  # run's own, and leaves the run unfinished.
  git -C "$SR_REPO" worktree add -q "$SR/wt" -b other 2> /dev/null
  out=$(SR_IN=$SR/wt sr abort "$id") && code=0 || code=$?
  [ "$code" -eq 1 ] || fail "other worktree: abort exit $code, wanted 1: $out"
  grep -qF "$SR_REPO" <<< "$out" || fail "other worktree: the run's worktree is not named: $out"
  [ ! -e "$(sr_common)/sdd/$id/finished.json" ] || fail "other worktree: the run was finished from another worktree"

  # N2c. A paused run's gates are its own workflow copy's: the installed
  # workflow changing a gate's options and input after start changes nothing
  # the run accepts or binds.
  printf '{"feature_directory":"specs/002-x"}' > "$SR_REPO/.specify/feature.json"
  sr abort "$id" > /dev/null
  printf '{"status":"paused","current_step_id":"review-spec"}\n' > "$SR_SA/state.json"
  out=$(sr start "a feature") || fail "own gates: start failed: $out"
  id=$(sr_last_id)
  sed -i.bak -e 's/verdict_input: spec_verdict/verdict_input: spec_answer/' -e 's/options: \[approve, reject\]/options: [approve, reject, later]/' \
    "$SR_REPO/.specify/workflows/sdd-routed/workflow.yml"
  calls=$(sr_calls)
  out=$(sr resume "$id" later) && code=0 || code=$?
  [ "$code" -eq 1 ] && [ "$(sr_calls)" -eq "$calls" ] || fail "own gates: a verdict only the installed workflow offers was taken (exit $code): $out"
  printf '{"status":"completed"}\n' > "$SR_SA/state.json"
  out=$(sr resume "$id" approve) || fail "own gates: approve failed: $out"
  tail -1 "$SR_SA/specify.jsonl" | grep -qF '"spec_verdict=approve"' ||
    fail "own gates: the verdict is not bound to the run's own input: $(tail -1 "$SR_SA/specify.jsonl")"
  rm -rf "$SR"

  # N3. A run whose process is alive blocks a second start in its worktree
  # even before Spec Kit holds any state for it — the window of cleanup,
  # prepare-worker and the proxy — and the second start's --from leaves the
  # pointer alone. The second start is made from inside the first's Spec
  # Kit, where the first's state.json does not exist yet.
  sr_fresh || return 1
  sr_feature specs/002-x
  nested=$SR/nested
  cat > "$SR_SA/specify.sh" << SH
[ -e "$nested.code" ] && exit 0
: > "$nested.code"
sdd-run start --from specs/002-x > "$nested.out" 2>&1
echo \$? > "$nested.code"
cat .specify/feature.json > "$nested.pointer" 2> /dev/null
exit 0
SH
  printf '{"status":"paused","current_step_id":"review-spec"}\n' > "$SR_SA/state.json"
  out=$(sr start "the first") || fail "live run: the first start failed: $out"
  # From the first start's own output: the last specify call here is the
  # second start's --version, which carries no run id.
  id=$(sed -n 's/^sdd-run: run \([0-9a-f]*\)$/\1/p' <<< "$out")
  [ "$(cat "$nested.code" 2> /dev/null)" = 1 ] || fail "live run: a second start passed the guard (exit $(cat "$nested.code" 2> /dev/null)): $(tail -2 "$nested.out" 2> /dev/null)"
  grep -qE "run $id of this worktree is running \(process [0-9]+\)" "$nested.out" 2> /dev/null ||
    fail "live run: the second start's refusal does not name the live run and its process: $(tail -2 "$nested.out" 2> /dev/null)"
  [ ! -s "$nested.pointer" ] || fail "live run: the second start rewrote the pointer under the first: $(cat "$nested.pointer")"
  [ "$(awk '/"workflow", "run"/ { n++ } END { print n + 0 }' "$SR_SA/specify.jsonl")" -eq 1 ] || fail "live run: Spec Kit ran a second run"
  rm -rf "$SR"

  # N4 (the third round, MEDIUM). A run that dies after its specify made and
  # recorded its feature, but before any phase is recorded done (here during
  # clarify_ask), cannot be taken up by start --from, which needs a finished
  # phase: the advice is to start anew, naming the directory left behind.
  sr_fresh || return 1
  cat > "$SR_SA/specify.sh" << 'SH'
mkdir -p specs/001-new && echo x > specs/001-new/spec.md
printf '{"feature_directory":"specs/001-new"}' | tee .specify/feature.json > "$SDD_RUN_DIR/feature.json"
SH
  printf '{"status":"failed","current_step_id":"clarify_ask"}\n' > "$SR_SA/state.json"
  out=$(sr start "a new feature") || true
  rm "$SR_SA/specify.sh"
  id=$(sr_last_id)
  printf '{"status":"running","current_step_id":"clarify_ask"}\n' > "$SR_REPO/.specify/workflows/runs/$id/state.json"
  out=$(sr resume "$id") && code=0 || code=$?
  [ "$code" -eq 1 ] || fail "died before a phase finished: resume exit $code, wanted 1: $out"
  grep -qF "start --from" <<< "$out" && fail "died before a phase finished: the advice is a start --from that refuses: $out"
  grep -qF 'start it anew, sdd-run start "<description>"' <<< "$out" || fail "died before a phase finished: the advice is not to start anew: $out"
  grep -qF "specs/001-new" <<< "$out" || fail "died before a phase finished: the directory left behind is not named: $out"
  return "$status"
}
check "sdd-run pins only its own feature, refuses a moved pointer, another worktree's abort, gates not its own, and a second start beside a live run" sdd_run_review2

sdd_run_usage() {
  local status=0 out common
  trap '[ -z "$SR" ] || rm -rf "$SR"' RETURN
  fail() {
    echo "$1"
    status=1
  }
  sr_fresh || return 1
  common=$(sr_common)
  mkdir -p "$common/sdd/aaa111" "$common/sdd/bbb222"
  # The run's own prices, frozen in its bundle: one unlike dotfiles', so a
  # report priced from dotfiles shows.
  /usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); c=d["providers"]["deepseek"]["models"][0]["cost"]; c.update(input=7.0, cacheRead=0.5, output=9.0); json.dump(d, open(sys.argv[2], "w"))' \
    "$SR/dotfiles/claude/speckit/pi-models.json" "$common/sdd/aaa111/pi-models.json"
  cat > "$common/sdd/aaa111/usage.jsonl" << 'JSONL'
{"run":"aaa111","event":"start","phase":"plan","model":"claude-opus-5-5","effort":"medium"}
{"run":"aaa111","event":"end","phase":"plan","model":"claude-opus-5-5","effort":"medium","usage":{"total_cost_usd":0.25,"modelUsage":{}},"exit":0}
{"run":"aaa111","event":"start","phase":"plan","model":"claude-opus-5-5","effort":"medium"}
{"run":"aaa111","event":"end","phase":"plan","model":"claude-opus-5-5","effort":"medium","usage":{"total_cost_usd":0.5,"modelUsage":{}},"exit":1}
{"run":"aaa111","event":"start","phase":"review","model":"claude-opus-5-5","effort":"medium"}
{"run":"aaa111","event":"start","phase":"implement-deepseek","model":"deepseek-flash","effort":"high"}
{"run":"aaa111","event":"end","phase":"implement-deepseek","model":"deepseek-flash","effort":"high","usage":{"input":1000000,"cached":2000000,"output":500000},"exit":0}
{"run":"aaa111","event":"start","phase":"tasks","model":"claude-sonnet-5-5","effort":"medium"}
{"run":"aaa111","event":"end","phase":"tasks","model":"claude-sonnet-5-5","effort":"medium","exit":0}
JSONL
  printf '{"run":"bbb222","event":"start","phase":"plan","model":"claude-opus-5-5","effort":"medium"}\n{"run":"bbb222","event":"end","phase":"plan","model":"claude-opus-5-5","effort":"medium","usage":{"total_cost_usd":9,"modelUsage":{}},"exit":0}\n' > "$common/sdd/bbb222/usage.jsonl"
  out=$(sr usage aaa111) || fail "usage: failed: $out"
  # DeepSeek's price from the run's pi-models.json: input, cache read and output per
  # million tokens.
  local want_ds
  want_ds=$(/usr/bin/python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1]))["providers"]["deepseek"]["models"][0]["cost"]; print("%.4f" % (c["input"] + 2*c["cacheRead"] + 0.5*c["output"]))' "$common/sdd/aaa111/pi-models.json")
  printf '%s\n' "$out" | grep -qE "^claude-opus-5-5 +2 attempts +[\$]0\.7500\$" || fail "usage: opus is not 2 attempts at \$0.7500: $out"
  printf '%s\n' "$out" | grep -qE "^deepseek-flash +1 attempt +\\\$$want_ds" || fail "usage: deepseek is not priced \$$want_ds from models.json: $out"
  printf '%s\n' "$out" | grep -qE '^unreported +2 attempts' || fail "usage: the two attempts that reported nothing are not listed: $out"
  if ! printf '%s\n' "$out" | grep -qF "review" || ! printf '%s\n' "$out" | grep -qF "tasks"; then
    fail "usage: the unreported attempts are not named: $out"
  fi
  local total
  total=$(/usr/bin/python3 -I -c 'import sys; print("%.4f" % (0.75 + float(sys.argv[1])))' "$want_ds")
  printf '%s\n' "$out" | grep -qE "^total +\\\$$total" || fail "usage: the total is not \$$total: $out"
  return "$status"
}
check "sdd-run usage sums each model's attempts for the named run, prices DeepSeek from models.json, and lists what reported nothing" sdd_run_usage
