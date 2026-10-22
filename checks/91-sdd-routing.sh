# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# covers: bin/sdd-step.sh bin/sdd-pass.py bin/sdd-egress-proxy.py claude/speckit/*
# covers: containers/worker/* checks/sdd/bundle.py checks/sdd/schema-cases.py checks/sdd/standins/*

# ── Routed Spec Kit ──────────────────────────────────────────────────────────
printf '\n%sRouted Spec Kit%s\n' "$DIM" "$OFF"

# Every schema accepts its sample and refuses the three variants
# checks/sdd/schema-cases.py derives from it: a required field dropped, an
# unknown field added, an enum (or const) field given a value outside it.
sdd_schemas() {
  local tmp name case status=0 schema
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  python3 -I checks/sdd/schema-cases.py "$tmp" || return 1
  for name in routing-table routing-layer route routing phases clarify implement verify review converge; do
    schema=claude/speckit/schemas/$name.schema.json
    [ -f "$schema" ] || {
      echo "$name: no $schema"
      status=1
      continue
    }
    check-jsonschema --schemafile "$schema" "$tmp/$name.valid.json" > /dev/null 2>&1 || {
      echo "$name: refused its valid sample"
      status=1
    }
    for case in missing extra enum; do
      if check-jsonschema --schemafile "$schema" "$tmp/$name.$case.json" > /dev/null 2>&1; then
        echo "$name: accepted the $case variant"
        status=1
      fi
    done
  done
  return "$status"
}
if command -v check-jsonschema > /dev/null 2>&1; then
  check "every routing schema accepts its sample and refuses a missing field, an extra field and a wrong enum" sdd_schemas
else
  skip "every routing schema accepts its sample and refuses a missing field, an extra field and a wrong enum" check-jsonschema
fi

# sdd-step outcome prints the fixed token each branch of the workflow compares,
# from the outcome file of the feature .specify/feature.json names, and fails
# on a file that is missing or that its schema refuses (FR-016).
sdd_outcome() {
  local tmp f status=0
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  f=specs/001-probe
  mkdir -p "$tmp/.specify" "$tmp/$f/.sdd" "$tmp/run"
  # Every subcommand finds its tools through the run bundle (contracts/pass.md).
  printf '{"check-jsonschema":"%s"}\n' "$(command -v check-jsonschema)" > "$tmp/run/tools.json"
  printf '{"feature_directory":"%s"}\n' "$f" > "$tmp/.specify/feature.json"
  local step=$PWD/bin/sdd-step.sh
  put() { # step json-fields
    printf '{"schema":"urn:dotfiles:sdd:%s:1","step":"%s","at":"2026-10-21T14:00:00Z",%s}\n' \
      "$1" "$1" "$2" > "$tmp/$f/.sdd/$1.json"
  }
  expect() { # step want why
    local got
    got=$(cd "$tmp" && SDD_RUN_DIR=$tmp/run "$step" outcome "$1" 2> /dev/null) || got="<exit $?>"
    [ "$got" = "$2" ] || {
      echo "$1, $3: printed '$got', wanted '$2'"
      status=1
    }
  }
  refuses() { # step why
    if (cd "$tmp" && SDD_RUN_DIR=$tmp/run "$step" outcome "$1" > /dev/null 2>&1); then
      echo "$1, $2: exited 0"
      status=1
    fi
  }
  local high='{"severity":"HIGH","text":"x"}' medium='{"severity":"MEDIUM","text":"x"}' low='{"severity":"LOW","text":"x"}'

  refuses clarify "no file"
  put clarify '"questions":3'
  expect clarify yes "three questions"
  put clarify '"questions":0'
  expect clarify no "no question"
  put clarify '"questions":0,"extra":1'
  refuses clarify "a field the schema does not know"
  put verify '"command":"./check.sh","exit":0,"tail":"","check_changes":[],"automation_changes":[]'
  expect verify pass "exit 0"
  put verify '"command":"./check.sh","exit":2,"tail":"","check_changes":[],"automation_changes":[]'
  expect verify fail "exit 2"
  put review "\"findings\":[$low,$high],\"done\":[]"
  expect review blocking "a HIGH finding"
  put review "\"findings\":[$low],\"done\":[\"T001\"]"
  expect review clear "only LOW findings"
  put converge "\"outcome\":\"converged\",\"findings\":[$low]"
  expect converge converged "converged with only LOW findings"
  put converge "\"outcome\":\"converged\",\"findings\":[$medium]"
  expect converge open "converged but a MEDIUM finding"
  put converge '"outcome":"tasks_appended","findings":[]'
  expect converge open "tasks appended"
  put converge '"outcome":"converged"'
  refuses converge "no findings field"
  refuses route "a step with no token to print"
  # A directory that exists and holds a valid file, so only the path's shape
  # can refuse it.
  mkdir -p "$tmp/elsewhere/.sdd"
  put clarify '"questions":1'
  cp "$tmp/$f/.sdd/clarify.json" "$tmp/elsewhere/.sdd/"
  printf '{"feature_directory":"elsewhere"}\n' > "$tmp/.specify/feature.json"
  refuses clarify "a feature directory outside specs/"
  return "$status"
}
if command -v check-jsonschema > /dev/null 2>&1; then
  check "sdd-step outcome prints each step's token and refuses a missing or invalid file" sdd_outcome
else
  skip "sdd-step outcome prints each step's token and refuses a missing or invalid file" check-jsonschema
fi

