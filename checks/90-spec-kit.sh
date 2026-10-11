# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Spec Kit ─────────────────────────────────────────────────────────────────
printf '\n%sSpec Kit%s\n' "$DIM" "$OFF"

# The override in zsh/.zshenv exists until upstream ships its own PyYAML
# fallback, and drift.sh is what notices either end of that: the override
# broken while still needed, or still set once the CLI no longer needs it.
# Run against a fake `uv tool dir` holding a common.sh with or without the
# fallback, and fake pythons that do or do not import yaml.
drift_speckit_python() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn="$tmp/fn.sh"
  {
    sed -n '/^speckit_python_drift() {$/,/^}$/p' drift.sh
  } > "$fn"
  grep -qF 'core_pack/scripts/bash/common.sh' "$fn" || {
    echo "could not extract speckit_python_drift from drift.sh"
    return 1
  }

  local scripts="$tmp/tools/specify-cli/lib/python3.12/site-packages/specify_cli/core_pack/scripts/bash"
  mkdir -p "$scripts" "$tmp/bin"
  printf '#!/bin/sh\necho %s/tools\n' "$tmp" > "$tmp/bin/uv"
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/py-yaml"
  printf '#!/bin/sh\nexit 1\n' > "$tmp/bin/py-bare"
  chmod +x "$tmp/bin/uv" "$tmp/bin/py-yaml" "$tmp/bin/py-bare"
  drift() {
    # shellcheck disable=SC2016  # expanded by the inner shell
    PATH="$tmp/bin:$PATH" SPECKIT_PYTHON_EXECUTABLE="$1" bash -c '. "$1" && speckit_python_drift' _ "$fn"
  }

  echo 'python3 -c "import yaml"' > "$scripts/common.sh"
  out=$(drift "$tmp/bin/py-yaml") || return 1
  [ -z "$out" ] || {
    echo "needed and working, expected silence, got: $out"
    return 1
  }
  out=$(drift "$tmp/bin/py-bare") || return 1
  case "$out" in
    *'not a python with PyYAML'*) ;;
    *)
      echo "needed and broken, expected a report, got: ${out:-nothing}"
      return 1
      ;;
  esac

  echo 'uv run --isolated --no-project --with pyyaml==6.0.3 python' >> "$scripts/common.sh"
  out=$(drift "$tmp/bin/py-yaml") || return 1
  case "$out" in
    *'no longer needed'*) ;;
    *)
      echo "fallback shipped, expected the override reported as removable, got: ${out:-nothing}"
      return 1
      ;;
  esac
}
check "drift.sh tracks SPECKIT_PYTHON_EXECUTABLE until upstream's fallback ships" drift_speckit_python

# sdd-init against a `specify` that records its arguments and writes the two
# directories the real one writes. What is under test is the script's own
# contract: what it refuses, what it calls, and what lands in its commit.
sdd_init() {
  local tmp repo out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/specify" << FAKE
#!/bin/sh
printf '%s\n' "\$*" >> "$tmp/calls"
case "\$1" in
  init) mkdir -p .specify/memory .claude/skills/speckit-tasks
        echo x > .specify/memory/constitution.md
        echo x > .claude/skills/speckit-tasks/SKILL.md ;;
