#!/usr/bin/env bash
# The default branch's ruleset and merge settings of each repository declared
# in github/repos.json, kept as code.
#
# Usage:  repo-rules check    report every difference from the declaration
#         repo-rules apply    create or update what differs (run it yourself:
#                             it changes repository permissions)
#
# One baseline for every declared repository: changes reach the default branch
# only through a pull request, after the checks the declaration names pass on
# a branch that is up to date, each pinned to GitHub Actions so no other app
# can report a status under its name; squash only, so history stays linear; no
# force-push, no deletion, no bypass. The repository settings are the ones
# `gh pr merge --auto` needs. What varies per repository is only its checks.
#
# `apply` never deletes. A ruleset on the repository other than the declared
# one is reported by `check` and left for a person to remove.
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

# The same fields, in the same order, from what GitHub returns.
live_ruleset() {
  gh api "repos/$1/rulesets/$2" --jq '
    {name, target, enforcement, conditions, bypass_actors,
     rules: (.rules | sort_by(.type))}' | jq -S .
}

live_settings() {
  gh api "repos/$1" --jq '{allow_auto_merge, delete_branch_on_merge,
    allow_squash_merge, allow_rebase_merge, allow_merge_commit}' | jq -S .
}

[ "${1:-}" = --source-only ] && return 0

mode=${1:?usage: repo-rules check|apply}
case "$mode" in check | apply) ;; *)
  echo "usage: repo-rules check|apply" >&2
  exit 2
  ;;
esac

drift=0
while read -r repo; do
  id=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name == \"$NAME\") | .id")
  others=$(gh api "repos/$repo/rulesets" --jq ".[] | select(.name != \"$NAME\") | .name")
  while read -r other; do
    [ -n "$other" ] || continue
    echo "$repo: undeclared ruleset \"$other\" (remove it on GitHub: apply never deletes)"
    drift=1
  done <<< "$others"

  want=$(desired_ruleset "$repo")
  if [ -z "$id" ]; then
    echo "$repo: no \"$NAME\" ruleset"
    drift=1
    [ "$mode" = apply ] && gh api -X POST "repos/$repo/rulesets" --input <(echo "$want") > /dev/null
  else
    have=$(live_ruleset "$repo" "$id")
    if [ "$have" != "$want" ]; then
      echo "$repo: ruleset differs from the declaration:"
      diff <(echo "$have") <(echo "$want") | sed 's/^/    /' || true
      drift=1
      [ "$mode" = apply ] && gh api -X PUT "repos/$repo/rulesets/$id" --input <(echo "$want") > /dev/null
    fi
  fi

  want=$(desired_settings)
  have=$(live_settings "$repo")
  if [ "$have" != "$want" ]; then
    echo "$repo: settings differ from the declaration:"
    diff <(echo "$have") <(echo "$want") | sed 's/^/    /' || true
    drift=1
    [ "$mode" = apply ] && gh api -X PATCH "repos/$repo" --input <(echo "$want") > /dev/null
  fi
done < <(jq -r 'keys[]' "$declaration")

[ "$mode" = check ] && exit "$drift"
exit 0