# The contained pass (contracts/pass.md, FR-028, research R20, R21), run end to
# end through `sdd-step agent` and `sdd-step verify` against the stand-ins in
# checks/sdd/standins: a container runtime that runs the command in the export
# instead of a VM, agents that apply a fixture's edits, and a Keychain holding
# fake credentials. Each case builds a fresh repository and bundle
# (checks/sdd/bundle.py). Every case also runs with a PATH whose first entry
# holds a git, a python3, a tar and a mise that would leave a mark, and with the
# repository's own hooks and fsmonitor set to leave one: a host step that
# found a tool through PATH, or ran repository configuration, shows.
sdd_pass() {
  local tmp status=0
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  local dotfiles=$PWD step=$PWD/bin/sdd-step.sh
  local claude_secret=sk-ant-oat01-FAKEclaudeTOKEN0123456789 deepseek_secret=sk-FAKEdeepseekKEY0123456789
  local repo run sa f=specs/001-probe out

  fresh() {
    rm -rf "$tmp/case" && mkdir -p "$tmp/case" || return 1
    local c=$tmp/case
    repo=$c/repo sa=$c/standins
    cp -R "$dotfiles/checks/sdd/standins" "$sa"
    # One stand-in answers for both agents, linked here rather than in git.
    ln -s agent "$sa/claude" && ln -s agent "$sa/pi"
    mkdir -p "$sa/secrets" "$sa/fixture" "$c/evil"
    printf '%s' "$claude_secret" > "$sa/secrets/claude-oauth"
    printf '%s' "$deepseek_secret" > "$sa/secrets/deepseek-api"
    local tool
    for tool in git python3 python tar mise check-jsonschema; do
      printf '#!/bin/sh\ntouch %s/pwned-%s\nexit 1\n' "$c" "$tool" > "$c/evil/$tool"
      chmod +x "$c/evil/$tool"
    done
    mkdir -p "$repo/.specify" "$repo/$f" "$repo/src" "$repo/githooks"
    (
      cd "$repo" || exit 1
      git init -q -b main
      printf '{"feature_directory":"%s"}\n' "$f" > .specify/feature.json
      printf '# Spec\n' > "$f/spec.md"
      printf -- '- [ ] T001 do it\n' > "$f/tasks.md"
      printf 'print(1)\n' > src/app.py
      printf '[lint]\nselect = ["E"]\n' > ruff.toml
      printf '#!/bin/sh\necho checking; exit 0\n' > check-app.sh
      chmod +x check-app.sh
      printf '#!/bin/sh\ntouch %s/pwned-hook\n' "$c" > githooks/pre-commit
      chmod +x githooks/pre-commit
      printf '[tools]\npython = "3.12"\n' > mise.toml
      git add -A && git -c user.name=t -c user.email=t@t commit -qm base
      git config core.hooksPath githooks
      git config core.fsmonitor "$c/evil/mise"
      git config user.name owner && git config user.email owner@example.com
    ) || return 1
    run=$(python3 -I "$dotfiles/checks/sdd/bundle.py" "$c" "$dotfiles") || return 1
    printf '{"run_id":"run1","pid":%s,"started":"2026-10-21T14:00:00Z","base":"%s"}\n' \
      "$$" "$(tgit rev-parse HEAD)" > "$run/lock.json"
  }
  # The agent's result: text, and structured output when given.
  result() {
    printf '{"type":"result","is_error":false,"result":"%s","structured_output":%s,"permission_denials":[],"total_cost_usd":0.01,"modelUsage":{"claude-opus-5-5":{"inputTokens":10}}}\n' \
      "$1" "${2:-null}" > "$sa/fixture/result.json"
  }
  edit() { # path content
    mkdir -p "$sa/fixture/edits/$(dirname "$1")"
    printf '%s' "$2" > "$sa/fixture/edits/$1"
  }
  pass() { # subcommand args...: runs it as the workflow would, from the repository root
    (cd "$repo" && HOME="${PASS_HOME:-$HOME}" PATH="$tmp/case/evil:$PATH" SDD_RUN_DIR=$run "$step" "$@" 2>&1)
  }
  fail() {
    echo "$1"
    status=1
  }
  # The check's own git, with the repository's planted hooks and fsmonitor off,
  # so only a host step of the pass can leave their marks.
  tgit() { git -C "$repo" -c core.fsmonitor=false -c core.hooksPath=/dev/null "$@"; }
  commits() { tgit rev-list --count HEAD; }
  # Copies the admissions present while the agent runs, so a case can see
  # what the proxy would have admitted this pass to.
  watch_admissions() {
    mkdir -p "$tmp/case/seen"
    printf 'cp "%s"/admissions/*.json "%s/seen/"\n' "$run" "$tmp/case" >> "$sa/fixture/script"
  }
  # Copies what the pass mounted at /bundle/proxy-ca.pem, from inside the
  # container stand-in, to seen-ca.pem.
  watch_ca() {
    {
      printf 'seen=%s/seen-ca.pem\n' "$tmp/case"
      cat << 'SH'
for m in $(echo "$SDD_STANDIN_MOUNTS" | tr ";" " "); do
  case $m in *:/bundle:ro) cp "${m%%:*}/proxy-ca.pem" "$seen" ;; esac
done
SH
    } >> "$sa/fixture/script"
  }
  admitted() { # want...: the admissions seen are exactly one, admitting these
    /usr/bin/python3 -I - "$tmp/case/seen" "$@" << 'PY'
import glob, json, sys
seen = glob.glob(sys.argv[1] + "/*.json")
if len(seen) != 1:
    sys.exit(f"{len(seen)} admissions while the agent ran, wanted one")
got = json.load(open(seen[0]))["admit"]
if sorted(got) != sorted(sys.argv[2:]):
    sys.exit(f"admitted {got}, wanted {sys.argv[2:]}")
PY
  }
  clean_after() { # case: no exports left, no pwned marks
    [ -z "$(ls -A "$run/passes" 2> /dev/null)" ] || fail "$1: left $(ls "$run/passes") in the bundle"
    [ -z "$(ls -A "$run/admissions" 2> /dev/null)" ] || fail "$1: left an admission behind"
    local mark
    for mark in "$tmp"/case/pwned-*; do
      [ -e "$mark" ] && fail "$1: a host step ran $(basename "$mark" | sed 's/^pwned-//') from PATH or repository configuration"
    done
    grep -qF -e "$claude_secret" -e "$deepseek_secret" "$sa/agents.jsonl" "$sa/calls.jsonl" 2> /dev/null &&
      fail "$1: a credential reached the container runtime or an agent"
    return 0
  }

  # 1. A plan pass writing what its row allows: exported, judged, applied, one commit.
  fresh || return 1
  result "planned"
  edit "$f/plan.md" "# Plan"
  watch_admissions
  watch_ca
  local before
  before=$(commits)
  out=$(pass agent plan) || fail "allowed: failed: $out"
  [ "$(cat "$repo/$f/plan.md" 2> /dev/null)" = "# Plan" ] || fail "allowed: plan.md not applied"
  [ "$(commits)" -eq $((before + 1)) ] || fail "allowed: $(($(commits) - before)) commits, wanted one"
  tgit log -1 --format=%s | grep -qx "plan: 001-probe (claude-opus-5-5)" ||
    fail "allowed: commit subject '$(tgit log -1 --format=%s)'"
  tgit diff --quiet HEAD || fail "allowed: the worktree differs from the commit"
  # The export: tracked files only, no .git, mounted alone at /work.
  /usr/bin/python3 -I - "$sa/agents.jsonl" "$sa/calls.jsonl" << 'PY' || status=1
import json, sys
agent = [json.loads(l) for l in open(sys.argv[1])][-1]
runs = [c for c in map(json.loads, open(sys.argv[2])) if c[:2] == ["container", "run"]]
mounts = dict(m.split(":")[1:2] + [m.split(":")[0]] for m in agent["env"]["SDD_STANDIN_MOUNTS"].split(";") if m)
bad = []
argv = agent["argv"]
for flag, want in [("--model", "claude-opus-5-5"), ("--effort", "medium"), ("--permission-mode", "dontAsk"),
                   ("--permission-prompts", "none"), ("--setting-sources", "project"),
                   ("--settings", "/bundle/profile.json"), ("--output-format", "json")]:
    if flag not in argv or argv[argv.index(flag) + 1] != want:
        bad.append(f"allowed: claude not given {flag} {want}: {argv}")
if "--strict-mcp-config" not in argv:
    bad.append("allowed: claude not given --strict-mcp-config")
if not argv or not argv[1].startswith("/speckit-plan"):
    bad.append(f"allowed: prompt is not the row's: {argv[:2]}")
run = runs[-1]
if "--cap-add" not in run or "--network" not in run or run[run.index("--network") + 1] != "sdd-run1":
    bad.append(f"allowed: container not on the run's network with the firewall capability: {run}")
if set(mounts) - {"/work", "/bundle", "/input"}:
    bad.append(f"allowed: mounted more than the export and inputs: {sorted(mounts)}")
for m in run:
    if m.endswith(":/bundle") or (":/bundle" in m and not m.endswith(":ro")):
        bad.append(f"allowed: inputs not read-only: {m}")
if bad:
    print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
  out=$(admitted anthropic 2>&1) || fail "allowed: $out"
  cmp -s "$tmp/case/seen-ca.pem" "$run/proxy-ca.pem" || fail "allowed: /bundle/proxy-ca.pem is not the run's authority"
  /usr/bin/python3 -I -c '
import json, re, sys
env = [json.loads(l) for l in open(sys.argv[1])][-1]["env"]
tok = env.get("CLAUDE_CODE_OAUTH_TOKEN", "")
sys.exit(0 if re.fullmatch(r"sdd-pass-[A-Za-z0-9_-]{16,119}", tok) and env.get("SDD_PASS_TOKEN") == tok
         and env.get("ANTHROPIC_BASE_URL") == "http://192.0.2.10:8080" else f"allowed: placeholder or base URL wrong: {tok!r}")