esac
FAKE
  chmod +x "$tmp/bin/specify"

  fresh() {
    repo="$tmp/repo-$1"
    git init -q "$repo"
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
    echo keep > "$repo/notes.txt"
    : > "$tmp/calls"
  }
  # A python that imports anything, standing in for one that has PyYAML.
  printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/python-with-yaml"
  chmod +x "$tmp/bin/python-with-yaml"
  run() {
    (cd "$repo" && PATH="$tmp/bin:$PATH" GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t \
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
      SPECKIT_PYTHON_EXECUTABLE="${PYX-$tmp/bin/python-with-yaml}" ../sdd-init 2>&1)
  }
  ln -s "$PWD/bin/sdd-init.sh" "$tmp/sdd-init"

  # The happy path: two calls, one commit holding only what init wrote.
  fresh ok
  out=$(run) || {
    echo "refused a clean repo: $out"
    return 1
  }
  # The URLs are read from the script, so the check pins the calls' shape and
  # order and leaves the versions to the script: one preset add per
  # PRESET_*_URL, in the order they are declared.
  echo 'init --here --force --integration claude' > "$tmp/want"
  while read -r url; do
    case "$url" in
      https://github.com/*/archive/refs/tags/v*.zip) ;;
      *)
        echo "a PRESET_*_URL is not a tag archive: $url"
        return 1
        ;;
    esac
    echo "preset add --from $url" >> "$tmp/want"
  done < <(sed -n 's/^PRESET_[A-Z_]*_URL=//p' bin/sdd-init.sh)
  grep -q "^PRESET_CONSTITUTION_AUTHORING_URL=https://github.com/[^/]*/spec-kit-preset-constitution-authoring/" bin/sdd-init.sh || {
    echo "sdd-init does not install the constitution-authoring preset"
    return 1
  }
  diff -u "$tmp/want" "$tmp/calls" || return 1
  [ "$(git -C "$repo" diff-tree --no-commit-id --name-only -r HEAD | sort | tr '\n' ' ')" = \
    ".claude/skills/speckit-tasks/SKILL.md .specify/memory/constitution.md " ] || {
    echo "the commit holds something else:"
    git -C "$repo" show --stat HEAD
    return 1
  }
  git -C "$repo" status --porcelain | grep -qx '?? notes.txt' || {
    echo "an unrelated file did not stay out of the commit"
    return 1
  }

  # Something already staged would ride along in the commit, so it refuses
  # before calling anything.
  fresh staged
  git -C "$repo" add notes.txt
  if out=$(run); then
    echo "accepted a repo with staged changes: $out"
    return 1
  fi
  [ ! -s "$tmp/calls" ] || {
    echo "called specify before refusing:"
    cat "$tmp/calls"
    return 1
  }

  # Once a preset is installed every script behind specify, plan and tasks
  # needs PyYAML through this variable, so without it the repo it leaves behind
  # cannot run a single phase. It refuses before calling anything.
  fresh nopython
  if out=$(PYX='' run); then
    echo "accepted an unset SPECKIT_PYTHON_EXECUTABLE: $out"
    return 1
  fi
  [ ! -s "$tmp/calls" ] || {
    echo "called specify without a python that has PyYAML"
    return 1
  }

  # A second run would re-init over a constitution that has been written.
  fresh twice
  run > /dev/null || return 1
  : > "$tmp/calls"
  if out=$(run); then
    echo "ran again over an existing .specify/: $out"
    return 1
  fi
  [ ! -s "$tmp/calls" ] || {
    echo "called specify over an existing .specify/"
    return 1
  }
}
check "sdd-init refuses staged work, no PyYAML python and a second run, and commits only what init wrote" sdd_init

# merge-on-green against a `gh` that answers from environment variables and
# records its calls. What is under test is the gate: the merge runs only when
# every check passed or was skipped, and only for the head the run started on.
merge_on_green() {
  local tmp out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/gh" << 'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CALLS"
case "$1 $2" in
  "pr view") echo "$HEAD_SHA" ;;
  "pr checks")
    # Like gh: with no checks reported, the --watch call itself fails.
    [ "$CHECKS_EXIT" = 0 ] || exit "$CHECKS_EXIT"
    case " $* " in
      *" --watch "*) exit "$WATCH_EXIT" ;;
    esac
    all="$*"
    expr=${all##*--jq }
    # Like gh's --jq: an empty result is success, error() is not.
    printf '%s' "$BUCKETS" | jq "$expr" > /dev/null 2>&1 || {
      echo "jq: not green" >&2
      exit 1
    }
    ;;
  "pr merge") exit 0 ;;
esac
FAKE
  chmod +x "$tmp/bin/gh"
  run() {
    : > "$tmp/calls"
    PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" HEAD_SHA=abc123 \
      WATCH_EXIT="${WATCH_EXIT:-0}" CHECKS_EXIT="${CHECKS_EXIT:-0}" \
      BUCKETS="${BUCKETS:-[]}" bin/merge-on-green.sh 7 --rebase --delete-branch 2>&1
  }
  merged() { grep -q '^pr merge' "$tmp/calls"; }

  BUCKETS='[{"bucket":"pass"},{"bucket":"skipping"}]' out=$(run) || {
    echo "refused green checks: $out"
    return 1
  }
  grep -qx 'pr merge 7 --match-head-commit abc123 --rebase --delete-branch' "$tmp/calls" || {
    echo "did not merge the pinned head with the flags given:"
    cat "$tmp/calls"
    return 1
  }

  # -R anywhere among the flags names the repository for every call, not
  # only for the merge: run outside a checkout, the first call needs it.
  : > "$tmp/calls"
  PATH="$tmp/bin:$PATH" CALLS="$tmp/calls" HEAD_SHA=abc123 WATCH_EXIT=0 CHECKS_EXIT=0 \
    BUCKETS='[{"bucket":"pass"}]' bin/merge-on-green.sh 7 -R o/r --rebase > /dev/null 2>&1 || {
    echo "refused -R o/r"
    return 1
  }
  if grep -v -- '-R o/r' "$tmp/calls" | grep -q .; then
    echo "a call went out without -R o/r:"
    cat "$tmp/calls"
    return 1
  fi
  grep -qx 'pr merge 7 --match-head-commit abc123 -R o/r --rebase' "$tmp/calls" || {
    echo "the merge lost a flag or doubled -R:"
    cat "$tmp/calls"
    return 1
  }

  local case
  for case in "failed watch:WATCH_EXIT=1" "cancelled check:BUCKETS=[{\"bucket\":\"pass\"},{\"bucket\":\"cancel\"}]" \
    "pending check:BUCKETS=[{\"bucket\":\"pending\"}]" "no checks reported:CHECKS_EXIT=1" \
    "every check skipped:BUCKETS=[{\"bucket\":\"skipping\"},{\"bucket\":\"skipping\"}]"; do
    if out=$(env "${case#*:}" bash -c "$(declare -f run); $(declare -p tmp); run"); then
      echo "${case%%:*}: exited 0: $out"
      return 1
    fi
    ! merged || {
      echo "${case%%:*}: merged anyway"
      return 1
    }
  done
}
check "merge-on-green merges the pinned head only when its checks passed (some may be skipped)" merge_on_green

