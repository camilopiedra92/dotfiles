#!/usr/bin/env bash
# Merges a pull request only when its CI is green, for the head it was green on.
#
# Usage:  merge-on-green <pr> [gh pr merge flags...]
#         e.g. merge-on-green 47 --rebase --delete-branch
#
# Run it from the repository (or with GH_REPO set), in a terminal of its own:
# it waits for the checks to finish.
#
# Where the platform can require checks -- a ruleset on the default branch --
# that is the gate, and `gh pr merge --auto` the merge; this script is for
# where it cannot: a private repository on GitHub's free plan. Each step closes
# a gap a bare `gh pr checks --watch && gh pr merge` leaves open (gh 2.97):
#   - the head is pinned before waiting and passed as --match-head-commit, so a
#     push that lands meanwhile makes GitHub refuse the merge;
#   - --watch exits 0 when checks are cancelled, so after it every check has to
#     be `pass` or `skipping`; cancelled or pending ones stop it;
#   - with no checks reported yet, gh exits non-zero and nothing merges.
# Ceiling: only the checks already reported count. A workflow that registers
# after the others finish is not waited for; the platform's required checks
# are what close that.
set -euo pipefail

if [ $# -lt 1 ]; then
  echo "usage: merge-on-green <pr> [gh pr merge flags...]" >&2
  exit 2
fi
pr=$1
shift

head=$(gh pr view "$pr" --json headRefOid --jq .headRefOid)
gh pr checks "$pr" --watch --fail-fast --interval 30
gh pr checks "$pr" --json bucket --jq \
  'if all(.[]; .bucket == "pass" or .bucket == "skipping") then empty else error("a check did not pass") end'
gh pr merge "$pr" --match-head-commit "$head" "$@"