' "$sa/agents.jsonl" || status=1
  clean_after allowed

  # 2. A write outside the row's list stops the pass, naming the path; nothing applied.
  fresh || return 1
  result "planned"
  edit "$f/plan.md" "# Plan"
  edit src/app.py "print(2)"
  before=$(commits)
  if out=$(pass agent plan); then fail "outside writes: succeeded"; fi
  printf '%s' "$out" | grep -qF "src/app.py" || fail "outside writes: did not name src/app.py: $out"
  [ "$(commits)" -eq "$before" ] && [ ! -e "$repo/$f/plan.md" ] || fail "outside writes: something was applied"
  clean_after "outside writes"

  # 3. The protected set, for an implement row, at any depth.
  local protected
  for protected in .claude/settings.json docs/CLAUDE.md .gitattributes .specify/feature.json "$f/.sdd/review.json" AGENTS.md .mcp.json; do
    fresh || return 1
    printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd-route.tmp"
    mkdir -p "$repo/$f/.sdd" && mv "$repo/$f/.sdd-route.tmp" "$repo/$f/.sdd/route.json"
    result "implemented"
    edit "$protected" "planted"
    if out=$(pass implement); then fail "protected $protected: succeeded"; fi
    printf '%s' "$out" | grep -qF "$protected" || fail "protected $protected: not named: $out"
    clean_after "protected $protected"
  done

  # 4. config-guard: emptying ruff.toml is an `ask`, which stops the pass.
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  result "implemented"
  edit ruff.toml ""
  if out=$(pass implement); then fail "config-guard ask: succeeded"; fi
  printf '%s' "$out" | grep -qF "ruff.toml" || fail "config-guard ask: did not name ruff.toml: $out"
  clean_after "config-guard ask"

  # 5. A judge that cannot run fails the pass closed.
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  rm "$run/hooks/config-guard.sh"
  result "implemented"
  edit src/app.py "print(2)"
  if out=$(pass implement); then fail "judge missing: succeeded without config-guard"; fi
  [ "$(cat "$repo/src/app.py")" = "print(1)" ] || fail "judge missing: applied"
  clean_after "judge missing"

  # 6. A new symlink stops the pass. A file made executable is applied, and
  # verify then lists it among the automation changes (FR-030). git records
  # only the executable bit, so no other mode can reach a patch.
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  result "implemented"
  printf 'ln -s /etc/passwd src/link\n' > "$sa/fixture/script"
  if out=$(pass implement); then fail "symlink: succeeded"; fi
  printf '%s' "$out" | grep -qF "src/link" || fail "symlink: path not named: $out"
  clean_after symlink
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  result "implemented"
  printf 'chmod 755 src/app.py\n' > "$sa/fixture/script"
  out=$(pass implement) || fail "executable: failed: $out"
  [ -x "$repo/src/app.py" ] || fail "executable: the mode was not applied"
  rm -f "$sa/fixture/script"
  out=$(pass verify) || fail "executable: verify failed: $out"
  /usr/bin/python3 -I -c 'import json,sys; sys.exit("src/app.py" not in json.load(open(sys.argv[1]))["automation_changes"])' \
    "$repo/$f/.sdd/verify.json" || fail "executable: verify.json does not list src/app.py among automation changes"
  clean_after executable

  # 7. A credential's exact value in the patch or in structured output stops the
  # pass, naming the credential and never showing it.
  local where
  for where in patch structured; do
    fresh || return 1
    case $where in
      patch)
        result "planned"
        edit "$f/plan.md" "token $claude_secret"
        out=$(pass agent plan) && fail "secret in $where: succeeded"
        ;;
      structured)
        result "reviewed" "{\"findings\":[{\"severity\":\"LOW\",\"text\":\"$claude_secret\"}],\"done\":[]}"
        out=$(pass agent review) && fail "secret in $where: succeeded"
        ;;
    esac
    printf '%s' "$out" | grep -qF claude-oauth || fail "secret in $where: credential not named: $out"
    grep -qF "$claude_secret" <<< "$out" && fail "secret in $where: the value was shown"
    [ ! -e "$repo/$f/plan.md" ] && [ ! -e "$repo/$f/.sdd/review.json" ] || fail "secret in $where: something was written"
    clean_after "secret in $where"
  done

  # 7b. The review reads the feature's whole change since the feature began —
  # not only this run's, which `sdd-run start --from` begins after an earlier
  # run implemented it — and not the run's own records under .sdd/ (the real
  # run, 2026-10-21: the reviewer saw only metadata and marked nothing done).
  fresh || return 1
  # Unrelated work interleaved with the feature's own stays out of it.
  printf 'other\n' > "$repo/src/other.py" && tgit add src/other.py && tgit commit -qm "unrelated work"
  printf 'print(2)\n' > "$repo/src/app.py" && tgit commit -qam "implement: 001-probe (claude-sonnet-5-5)"
  printf 'later\n' > "$repo/src/later.py" && tgit add src/later.py && tgit commit -qm "more unrelated work"
  printf '{"run_id":"run1","pid":%s,"started":"x","base":"%s"}\n' "$$" "$(tgit rev-parse HEAD)" > "$run/lock.json"
  mkdir -p "$repo/$f/.sdd" && printf '{}\n' > "$repo/$f/.sdd/route.json"
  # Inside the agent, the stand-in's mounts name where /input is.
  {
    printf 'seen=%s/seen-diff.patch\n' "$tmp/case"
    cat << 'SH'
for m in $(echo "$SDD_STANDIN_MOUNTS" | tr ";" " "); do
  case $m in *:/input:ro) cp "${m%%:*}/diff.patch" "$seen" ;; esac
done
SH
  } > "$sa/fixture/script"
  result "reviewed" '{"findings":[],"done":["T001"]}'
  out=$(pass agent review) || fail "review diff: failed: $out"
  grep -qF "+print(2)" "$tmp/case/seen-diff.patch" 2> /dev/null || fail "review diff: the feature's implementation before this run is not in it"
  grep -qF ".sdd/" "$tmp/case/seen-diff.patch" 2> /dev/null && fail "review diff: the run's own .sdd records are in it"
  grep -qE "src/(other|later)\.py" "$tmp/case/seen-diff.patch" 2> /dev/null && fail "review diff: unrelated commits are in it"
  clean_after "review diff"
  # 8. Results: structured output to the row's outcome file with the common
  # fields, the result's text to result_to, a start and an end usage line.
  fresh || return 1
  result "reviewed" '{"findings":[{"severity":"LOW","text":"fine"}],"done":["T001"]}'
  out=$(pass agent review) || fail "review results: failed: $out"
  (cd "$repo" && SDD_RUN_DIR=$run "$step" outcome review 2> /dev/null) | grep -qx clear ||
    fail "review results: .sdd/review.json missing or invalid"
  fresh || return 1
  result "the analysis"
  out=$(pass agent analyze) || fail "analyze results: failed: $out"
  [ "$(cat "$repo/$f/analysis.md" 2> /dev/null)" = "the analysis" ] || fail "analyze results: analysis.md not the result's text"
  [ "$(grep -c '"event": *"start"' "$run/usage.jsonl" 2> /dev/null)" -eq 1 ] &&
    [ "$(grep -c '"event": *"end"' "$run/usage.jsonl" 2> /dev/null)" -eq 1 ] ||
    fail "analyze results: usage.jsonl lacks one start and one end line"
  clean_after "results"

  # 9. An agent past its row's timeout: the container stopped, nothing applied.
  fresh || return 1
  /usr/bin/python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["phases"]["plan"]["timeout"]["value"]=2; json.dump(d,open(p,"w"))' "$run/routing.json"
  echo 20 > "$sa/fixture/sleep"
  printf 'still planning\n' > "$sa/fixture/say"
  result "planned"
  edit "$f/plan.md" "# Plan"
  if out=$(pass agent plan); then fail "timeout: succeeded"; fi
  grep -q '"stop"' "$sa/calls.jsonl" || fail "timeout: the container was not stopped"
  [ ! -e "$repo/$f/plan.md" ] || fail "timeout: applied"
  # What the agent said before it was stopped stays in results/ (the US1
  # review's second round, 2026-10-22).
  grep -rqF "still planning" "$run/results" 2> /dev/null || fail "timeout: what the agent said is not kept in results/"
  clean_after "timeout"

  # 10a. An answer that is no JSON result still lands in results/, where the
  # owner looks first.
  fresh || return 1
  printf 'the agent printed this instead of JSON\n' > "$sa/fixture/result.json"
  if out=$(pass agent plan); then fail "no JSON: succeeded"; fi
  grep -rqF "the agent printed this instead of JSON" "$run/results" 2> /dev/null || fail "no JSON: the answer is not kept in results/"
  clean_after "no JSON"
  # 10. An agent error, or a denied tool, fails the step naming the cause.
  fresh || return 1
  printf '{"type":"result","is_error":false,"result":"x","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"mkdir -p specs/002-x"}}]}\n' > "$sa/fixture/result.json"
  if out=$(pass agent plan); then fail "denial: succeeded"; fi
  printf '%s' "$out" | grep -qi "denied\|denial" || fail "denial: cause not named: $out"
  # The command itself, so the owner can tell a profile gap from an agent
  # overreaching (seen in the first real run, 2026-10-21).
  printf '%s' "$out" | grep -qF "mkdir -p specs/002-x" || fail "denial: the denied command is not named: $out"
  clean_after "denial"

  # 11. Verify: the frozen check command in the container with the verify
  # cache, no patch and no commit; its result in verify.json.
  fresh || return 1
  {
    printf '#!/bin/sh\necho checking; cp "%s"/admissions/*.json "%s/seen/"\nseen=%s/seen-ca.pem\n' "$run" "$tmp/case" "$tmp/case"
    cat << 'SH'
for m in $(echo "$SDD_STANDIN_MOUNTS" | tr ";" " "); do
  case $m in *:/bundle:ro) cp "${m%%:*}/proxy-ca.pem" "$seen" ;; esac
