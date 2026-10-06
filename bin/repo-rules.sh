#!/usr/bin/env bash
# The default branch's ruleset and merge settings of each repository declared
# in github/repos.json, kept as code.
#
# Usage:  repo-rules check [owner/repo...]   report every difference
#         repo-rules apply [owner/repo...]   create or update what differs
#
# With no repository named, every declared one. `apply` changes repository
# permissions, so a person runs it; name one repository to try a change there
# first.
#
# One baseline for every declared repository: changes reach the default branch
# only through a pull request, after the checks the declaration names pass on
# a branch that is up to date, each pinned to GitHub Actions so no other app
# can report a status under its name; squash only, so history stays linear; no
# force-push, no deletion, no bypass. The repository settings are the ones
# `gh pr merge --auto` needs. What varies per repository is only its checks.
#
# `apply` never deletes. A ruleset other than the declared one is reported by
# `check` and left for a person to remove.
#
# `check` with no repository named also reports the public repositories under
# active work -- not archived, pushed in the last 90 days -- that the
# declaration leaves out, so joining it is checked rather than remembered.
# Which checks a new one requires is a person's choice, so it is reported and
# never added.
#
# Exit: 0 in the declared state (check) or applied (apply); 1 drift found by
# check; 2 the declaration or GitHub could not be read.
set -euo pipefail

declaration=${REPO_RULES_DECLARATION:-$(dirname "$(readlink -f "$0")")/../github/repos.json}
NAME="protect default branch"
GITHUB_ACTIONS=15368

desired_ruleset() {
  jq -S --arg repo "$1" --arg name "$NAME" --argjson app "$GITHUB_ACTIONS" '
    {
      name: $name,
      target: "branch",
      enforcement: "active",
      conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
      bypass_actors: [],
      rules: ([
        {type: "deletion"},
        {type: "non_fast_forward"},
        {type: "required_linear_history"},
        {type: "pull_request", parameters: {
          allowed_merge_methods: ["squash"],
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: false,
          require_extra_approval_for_unattributed_changes: true,
          require_last_push_approval: false,
          required_approving_review_count: 0,
          required_review_thread_resolution: false,
          required_reviewers: []
        }},
        {type: "required_status_checks", parameters: {
          do_not_enforce_on_create: false,
          strict_required_status_checks_policy: true,
          required_status_checks: [.[$repo].checks[] | {context: ., integration_id: $app}]
        }}
      ] | sort_by(.type))
    }' "$declaration"
}

desired_settings() {
  jq -nS '{allow_auto_merge: true, delete_branch_on_merge: true,
    allow_squash_merge: true, allow_rebase_merge: false, allow_merge_commit: false}'
}

# What GitHub returns, cut to the declared fields and put in the same order,
# so `check` compares meaning and not the response's shape.
live_ruleset() {
  local json
  json=$(gh api "repos/$1/rulesets/$2") || return 1
  jq -S '{name, target, enforcement, conditions, bypass_actors,
    rules: (.rules | sort_by(.type))}' <<< "$json"
}

live_settings() {
  local json
  json=$(gh api "repos/$1") || return 1
  jq -S '{allow_auto_merge, delete_branch_on_merge, allow_squash_merge,
    allow_rebase_merge, allow_merge_commit}' <<< "$json"
}

# One repository: prints its drift, applies when asked. Returns 2 when GitHub
# cannot be read for it, 1 when it drifted, 0 when it matched.
reconcile() {
  local repo=$1 rulesets ids id others want have drifted=0
  rulesets=$(gh api "repos/$repo/rulesets") || return 2
  ids=$(jq -r --arg n "$NAME" '.[] | select(.name == $n) | .id' <<< "$rulesets")
  others=$(jq -r --arg n "$NAME" '.[] | select(.name != $n) | .name' <<< "$rulesets")
  if [ "$(grep -c . <<< "$ids")" -gt 1 ]; then
    echo "$repo: more than one ruleset named \"$NAME\""
    return 2
  fi
  id=$ids

  while read -r other; do
    [ -n "$other" ] || continue
    echo "$repo: undeclared ruleset \"$other\" (remove it on GitHub: apply never deletes)"
    drifted=1
  done <<< "$others"

  want=$(desired_ruleset "$repo")
  if [ -z "$id" ]; then
    echo "$repo: no \"$NAME\" ruleset"
    drifted=1
    if [ "$mode" = apply ]; then
      gh api -X POST "repos/$repo/rulesets" --input - <<< "$want" > /dev/null || return 2
    fi
  else
    have=$(live_ruleset "$repo" "$id") || return 2
    if [ "$have" != "$want" ]; then
      echo "$repo: ruleset differs from the declaration:"
      diff <(echo "$have") <(echo "$want") | sed 's/^/    /' || true
      drifted=1
      if [ "$mode" = apply ]; then
        gh api -X PUT "repos/$repo/rulesets/$id" --input - <<< "$want" > /dev/null || return 2
      fi
    fi
  fi

  want=$(desired_settings)
  have=$(live_settings "$repo") || return 2
  if [ "$have" != "$want" ]; then
    echo "$repo: settings differ from the declaration:"
    diff <(echo "$have") <(echo "$want") | sed 's/^/    /' || true
    drifted=1
    if [ "$mode" = apply ]; then
      gh api -X PATCH "repos/$repo" --input - <<< "$want" > /dev/null || return 2
    fi
  fi
  return "$drifted"
}

mode=${1:-}
case "$mode" in check | apply) shift ;; *)
  echo "usage: repo-rules check|apply [owner/repo...]" >&2
  exit 2
  ;;
esac

# A declaration that cannot be read must not read as "no drift".
if ! declared=$(jq -er 'if type == "object" and length > 0
    and all(.[]; (.checks | type) == "array" and (.checks | length) > 0)
  then keys[] else error("expected {\"owner/repo\": {\"checks\": [...]}, ...}") end' \
  "$declaration" 2>&1); then
  echo "repo-rules: cannot read $declaration: $declared" >&2
  exit 2
fi
targets=$declared
if [ $# -gt 0 ]; then
  for repo in "$@"; do
    grep -qxF "$repo" <<< "$declared" || {
      echo "repo-rules: $repo is not declared in $declaration" >&2
      exit 2
    }
  done
  targets=$(printf '%s\n' "$@")
fi

status=0
while read -r repo; do
  rc=0
  reconcile "$repo" || rc=$?
  case "$rc" in
    0) ;;
    1) [ "$mode" = apply ] || [ "$status" = 2 ] || status=1 ;;
    *)
      echo "$repo: could not be read or written on GitHub (gh's error is above)"
      status=2
      ;;
  esac
done <<< "$targets"

if [ "$mode" = check ] && [ $# -eq 0 ]; then
  if ! listed=$(gh repo list --visibility public --limit 1000 \
    --json nameWithOwner,isArchived,pushedAt); then
    echo "repo-rules: could not list the public repositories (gh's error is above)"
    exit 2
  fi
  active=$(jq -r '.[] | select((.isArchived | not)
    and (.pushedAt | fromdateiso8601) > (now - 90 * 86400)) | .nameWithOwner' <<< "$listed")
  while read -r repo; do
    [ -n "$repo" ] || continue
    grep -qxF "$repo" <<< "$declared" && continue
    echo "$repo: active public repository not declared in github/repos.json"
    [ "$status" = 2 ] || status=1
  done <<< "$active"
fi
exit "$status"