# repo-rules against a `gh` that serves repositories and rulesets from files
# under $STATE (a missing file is a 404) and records every write. Under test:
# `check` reports exactly the differences from the declaration and tells
# "drift" (1) from "could not read" (2); `apply` writes what removes them --
# the ruleset with each check pinned to GitHub Actions, and the settings
# `gh pr merge --auto` needs -- only for the repositories named, and deletes
# nothing.
repo_rules() {
  local tmp state out rc
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  state=$tmp/state
  cat > "$tmp/bin/gh" << 'FAKE'
#!/usr/bin/env bash
# gh repo list ... (served from $STATE/repo_list.json), or
# gh api [-X METHOD] PATH [--input FILE|-]
if [ "$1" = repo ]; then
  printf '%s\n' "$*" >> "$STATE/repo_list_calls"
  cat "$STATE/repo_list.json" 2> /dev/null || echo '[]'
  exit 0
fi
shift
method=GET input= path=
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    --input) input=$2; shift 2 ;;
    *) path=$1; shift ;;
  esac
done
if [ "$method" != GET ]; then
  if [ "$input" = - ]; then body=$(jq -cS .); else body=$(jq -cS . "$input"); fi
  printf '%s %s %s\n' "$method" "$path" "$body" >> "$STATE/writes"
  exit 0