done
echo changed > src/app.py
exit 3
SH
  } > "$repo/check-app.sh"
  mkdir -p "$tmp/case/seen"
  tgit commit -qam "failing check"
  before=$(commits)
  out=$(pass verify) || fail "verify: exited non-zero: $out"
  printf '%s' "$out" | grep -qx fail || fail "verify: did not print fail: $out"
  [ "$(commits)" -eq "$before" ] && [ "$(cat "$repo/src/app.py")" = "print(1)" ] || fail "verify: changed the repository"
  (cd "$repo" && SDD_RUN_DIR=$run "$step" outcome verify 2> /dev/null) | grep -qx fail || fail "verify: verify.json missing or wrong"
  grep -F '"run"' "$sa/calls.jsonl" | grep -qF "sdd-cache-verify-run1" || fail "verify: not on the verify cache volume"
  out=$(admitted registries 2>&1) || fail "verify: $out"
  cmp -s "$tmp/case/seen-ca.pem" "$run/proxy-ca.pem" || fail "verify: /bundle/proxy-ca.pem is not the run's authority"
  clean_after verify

  # 12. Implement runs on the implement cache, never the verify one.
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  result "implemented"
  edit src/app.py "print(2)"
  watch_admissions
  printf 'BRIEF FROZEN IN THE BUNDLE\n' > "$run/brief.md"
  out=$(pass implement) || fail "implement: failed: $out"
  out=$(admitted anthropic registries 2>&1) || fail "implement: $out"
  [ "$(cat "$repo/src/app.py")" = "print(2)" ] || fail "implement: not applied"
  grep -F '"run"' "$sa/calls.jsonl" | grep -qF "sdd-cache-implement-run1" || fail "implement: not on the implement cache volume"
  local runs
  runs=$(grep -F '"run"' "$sa/calls.jsonl")
  grep -qF "sdd-cache-verify-run1" <<< "$runs" && fail "implement: mounted the verify cache"
  # The brief comes from the bundle, frozen at start like everything else
  # that governs the run — never read live from dotfiles.
  # It goes to the system prompt; the user prompt is Spec Kit's command alone,
  # so the procedure lives in one place (the skill) and the run's context in
  # another (the brief).
  /usr/bin/python3 -I -c '
import json, sys
argv = [json.loads(l) for l in open(sys.argv[1])][-1]["argv"]
bad = []
if "--append-system-prompt" not in argv or "BRIEF FROZEN IN THE BUNDLE" not in argv[argv.index("--append-system-prompt") + 1]:
    bad.append("implement: the bundle brief is not appended to the system prompt")
if argv[argv.index("-p") + 1] != "/speckit-implement specs/001-probe":
    bad.append("implement: the prompt is not the Spec Kit command alone: %r" % argv[argv.index("-p") + 1][:80])
sys.exit("\n".join(bad) or 0)
' "$sa/agents.jsonl" || status=1
  clean_after implement

  # 12a. Only the run marks tasks (FR-006): checkbox changes in tasks.md by
  # an implement pass are taken back, named, and the rest of the patch goes
  # on; a pass that only ticked boxes changed nothing. (Spec Kit's implement
  # tells its agent to mark tasks; the brief says not to; the judge decides.)
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  result "implemented and marked"
  edit "$f/tasks.md" "- [X] T001 do it
"
  edit src/app.py "print(9)"
  out=$(pass implement) || fail "ticks: failed: $out"
  [ "$(cat "$repo/src/app.py")" = "print(9)" ] || fail "ticks: the rest of the patch was not applied"
  grep -qxF -- "- [ ] T001 do it" "$repo/$f/tasks.md" || fail "ticks: the implementer's tick reached tasks.md: $(cat "$repo/$f/tasks.md")"
  printf '%s' "$out" | grep -qF "tasks.md" || fail "ticks: the taken-back ticks are not named: $out"
  clean_after ticks
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  result "only marked"
  edit "$f/tasks.md" "- [x] T001 do it
