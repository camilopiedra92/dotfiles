# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# No `# covers:` line, so it runs for every change: gitleaks reads the
# history and the index, and the executable-bit check every tracked file.

# ── Lint ─────────────────────────────────────────────────────────────────────
printf '\n%sLint%s\n' "$DIM" "$OFF"

if command -v shellcheck > /dev/null 2>&1; then
  # -x follows sourced files, catching breakage across file boundaries.
  check "shellcheck" shellcheck -x ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/* ./macos/*.sh ./checks/*.sh ./checks/lib/*.sh
else
  skip "shellcheck" "brew install shellcheck"
fi

# shfmt reads .editorconfig, so the style lives there and not in flags here:
# the editor, this check and the hook cannot drift apart if there is only one
# definition to read.
if command -v shfmt > /dev/null 2>&1; then
  check "shfmt" shfmt -d ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/* ./macos/*.sh ./checks/*.sh ./checks/lib/*.sh
else
  skip "shfmt" "brew install shfmt"
fi

# The workflow was the one file here nothing checked, and a malformed one does
# not fail loudly: GitHub just declines to run it, so the symptom is checks
# that quietly stop happening. actionlint parses it, resolves runner labels and
# action inputs against what actually exists, flags untrusted `${{ }}` values
# interpolated into scripts, and runs shellcheck over every embedded `run`
# block — shell that would otherwise be linted nowhere.
if command -v actionlint > /dev/null 2>&1; then
  check "actionlint" actionlint
else
  skip "actionlint" "brew install actionlint"
fi

# actionlint finds broken workflows; zizmor finds exploitable ones: credentials
# left in .git/config, an over-broad App token, an untrusted value reaching a
# script. Offline on purpose: its online audits need a GitHub token and a
# network, so the same tree could pass here and fail in CI or the reverse, and
# a check that depends on where it runs is the drift check.sh exists to prevent.
if command -v zizmor > /dev/null 2>&1; then
  check "zizmor" zizmor --offline --no-progress .github
else
  skip "zizmor" "brew install zizmor"
fi

# A secret removed in a later commit is still published, so this reads history,
# not the tree. --staged adds what is about to be committed, which is the one
# moment a secret can still be stopped before it enters history.
secrets() {
  gitleaks git --no-banner --redact --log-level error . || return 1
  gitleaks git --staged --no-banner --redact --log-level error .
}
if command -v gitleaks > /dev/null 2>&1; then
  check "gitleaks" secrets
else
  skip "gitleaks" "brew install gitleaks"
fi

syntax_bash() { for f in ./*.sh ./bin/*.sh ./claude/*.sh ./githooks/* ./macos/*.sh ./checks/*.sh ./checks/lib/*.sh; do bash -n "$f" || return 1; done; }
check "bash syntax" syntax_bash

if command -v zsh > /dev/null 2>&1; then
  syntax_zsh() { for f in zsh/.zshenv zsh/.zprofile zsh/.zshrc; do zsh -n "$f" || return 1; done; }
  check "zsh syntax" syntax_zsh
else
  skip "zsh syntax" "zsh not installed"
fi

# The mode that matters lives in git, not on this machine: a fresh clone gets
# whatever the tree says, and `~/dotfiles/install.sh` -- the invocation the
# README documents -- then dies with permission denied. The bit is lost silently
# and by accident, by anything that replaces the file rather than editing it in
# place: an editor writing through a temp file, or a `mv` from /tmp, which is
# how it was lost here. Nothing else in this run would have noticed, because
# every check invokes these through `bash <file>` and that works at 644.
#
# The rule is the shebang, not the .sh suffix, and it is checked both ways.
# githooks/pre-commit has no suffix and must be executable; zsh/.zshenv has no
# shebang and must stay 644, since it is sourced and never run. A file that
# names an interpreter exists to be executed, and one that does not, does not.
exec_bits() {
  local bad=0 meta path mode first
  while IFS=$'\t' read -r meta path; do
    mode=${meta%% *}
    first=$(head -n1 "$path" 2> /dev/null)
    case "$first" in
      '#!'*)
        if [ "$mode" != 100755 ]; then
          echo "$path declares an interpreter but is $mode in git, so a clone cannot run it"
          bad=1
        fi
        ;;
      *)
        if [ "$mode" = 100755 ]; then
          echo "$path is executable in git but has no shebang"
          bad=1
        fi
        ;;
    esac
  done < <(this_repo_git ls-files -s)
  return "$bad"
}
check "tracked scripts are executable in git" exec_bits

# The index check.sh keeps for the calls about this repository (THIS_INDEX)
# has to be the one they read: an index in which install.sh lost its
# executable bit, as a `chmod -x` then `commit -a` would leave it, must fail
# exec_bits. Only a scratch index is written; read-tree and --chmod touch
# nothing else.
exec_bits_reads_the_commit_index() {
  local tmp
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  GIT_INDEX_FILE=$tmp/commit-index git read-tree HEAD &&
    GIT_INDEX_FILE=$tmp/commit-index git update-index --chmod=-x install.sh || return 1
  if THIS_INDEX=$tmp/commit-index exec_bits > /dev/null; then
    echo "exec_bits did not read the commit's index"
    return 1
  fi
}
check "exec_bits reads the index being committed" exec_bits_reads_the_commit_index