fi
file="$STATE/${path//\//_}.json"
[ -f "$file" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
cat "$file"
FAKE
  chmod +x "$tmp/bin/gh"
  run() { PATH="$tmp/bin:$PATH" STATE="$state" REPO_RULES_DECLARATION="$tmp/repos.json" bin/repo-rules.sh "$@" 2>&1; }
  settings='{"allow_auto_merge":true,"delete_branch_on_merge":true,"allow_merge_commit":false,"allow_squash_merge":true,"allow_rebase_merge":false,"id":1,"full_name":"o/a"}'
  fresh() {
    rm -rf "$state" && mkdir -p "$state"
    echo '{"o/a": {"checks": ["ci-passed"]}}' > "$tmp/repos.json"
    echo "$settings" > "$state/repos_o_a.json"
    echo '[]' > "$state/repos_o_a_rulesets.json"
  }

  # Nothing on GitHub yet: check reports drift (1); apply creates the
  # ruleset with the check pinned to GitHub Actions.
  fresh
  rc=0 && out=$(run check) || rc=$?
  [ "$rc" = 1 ] || {
    echo "check on a repository with no ruleset exited $rc: $out"
    return 1
  }
  run apply > /dev/null || return 1
  grep -q '^POST repos/o/a/rulesets ' "$state/writes" || {
    echo "apply did not create the ruleset:"
    cat "$state/writes"
    return 1
  }
  grep '^POST' "$state/writes" | grep -q '"required_status_checks":\[{"context":"ci-passed","integration_id":15368}\]' || {
    echo "the created ruleset does not pin ci-passed to GitHub Actions:"
    cat "$state/writes"
    return 1
  }

  # The created ruleset served back the way GitHub returns one: with an id,
  # bookkeeping fields and its rules in another order. check is clean and
  # apply writes nothing.
  grep '^POST' "$state/writes" | cut -d' ' -f3- |
    jq '. + {id: 7, source: "o/a", source_type: "Repository", created_at: "x", _links: {}}
      | .rules |= reverse' > "$tmp/served"
  fresh
  echo '[{"id":7,"name":"protect default branch"}]' > "$state/repos_o_a_rulesets.json"
  cp "$tmp/served" "$state/repos_o_a_rulesets_7.json"
  out=$(run check) || {
    echo "check failed on what apply itself created: $out"
    return 1
  }
  run apply > /dev/null || return 1
  [ ! -s "$state/writes" ] || {
    echo "apply wrote to a repository already in its declared state:"
    cat "$state/writes"
    return 1
  }

  # The check pinned to any app (the gap this exists for), a setting off, and
  # an undeclared ruleset: each is reported; apply fixes the first two with a
  # PUT and a PATCH, and deletes nothing.
  jq '(.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks) = [{"context":"ci-passed"}]' \
    "$tmp/served" > "$state/repos_o_a_rulesets_7.json"
  jq '.allow_auto_merge = false' <<< "$settings" > "$state/repos_o_a.json"
  echo '[{"id":7,"name":"protect default branch"},{"id":9,"name":"main"}]' > "$state/repos_o_a_rulesets.json"
  rc=0 && out=$(run check) || rc=$?
  [ "$rc" = 1 ] || {
    echo "check on drift exited $rc"
    return 1
  }
  for want in "integration_id" "allow_auto_merge" "undeclared ruleset \"main\""; do
    grep -qF "$want" <<< "$out" || {
      echo "check did not report $want: $out"
      return 1
    }
  done
  run apply > /dev/null || return 1
  if ! grep -q '^PUT repos/o/a/rulesets/7 ' "$state/writes" ||
    ! grep -q '^PATCH repos/o/a ' "$state/writes"; then
    echo "apply did not update the ruleset and the settings:"
    cat "$state/writes"
    return 1
  fi
  ! grep -q '^DELETE' "$state/writes" || {
    echo "apply deleted something"
    return 1
  }

  # A declaration that cannot be read is an error (2), never "no drift".
  fresh
  for bad in '' 'not json' '{}' '{"o/a": {"checks": []}}'; do
    printf '%s' "$bad" > "$tmp/repos.json"
    rc=0 && out=$(run check) || rc=$?
    [ "$rc" = 2 ] || {
      echo "a declaration of '$bad' exited $rc: $out"
      return 1
    }
  done

  # A repository GitHub will not show: named in the output, the others still
  # checked, and exit 2 rather than the 1 of drift.
  fresh
  echo '{"o/a": {"checks": ["ci-passed"]}, "o/b": {"checks": ["x"]}}' > "$tmp/repos.json"
  rc=0 && out=$(run check) || rc=$?
  if [ "$rc" != 2 ] || ! grep -q '^o/b: could not be read' <<< "$out" ||
    ! grep -q '^o/a: no ' <<< "$out"; then
    echo "an unreadable repository exited $rc or hid the others: $out"
    return 1
  fi

  # apply with one repository named writes only to it.
  run apply o/a > /dev/null || return 1
  ! grep -q ' repos/o/b' "$state/writes" || {
    echo "apply o/a wrote to o/b"
    return 1
  }
  rc=0 && out=$(run apply o/zz) || rc=$?
  [ "$rc" = 2 ] || {
    echo "apply on an undeclared repository exited $rc"
    return 1
  }

  # A public repository under active work that the declaration leaves out is
  # drift: the rule "every repository I keep working on joins" is checked,
  # not remembered. Archived ones and ones untouched for 90 days are not.
  fresh
  jq -n --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '[
    {nameWithOwner: "o/a", isArchived: false, pushedAt: $now},
    {nameWithOwner: "o/new", isArchived: false, pushedAt: $now},
    {nameWithOwner: "o/archived", isArchived: true, pushedAt: $now},
    {nameWithOwner: "o/old", isArchived: false, pushedAt: "2020-01-01T00:00:00Z"},
    {nameWithOwner: "o/empty", isArchived: false, pushedAt: null}
  ]' > "$state/repo_list.json"
  echo '[{"id":7,"name":"protect default branch"}]' > "$state/repos_o_a_rulesets.json"
  cp "$tmp/served" "$state/repos_o_a_rulesets_7.json"
  rc=0 && out=$(run check) || rc=$?
  if [ "$rc" != 1 ] || [ "$(grep -c 'not declared' <<< "$out")" != 1 ] ||
    ! grep -q '^o/new: active public repository not declared' <<< "$out"; then
    echo "check exited $rc; expected only o/new reported as undeclared: $out"
    return 1
  fi
  # Forks and private repositories are not asked for at all.
  if ! grep -q -- '--visibility public' "$state/repo_list_calls" ||
    ! grep -q -- '--source' "$state/repo_list_calls"; then
    echo "the listing does not ask for public non-fork repositories only:"
    cat "$state/repo_list_calls"
    return 1
  fi
  # apply does not report what it cannot fix.
  out=$(run apply) || {
    echo "apply failed where only an undeclared repository differs: $out"
    return 1
  }
  ! grep -q 'not declared' <<< "$out" || {
    echo "apply reported an undeclared repository: $out"
    return 1
  }
  out=$(run check o/a) || {
    echo "check o/a looked beyond the repository named: $out"
    return 1
  }
}
check "repo-rules reports drift from github/repos.json and applies only what removes it" repo_rules