"
  if out=$(pass implement); then fail "tick only: a first implementation that only ticked boxes succeeded"; fi
  clean_after "tick only"

  # 12b. An implementer that changes nothing while tasks remain open has
  # failed, whatever it says; what it said is shown and kept in the bundle,
  # as every agent's answer is (seen in the real run, 2026-10-21: three
  # rounds of nothing, with nobody able to see why).
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  result "STOPPED: some checklists are incomplete, proceed?"
  if out=$(pass implement); then fail "no-op implement: succeeded with tasks open"; fi
  printf '%s' "$out" | grep -qF "STOPPED: some checklists are incomplete" || fail "no-op implement: the agent's answer is not shown: $out"
  grep -rqF "STOPPED: some checklists are incomplete" "$run/results" 2> /dev/null || fail "no-op implement: the agent's answer is not kept in the bundle"
  clean_after "no-op implement"
  # A feature implemented by an earlier run (sdd-run start --from) has been
  # implemented: a first pass of this run finding nothing to change is valid
  # (the real run, 2026-10-21).
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  printf 'print(2)\n' > "$repo/src/app.py" && tgit commit -qam "implement: 001-probe (claude-sonnet-5-5)"
  printf '{"run_id":"run1","pid":%s,"started":"x","base":"%s"}\n' "$$" "$(tgit rev-parse HEAD)" > "$run/lock.json"
  result "everything is already implemented"
  out=$(pass implement) || fail "no-op after an earlier run implemented it: refused: $out"
  clean_after "no-op, implemented by an earlier run"
  # After an implementation, a fix round (verify failed) that changes nothing
  # fails too; with verify passing, nothing left to change is a valid answer.
  local verdict
  for verdict in 1 0; do
    fresh || return 1
    mkdir -p "$repo/$f/.sdd"
    printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
    printf 'print(2)\n' > "$repo/src/app.py" && tgit commit -qam "implement: 001-probe (claude-sonnet-5-5)"
    printf '{"schema":"urn:dotfiles:sdd:verify:1","step":"verify","at":"2026-10-21T14:00:00Z","command":"./check-app.sh","exit":%s,"tail":"","check_changes":[],"automation_changes":[]}\n' "$verdict" > "$repo/$f/.sdd/verify.json"
    result "nothing more to change"
    if [ "$verdict" = 1 ]; then
      if out=$(pass implement); then fail "no-op fix round: succeeded"; fi
      printf '%s' "$out" | grep -qF "a fix round" || fail "no-op fix round: not named as one: $out"
    else
      out=$(pass implement) || fail "no-op after a passing verify: refused: $out"
    fi
    clean_after "no-op, verify exit $verdict"
  done

  # 13. Implement on DeepSeek, opted in at start and now: pi gets the worker's
  # models.json pointed at the proxy with the placeholder as its key, and the
  # pass is admitted to DeepSeek and the registries, not to Anthropic.
  fresh || return 1
  mkdir -p "$repo/$f/.sdd"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"deepseek"}\n' > "$repo/$f/.sdd/route.json"
  tgit config sdd.implement deepseek
  # pi's models come from the bundle, frozen at start (its prices too).
  /usr/bin/python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["providers"]["deepseek"]["models"][0]["name"]="FROZEN-IN-BUNDLE"; json.dump(d,open(p,"w"))' "$run/pi-models.json"
  # Two responses in one pass: pi reports each message_end's own usage (pi
  # 1.3.0 docs/json.md), so the pass's usage is their sum.
  printf '%s\n' '{"type":"message_end","message":{"role":"assistant","model":"deepseek-flash","content":[{"type":"text","text":"reading"}],"usage":{"input":10,"cacheRead":5,"output":3}}}' \
    '{"type":"message_end","message":{"role":"user","content":"tool result"}}' \
    '{"type":"message_end","message":{"role":"assistant","model":"deepseek-flash","content":[{"type":"text","text":"done"}],"usage":{"input":20,"cacheRead":1,"output":4}}}' > "$sa/fixture/result.json"
  edit src/app.py "print(3)"
  watch_admissions
  # Inside the agent, the stand-in's mounts name where /bundle is.
  {
    printf 'seen=%s/seen-models.json\n' "$tmp/case"
    cat << 'SH'
for m in $(echo "$SDD_STANDIN_MOUNTS" | tr ";" " "); do
  case $m in *:/bundle:ro) cp "${m%%:*}/models.json" "$seen" ;; esac
done
SH
  } >> "$sa/fixture/script"
  out=$(pass implement) || fail "deepseek: failed: $out"
  [ "$(cat "$repo/src/app.py")" = "print(3)" ] || fail "deepseek: not applied"
  out=$(admitted deepseek registries 2>&1) || fail "deepseek: $out"
  /usr/bin/python3 -I -c '
import json, sys
agent = [json.loads(l) for l in open(sys.argv[1])][-1]
m = json.load(open(sys.argv[2]))["providers"]["deepseek"]
tok = agent["env"].get("SDD_PASS_TOKEN")
name, argv, base, key = agent["agent"], agent["argv"], m["baseUrl"], m["apiKey"]
bad = []
# pi runs the Spec Kit implement command, in the pi spelling, alone; the
# brief goes to its system prompt.
if argv[-1] != "/speckit.implement specs/001-probe":
    bad.append("deepseek: pi was not given /speckit.implement alone: %r" % argv[-1][:80])
if "--append-system-prompt" not in argv or "Brief" not in argv[argv.index("--append-system-prompt") + 1]:
    bad.append("deepseek: the brief is not appended to the system prompt of pi")
if name != "pi" or "deepseek/deepseek-flash" not in argv:
    bad.append(f"deepseek: pi not run on deepseek/deepseek-flash: {name} {argv}")
if m["models"][0]["name"] != "FROZEN-IN-BUNDLE":
    bad.append("deepseek: the models.json pi got is not the bundle copy")
if base != "http://192.0.2.10:8080" or key != tok:
    bad.append(f"deepseek: models.json not pointed at the proxy with the placeholder: {base}")
if "CLAUDE_CODE_OAUTH_TOKEN" in agent["env"]:
    bad.append("deepseek: a Claude placeholder reached the pi pass")
