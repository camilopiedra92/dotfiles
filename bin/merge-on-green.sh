#!/usr/bin/env bash
# Merges a pull request only when its CI is green, for the head it was green on.
#
# Usage:  merge-on-green <pr> [gh pr merge flags...]
#         e.g. merge-on-green 47 --rebase --delete-branch
#
# Run it in a terminal of its own: it waits for the checks to finish. The
# repository is the checkout it runs in, or `-R owner/repo` among the flags,
# which then applies to every call. Not GH_REPO: run inside another checkout,
# `--delete-branch` would then delete that checkout's branch of the same name.
#
# Where the platform can require checks -- a ruleset on the default branch --
# that is the gate, and `gh pr merge --auto` the merge; this script is for
# where it cannot: a private repository on GitHub's free plan. Each step closes
# a gap a bare `gh pr checks --watch && gh pr merge` leaves open (gh 2.97):
#   - the head is pinned before waiting and passed as --match-head-commit, so a
#     push that lands meanwhile makes GitHub refuse the merge;
#   - --watch exits 0 when checks are cancelled, so after it every check has to
#     be `pass` or `skipping` (skipped or neutral); cancelled or pending ones
#     stop it, and so does a run where every check was skipped, since then
#     nothing ran: at least one has to pass;
#   - with no checks reported yet, gh exits non-zero and nothing merges; in a
#     repository without CI it never merges.
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
repo=()
args=("$@")
for i in "${!args[@]}"; do
  case "${args[i]}" in
    -R | --repo) repo=(-R "${args[i + 1]:?-R needs owner/repo}") ;;
    --repo=*) repo=(-R "${args[i]#--repo=}") ;;
  esac
done

head=$(gh pr view "$pr" ${repo[@]+"${repo[@]}"} --json headRefOid --jq .headRefOid)
gh pr checks "$pr" ${repo[@]+"${repo[@]}"} --watch --fail-fast --interval 30
gh pr checks "$pr" ${repo[@]+"${repo[@]}"} --json bucket --jq \
  'if all(.[]; .bucket == "pass" or .bucket == "skipping") and any(.[]; .bucket == "pass") then empty else error("not every check passed, or none ran") end'
gh pr merge "$pr" --match-head-commit "$head" "$@"