sys.exit("\n".join(bad) or 0)
' "$sa/agents.jsonl" "$tmp/case/seen-models.json" || status=1
  /usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d["agent"]=="deepseek" and d["usage"]=={"input":30,"cached":6,"output":7} else f"deepseek: implement.json {d}")' \
    "$repo/$f/.sdd/implement.json" || status=1
  clean_after deepseek

  # Review of Phase 2 (2026-10-21): each case below got through before.
  sonnet_route() {
    mkdir -p "$repo/$f/.sdd"
    printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  }
  # 14. The protected set on a case-insensitive filesystem: any spelling APFS
  # folds onto a protected name is that name (a long s, U+017F, folds to s).
  local spelling
  for spelling in .Claude/settings.json src/Claude.md claude.local.md .MCP.json agents.md .GITATTRIBUTES $'.mcp.j\xc5\xbfon' \
    .pi/prompts/speckit.implement.md .Pi/settings.json; do
    fresh || return 1
    sonnet_route
    result "implemented"
    edit "$spelling" "planted"
    if out=$(pass implement); then fail "spelling $spelling: succeeded"; fi
    clean_after "spelling $spelling"
  done
  # 15. A judgment row's /** writes do not open the protected set.
  for spelling in "$f/contracts/CLAUDE.md" "$f/contracts/.claude/skills/x/SKILL.md" "$f/contracts/.gitattributes" "$f/contracts/AGENTS.md"; do
    fresh || return 1
    result "planned"
    edit "$spelling" "planted"
    if out=$(pass agent plan); then fail "judgment $spelling: succeeded"; fi
    clean_after "judgment $spelling"
  done
  # 16. A path that would land through an untracked symlink, or in an ignored
  # directory, of the owner's worktree is refused.
  fresh || return 1
  sonnet_route
  mkdir -p "$tmp/case/outside"
  ln -s ../outside "$repo/out"
  result "implemented"
  edit out/pwn "planted"
  if out=$(pass implement); then fail "worktree symlink: succeeded"; fi
  [ ! -e "$tmp/case/outside/pwn" ] || fail "worktree symlink: wrote outside the repository"
  clean_after "worktree symlink"
  fresh || return 1
  sonnet_route
  # What the repository ignores is not its content (git's own rule): a pass's
  # writes there — a cache its tests left, a planted .pth — are dropped, never
  # written into the worktree, and the rest of the patch goes on (the real
  # run, 2026-10-21: a review's test run left __pycache__ behind).
  printf '.venv/\n__pycache__/\n' > "$repo/.gitignore"
  tgit add .gitignore && tgit commit -qm ignore
  result "implemented"
  edit .venv/lib/evil.pth "import os"
  edit src/__pycache__/app.cpython-311.pyc "bytecode"
  edit src/app.py "print(7)"
  out=$(pass implement) || fail "ignored path: refused the whole patch: $out"
  [ ! -e "$repo/.venv/lib/evil.pth" ] && [ ! -e "$repo/src/__pycache__/app.cpython-311.pyc" ] || fail "ignored path: written"
  [ "$(cat "$repo/src/app.py")" = "print(7)" ] || fail "ignored path: the rest of the patch was not applied"
  printf '%s' "$out" | grep -qF ".venv/lib/evil.pth" || fail "ignored path: the dropped path is not named: $out"
  /usr/bin/python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ".venv/lib/evil.pth" in d.get("dropped", []) else "ignored path: implement.json does not record what was dropped: %s" % d.get("dropped"))' \
    "$repo/$f/.sdd/implement.json" || status=1
  clean_after "ignored path"
  # A reading phase whose test run left an ignored cache still writes nothing.
  fresh || return 1
  printf '__pycache__/\n' > "$repo/.gitignore"
  tgit add .gitignore && tgit commit -qm ignore
  result "reviewed" '{"findings":[],"done":[]}'
  edit src/__pycache__/app.cpython-311.pyc "bytecode"
  out=$(pass agent review) || fail "reader cache: refused: $out"
  clean_after "reader cache"
  # Only the repository's own ignore rules count: git also reads the owner's
  # ~/.config/git/ignore, which says nothing about this repository.
  fresh || return 1
  mkdir -p "$repo/$f/.sdd" "$tmp/case/home/.config/git"
  printf '{"schema":"urn:dotfiles:sdd:route:1","step":"route","at":"2026-10-21T14:00:00Z","agent":"sonnet"}\n' > "$repo/$f/.sdd/route.json"
  printf 'generated.py\n' > "$tmp/case/home/.config/git/ignore"
  result "implemented"
  edit src/generated.py "print(8)"
  out=$(PASS_HOME=$tmp/case/home pass implement) || fail "global excludes: failed: $out"
  [ "$(cat "$repo/src/generated.py" 2> /dev/null)" = "print(8)" ] || fail "global excludes: a file only the owner's own excludes match was dropped"
  clean_after "global excludes"
  # 17. The credential scan fails closed, and reads binary files as bytes.
  fresh || return 1
  mv "$sa/secrets/claude-oauth" "$sa/secrets/claude-oauth.gone"
  result "planned"
  edit "$f/plan.md" "# Plan"
  if out=$(pass agent plan); then fail "scan without the Keychain: succeeded"; fi
  clean_after "scan without the Keychain"
  fresh || return 1
  result "planned"
  mkdir -p "$sa/fixture/edits/$f/contracts"
  printf 'blob\0\1%s\0' "$claude_secret" > "$sa/fixture/edits/$f/contracts/raw.bin"
  if out=$(pass agent plan); then fail "binary secret: succeeded"; fi
  printf '%s' "$out" | grep -qF claude-oauth || fail "binary secret: credential not named: $out"
  clean_after "binary secret"
  # 18. A tracked top-level export/ directory is judged at its own path.
  fresh || return 1
  sonnet_route
  mkdir -p "$repo/export" && printf 'x\n' > "$repo/export/x"
  tgit add export && tgit commit -qm export
  result "implemented"
  edit export/x "y"
  out=$(pass implement) || fail "export/ dir: failed: $out"
  if [ "$(cat "$repo/export/x")" != y ] || [ -e "$repo/x" ]; then fail "export/ dir: applied at the wrong path"; fi
  clean_after "export/ dir"
  # 19. .gitkeep is not a git file that governs anything.
  fresh || return 1
  sonnet_route
  result "implemented"
  edit src/empty/.gitkeep ""
  out=$(pass implement) || fail ".gitkeep: refused: $out"
  clean_after ".gitkeep"
  # 20. Invalid structured output fails the step with nothing committed.
  fresh || return 1
  result "reviewed" '{"findings":[{"severity":"BAD","text":"x"}],"done":[]}'
  edit "$f/contracts/x.md" "x"
  /usr/bin/python3 -I -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d["phases"]["review"]["writes"]["value"]=["<f>/contracts/**"]; json.dump(d,open(p,"w"))' "$run/routing.json"
  before=$(commits)
  if out=$(pass agent review); then fail "invalid outcome: succeeded"; fi
  [ "$(commits)" -eq "$before" ] || fail "invalid outcome: committed"
  clean_after "invalid outcome"
  # 21. The owner's staged work is never swept into a pass's commit.
  fresh || return 1
  printf 'owner\n' > "$repo/owner.txt" && tgit add owner.txt
  result "planned"
  edit "$f/plan.md" "# Plan"
  # The commit the pass starts from: `base`, the fixture's commit message, is
  # no revision, and `base..HEAD` read as an empty history.
  local base history
  base=$(tgit rev-parse HEAD)
  out=$(pass agent plan)
  history=$(tgit log --name-only --format= "$base..HEAD")
  grep -qx owner.txt <<< "$history" && fail "staged: the owner's staged file went into a pass commit"
  history=$(tgit log --all --name-only --format=)
  grep -qx owner.txt <<< "$history" && fail "staged: the owner's staged file was committed"
  tgit diff --cached --name-only | grep -qx owner.txt || fail "staged: the owner's staged file is no longer staged"
  clean_after staged
  # 22. Repository diff configuration never runs on the host.
  fresh || return 1
  printf '#!/bin/sh\ntouch %s/pwned-diffext\n' "$tmp/case" > "$tmp/case/evil/diffext"
  chmod +x "$tmp/case/evil/diffext"
  tgit config diff.external "$tmp/case/evil/diffext"
  result "planned"
  edit "$f/plan.md" "# Plan"
  out=$(pass agent plan) || fail "diff.external: failed: $out"
  rm -rf "$sa/fixture/edits"
  result "reviewed" '{"findings":[],"done":[]}'
  out=$(pass agent review) || fail "diff.external review: failed: $out"
  clean_after "diff.external"
  # 23. Check changes (FR-029) are every path the check command names,
  # however it spells them, and automation (FR-030) includes the
  # repository's own hooks directory.
  fresh || return 1
  sonnet_route
  mkdir -p "$repo/ci" && printf '#!/bin/sh\nexit 0\n' > "$repo/ci/check-app.sh" && chmod 644 "$repo/ci/check-app.sh"
  tgit add ci && tgit commit -qm ci
  printf '{"command":"sh ./ci/check-app.sh --strict"}\n' > "$run/check.json"
  result "implemented"
  edit ci/check-app.sh "exit 0"
  edit githooks/post-merge "#!/bin/sh"
  out=$(pass implement) || fail "flags: failed: $out"
  out=$(pass verify) || fail "flags: verify failed: $out"
  /usr/bin/python3 -I -c '
import json, sys
d = json.load(open(sys.argv[1]))
bad = []
if d["check_changes"] != ["ci/check-app.sh"]:
    bad.append("flags: check_changes is %s, wanted ci/check-app.sh" % d["check_changes"])
if "githooks/post-merge" not in d["automation_changes"]:
    bad.append("flags: the hooks directory change is not an automation change: %s" % d["automation_changes"])
sys.exit("\n".join(bad) or 0)
' "$repo/$f/.sdd/verify.json" || status=1
  clean_after flags

  # Second review round (2026-10-21).
  # 24. implement.json is validated before anything is applied: an agent's
  # usage the schema refuses leaves no commit.
  fresh || return 1
  sonnet_route
  printf '{"type":"result","is_error":false,"result":"x","permission_denials":[],"total_cost_usd":-1,"modelUsage":{}}\n' > "$sa/fixture/result.json"
  edit src/app.py "print(5)"
  if out=$(pass implement); then fail "implement outcome: succeeded"; fi
  # The run's own "sdd: ... before implement" commit is expected; the pass's is not.
  history=$(tgit log --format=%s)
  grep -q '^implement:' <<< "$history" && fail "implement outcome: committed although implement.json was invalid"
  [ "$(cat "$repo/src/app.py")" = "print(1)" ] || fail "implement outcome: applied although implement.json was invalid"
  clean_after "implement outcome"
  # 25. A decomposed (NFD) name reaches the index precomposed, as the owner's
  # git writes it on macOS.
  fresh || return 1
  sonnet_route
  result "implemented"
  edit "$(printf 'cafe\xcc\x81.md')" "x"
  out=$(pass implement) || fail "nfd: failed: $out"
  tgit -c core.quotePath=false ls-files | grep -qxF "$(printf 'caf\xc3\xa9.md')" || fail "nfd: the name was committed decomposed"
  clean_after nfd
  # 26. A tracked symlink can be deleted; a tracked file an ignore rule
  # matches can be changed.
  fresh || return 1
  sonnet_route
  ln -s app.py "$repo/src/link"
  printf '*.log\n' > "$repo/.gitignore"
  printf 'old\n' > "$repo/keep.log"
  tgit add -f src/link .gitignore keep.log && tgit commit -qm "tracked link and log"
  result "implemented"
  printf 'src/link\n' > "$sa/fixture/delete"
  edit keep.log "new"
  out=$(pass implement) || fail "tracked symlink: refused: $out"
  [ ! -e "$repo/src/link" ] && [ ! -L "$repo/src/link" ] || fail "tracked symlink: not deleted"
  [ "$(cat "$repo/keep.log")" = new ] || fail "tracked ignored file: not changed"
  clean_after "tracked symlink"
  # 27. A name that reads as pathspec magic is only a name.
  fresh || return 1
  sonnet_route
  result "implemented"
  edit ":(exclude)src" "x"
  out=$(pass implement) || fail "magic name: refused: $out"
  [ -f "$repo/:(exclude)src" ] || fail "magic name: not applied"
  clean_after "magic name"
  # 28. A pass without the run's authority does not start: the worker could
  # not reach a registry through the proxy's inspection (FR-031).
  fresh || return 1
  rm "$run/proxy-ca.pem"
  result "planned"
  edit "$f/plan.md" "# Plan"
  if out=$(pass agent plan); then fail "no authority: succeeded"; fi
  printf '%s' "$out" | grep -qF "sdd-step: the bundle has no proxy-ca.pem" || fail "no authority: not refused with its reason: $out"
  grep -qF '"run"' "$sa/calls.jsonl" 2> /dev/null && fail "no authority: a container was started"
  clean_after "no authority"

  return "$status"
}
if command -v check-jsonschema > /dev/null 2>&1; then
  check "the contained pass exports, judges, applies and cleans up, and no credential or repository configuration reaches a host step" sdd_pass
else
  skip "the contained pass exports, judges, applies and cleans up, and no credential or repository configuration reaches a host step" check-jsonschema
fi

# The run's own machinery (contracts/sdd-step.md): prepare-worker builds the
# worker image once per content of containers/worker/ and records its tag;
# egress-proxy starts the proxy container on the run's network with the
# credentials on its stdin only, records where agents reach it and the model
# behind each DeepSeek id, and removes the network when the proxy stops;
# cleanup removes what a run left behind, and leaves a live run alone.
sdd_lifecycle() {
  local tmp status=0
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  local dotfiles=$PWD step=$PWD/bin/sdd-step.sh repo=$tmp/repo sa=$tmp/standins run out
  local claude_secret=sk-ant-oat01-FAKEclaudeTOKEN0123456789 deepseek_secret=sk-FAKEdeepseekKEY0123456789
  fail() {
    echo "$1"
    status=1
  }
  cp -R checks/sdd/standins "$sa"
  mkdir -p "$sa/secrets" "$repo"
  printf '%s' "$claude_secret" > "$sa/secrets/claude-oauth"
  printf '%s' "$deepseek_secret" > "$sa/secrets/deepseek-api"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
  run=$(python3 -I checks/sdd/bundle.py "$tmp" "$dotfiles") || return 1
  rm -f "$run/proxy.json" "$run/worker.json" "$run/proxy-ca.pem"
  printf '{"run_id":"run1","pid":%s,"started":"2026-10-21T14:00:00Z","base":"x"}\n' "$$" > "$run/lock.json"
  sub() { (cd "$repo" && SDD_RUN_DIR=$run "$step" "$@" 2>&1); }
  calls() { grep -F "\"$1\"" "$sa/calls.jsonl" 2> /dev/null; }

  # prepare-worker: builds once, from dotfiles' containers/worker/, and records the tag.
  # The built image's inventory, as the stand-in answers its inventory run:
  # here the committed one, so the build is accepted.
  cp "$dotfiles/containers/worker/inventory.txt" "$sa/inventory.out" 2> /dev/null
  local tag
  tag=$(sub prepare-worker) || fail "prepare-worker: failed: $tag"
  [[ "$tag" =~ ^sdd-worker:[0-9a-f]{12}$ ]] || fail "prepare-worker: printed '$tag', not sdd-worker:<12 hex>"
  calls build | grep -qF "$dotfiles/containers/worker" || fail "prepare-worker: did not build from containers/worker"
  /usr/bin/python3 -I -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["image"] != sys.argv[2])' "$run/worker.json" "$tag" 2> /dev/null ||
    fail "prepare-worker: worker.json does not record $tag"
  out=$(sub prepare-worker) || fail "prepare-worker: second run failed: $out"
  [ "$(calls build | wc -l | tr -d ' ')" -eq 1 ] || fail "prepare-worker: built again although the image was present"
  # Superseded worker images go, unless a run that has not finished still
  # uses one — in this repository, or in another that registered its run in
  # ~/.local/state/sdd/runs/ — paused runs included; images that are not the
  # worker's are never touched.
  local paused=$repo/.git/sdd/run3 done=$repo/.git/sdd/run4 other=$tmp/other/.git/sdd/run5
  mkdir -p "$paused" "$done" "$other" "$tmp/home/.local/state/sdd/runs"
  printf '{"image":"sdd-worker:bbbbbbbbbbbb"}\n' > "$paused/worker.json"
  printf '{"image":"sdd-worker:aaaaaaaaaaaa"}\n' > "$done/worker.json"
  printf '{"finished":"2026-10-21T15:00:00Z"}\n' > "$done/finished.json"
  printf '{"image":"sdd-worker:cccccccccccc"}\n' > "$other/worker.json"
  ln -s "$other" "$tmp/home/.local/state/sdd/runs/run5"
  printf '%s\n' sdd-worker:aaaaaaaaaaaa sdd-worker:bbbbbbbbbbbb sdd-worker:cccccccccccc sdd-worker:dddddddddddd debian:bookworm-slim >> "$sa/images.txt"
  out=$(cd "$repo" && HOME=$tmp/home SDD_RUN_DIR=$run "$step" prepare-worker 2>&1) || fail "prepare-worker: third run failed: $out"
  grep -qx sdd-worker:aaaaaaaaaaaa "$sa/images.txt" && fail "prepare-worker: kept the image of a finished run"
  grep -qx sdd-worker:dddddddddddd "$sa/images.txt" && fail "prepare-worker: kept an image no run uses"
  grep -qx sdd-worker:bbbbbbbbbbbb "$sa/images.txt" || fail "prepare-worker: deleted the image a paused run uses"
  grep -qx sdd-worker:cccccccccccc "$sa/images.txt" || fail "prepare-worker: deleted the image another repository's run uses"
  grep -qx debian:bookworm-slim "$sa/images.txt" || fail "prepare-worker: deleted an image that is not the worker's"
  grep -qx "$tag" "$sa/images.txt" || fail "prepare-worker: deleted the current worker image"
  rm -rf "$paused" "$done"

  # A build whose installed packages differ from the committed inventory
  # (FR-032) is refused, naming each difference; it is deleted, since a
  # present image is one prepare-worker accepted, and nothing is recorded.
  if [ -s "$sa/inventory.out" ]; then
    grep -vxF "$tag" "$sa/images.txt" > "$sa/images.new" && mv "$sa/images.new" "$sa/images.txt"
    rm -f "$run/worker.json"
    {
      sed 1d "$dotfiles/containers/worker/inventory.txt"
      echo "deb planted-package 9.9"
    } | sort > "$sa/inventory.out"
    local first
    first=$(head -1 "$dotfiles/containers/worker/inventory.txt")
    if out=$(sub prepare-worker); then fail "inventory: a differing build was accepted"; fi
    printf '%s' "$out" | grep -qF "deb planted-package 9.9" || fail "inventory: the added package is not named: $out"
    printf '%s' "$out" | grep -qF "$first" || fail "inventory: the missing package is not named: $out"
    [ ! -e "$run/worker.json" ] || fail "inventory: worker.json recorded a refused image"
    grep -qx "$tag" "$sa/images.txt" && fail "inventory: the refused image was kept"
    # An image already present under its tag is checked again: a refused
    # build that survived its deletion, or an interrupted check, is never
    # used unchecked (review of Phase 2b).
    cp "$dotfiles/containers/worker/inventory.txt" "$sa/inventory.out"
    out=$(sub prepare-worker) || fail "inventory: the committed inventory was refused: $out"
    printf 'deb planted-package 9.9\n' >> "$sa/inventory.out"
    if out=$(sub prepare-worker); then fail "inventory: a present image that differs was used unchecked"; fi
    grep -qx "$tag" "$sa/images.txt" && fail "inventory: the present image that differs was kept"
    cp "$dotfiles/containers/worker/inventory.txt" "$sa/inventory.out"
    out=$(sub prepare-worker) || fail "inventory: rebuilding after a refusal failed: $out"
    : > "$sa/inventory.fail"
    if out=$(sub prepare-worker); then fail "inventory: a failed inventory run was accepted"; fi
    rm "$sa/inventory.fail"
    out=$(sub prepare-worker) || fail "inventory: rebuilding after a failed inventory run failed: $out"
    printf 'deb planted-package 9.9\n' >> "$sa/inventory.out"
    : > "$sa/delete.fail"
    if out=$(sub prepare-worker); then fail "inventory: succeeded although the refused image could not be deleted"; fi
    printf "%s" "$out" | grep -qF "could not be deleted" || fail "inventory: a failed deletion was not named: $out"
    rm "$sa/delete.fail"
    cp "$dotfiles/containers/worker/inventory.txt" "$sa/inventory.out"
    out=$(sub prepare-worker) || fail "inventory: the committed inventory was refused at the end: $out"
  else
    fail "inventory: containers/worker/inventory.txt is missing or empty"
  fi

  # egress-proxy, opted out: Claude's credential only.
  local opt pid
  # The network policy comes from the bundle, frozen at start.
  printf 'registry.frozen.example\n' > "$run/egress-registries.txt"
  for opt in sonnet deepseek; do
    printf '{"implement":"%s"}\n' "$opt" > "$run/optin.json"
    rm -f "$run/proxy.json" "$sa/proxy-start.json"
    (cd "$repo" && SDD_RUN_DIR=$run "$step" egress-proxy > "$tmp/proxy.out" 2>&1) &
    pid=$!
    local waited=0
    while [ ! -s "$run/proxy.json" ] && [ $waited -lt 100 ] && kill -0 "$pid" 2> /dev/null; do
      sleep 0.1
      waited=$((waited + 1))
    done
    [ -s "$run/proxy.json" ] || {
      fail "egress-proxy $opt: no proxy.json: $(cat "$tmp/proxy.out")"
      kill "$pid" 2> /dev/null
      continue
    }
    /usr/bin/python3 -I - "$run/proxy.json" "$sa/proxy-start.json" "$opt" "$run/routing.json" "$run/admissions" << 'PY' || status=1
import json, sys
import os
proxy, start, opt, routing, admissions = sys.argv[1:]
bad = []
p = json.load(open(proxy))
if p != {"address": "127.0.0.1", "port": 8080}:
    bad.append(f"proxy.json is {p}")
s = json.load(open(start))
want = {"anthropic": True, "deepseek": True} if opt == "deepseek" else {"anthropic": True}
if s["providers"] != want:
    bad.append(f"the proxy got credentials {s['providers']}, wanted {want} (True: the Keychain's value)")
if s["admissions"] != "/admissions":
    bad.append(f"admissions read from {s['admissions']}")
# Each GitHub host gets its download-only rule; check 93 tests what they allow.
if sorted(s.get("paths") or {}) != ["codeload.github.com", "github.com"]:
    bad.append(f"the proxy was not given GitHub's download-only path rules: {s.get('paths')}")
ca = open(os.path.join(os.path.dirname(proxy), "proxy-ca.pem")).read() if os.path.exists(os.path.join(os.path.dirname(proxy), "proxy-ca.pem")) else None
if ca != "-----BEGIN CERTIFICATE-----\nstand-in run authority\n-----END CERTIFICATE-----\n":
    bad.append(f"proxy-ca.pem is not the authority the proxy printed: {ca!r}")
served = json.load(open(routing))["served"]
if opt == "deepseek" and served.get("deepseek-flash") != "DeepSeek-Standin-Flash":
    bad.append(f"routing.json served is {served}, not the name /models gave")
import os
if not os.path.exists(os.path.join(admissions, "heartbeat")):
    bad.append("no heartbeat file in the admissions directory")
for b in bad:
    print(f"egress-proxy {opt}: {b}")
sys.exit(1 if bad else 0)
PY
    local proxy_run
    proxy_run=$(calls run | grep -F sdd-egress-proxy.py | tail -1)
    printf '%s' "$proxy_run" | grep -qF '"--network", "sdd-run1"' || fail "egress-proxy $opt: not on the run's network: $proxy_run"
    printf '%s' "$proxy_run" | grep -qF "$run/admissions:/admissions:ro" || fail "egress-proxy $opt: admissions not mounted read-only: $proxy_run"
    /usr/bin/python3 -I -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["registries"] == ["registry.frozen.example"] else "egress-proxy: the registries are not the bundle'"'"'s")' "$sa/proxy-start.json" || status=1
    calls network | grep -qF '"create", "sdd-run1"' || fail "egress-proxy $opt: the run's network was not created"
    grep -qF -e "$claude_secret" -e "$deepseek_secret" "$sa/calls.jsonl" "$tmp/proxy.out" "$run"/*.json &&
      fail "egress-proxy $opt: a credential reached an argument, the bundle or the output"
    "$sa/container" stop sdd-run1-proxy
    wait "$pid" || fail "egress-proxy $opt: exited non-zero when the proxy stopped: $(cat "$tmp/proxy.out")"
    grep -qx sdd-run1 "$sa/networks.txt" 2> /dev/null && fail "egress-proxy $opt: the network outlived the proxy"
    [ ! -e "$run/proxy-ca.pem" ] || fail "egress-proxy $opt: proxy-ca.pem outlived the proxy"
  done

  # cleanup: everything labelled with a dead run goes; a live run's stays.
  mkdir -p "$run/passes/plan-1/export" "$run/admissions"
  : > "$run/admissions/sdd-pass-leftover.json"
  printf 'sdd.run=run1 ' > "$sa/labels.sdd-run1-plan-1"
  local live=$repo/.git/sdd/run2
  mkdir -p "$live/passes/plan-9"
  cp "$run/tools.json" "$live/"
  printf '{"run_id":"run2","pid":%s,"started":"%s","base":"x"}\n' "$$" "$(ps -o lstart= -p $$ | sed 's/^ *//')" > "$live/lock.json"
  printf 'sdd.run=run2 ' > "$sa/labels.sdd-run2-plan-9"
  printf '{"run_id":"run1","pid":999999,"started":"x","base":"x"}\n' > "$run/lock.json"
  printf '%s\n' sdd-cache-implement-run1 sdd-cache-verify-run1 sdd-cache-verify-run2 > "$sa/volumes.txt"
  out=$(sub cleanup) || fail "cleanup: failed: $out"
  [ ! -e "$sa/labels.sdd-run1-plan-1" ] || fail "cleanup: left the dead run's container"
  [ -z "$(ls -A "$run/passes" 2> /dev/null)" ] || fail "cleanup: left the dead run's exports"
  [ ! -e "$run/admissions/sdd-pass-leftover.json" ] || fail "cleanup: left the dead run's admissions"
  grep -q run1 "$sa/volumes.txt" && fail "cleanup: left the dead run's cache volumes"
  if [ ! -e "$sa/labels.sdd-run2-plan-9" ] || [ ! -d "$live/passes/plan-9" ] || ! grep -qx sdd-cache-verify-run2 "$sa/volumes.txt"; then
    fail "cleanup: touched the live run"
  fi
  return "$status"
}
check "prepare-worker builds once, egress-proxy holds the credentials and records the served model, cleanup spares a live run" sdd_lifecycle
