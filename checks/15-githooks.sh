# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Git hooks ────────────────────────────────────────────────────────────────
# The hooks in githooks/, driven by git itself against scratch repositories:
# a real push to a scratch bare remote, a real commit. Feeding a hook a
# hand-written stdin line would test it against a reading of git's protocol
# instead of against git. Each runs as a byte-identical copy in the scratch
# directory, with core.hooksPath pointing there on that one command: a hook
# that looked for check.sh beside itself would otherwise find this
# repository's, which runs this check again, which commits again -- a review
# saw nine nested levels in a minute and no verdict (2026-10-12).
#
# GIT_CONFIG_GLOBAL=/dev/null, as git/config asks of a suite that builds
# scratch repositories: without it each one starts an fsmonitor daemon that
# outlives the run, and the global signing and defaults leak into
# repositories meant to behave like a runner's.
printf '\n%sGit hooks%s\n' "$DIM" "$OFF"

pre_push_guard() {
  local tmp hooks out c1 c2 tip step
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  hooks="$tmp/hooks"
  mkdir "$hooks" && cp -p githooks/pre-push "$hooks/"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  g() { git -C "$tmp/work" -c user.name=t -c user.email=t@t "$@"; }
  push() { git -C "$tmp/work" -c core.hooksPath="$hooks" push -q origin "$@" 2>&1; }
  remote_tips() { git -C "$tmp/remote.git" for-each-ref --format='%(refname) %(objectname)'; }
  # An allowed push succeeds and the hook says nothing; -q silences git.
  allowed() {
    local case=$1
    shift
    out=$(push "$@") || {
      echo "$case: refused $*: $out"
      return 1
    }
    [ -z "$out" ] || {
      echo "$case: the hook printed on an allowed push of $*: $out"
      return 1
    }
  }
  # A refused push fails, says why, says how to push past the guard on
  # purpose, and leaves every ref on the remote where it was.
  refused() {
    local case=$1 why=$2 before
    shift 2
    before=$(remote_tips)
    if out=$(push "$@"); then
      echo "$case: allowed $*"
      return 1
    fi
    case "$out" in *$why*) ;; *)
      echo "$case: refused $* without saying \"$why\": $out"
      return 1
      ;;
    esac
    case "$out" in *"--no-verify --force-with-lease"*) ;; *)
      echo "$case: refused $* without saying how to push past it: $out"
      return 1
      ;;
    esac
    [ "$(remote_tips)" = "$before" ] || {
      echo "$case: a ref on the remote moved although $* was refused"
      return 1
    }
  }

  # The server's own default refuses deleting its current branch, which would
  # refuse `push :main` whatever the hook decided; with it neutral, every
  # refusal below is the hook's.
  git init -q --bare -b main "$tmp/remote.git"
  git -C "$tmp/remote.git" config receive.denyDeleteCurrent ignore
  git clone -q "$tmp/remote.git" "$tmp/work" 2> /dev/null
  g commit -q --allow-empty -m c1
  c1=$(g rev-parse HEAD)

  # No origin/HEAD yet, and the remote has no main: a first push is trivially
  # a fast-forward.
  allowed "first push" main || return 1

  # From here origin/HEAD names main, so the fallback is exercised only at
  # the end, where a broken fallback is named as such.
  g remote set-head origin main > /dev/null

  g commit -q --allow-empty -m c2
  c2=$(g rev-parse HEAD)
  allowed "fast-forward" main || return 1

  # A rewrite: c3 replaces c2, so c2 would stop existing on the remote.
  g reset -q --hard "$c1"
  g commit -q --allow-empty -m c3
  tip=$(g rev-parse HEAD)
  refused "non-fast-forward" "refusing to force-push main" --force main || return 1
  case "$out" in *"$c2"*"$tip"*) ;; *)
    echo "non-fast-forward: refused without naming both commits: $out"
    return 1
    ;;
  esac

  refused "deletion" "refusing to delete main" :main || return 1

  # Any other branch is the pusher's to rewrite or delete.
  for step in "$c2:refs/heads/feature" "+$tip:refs/heads/feature" ":feature"; do
    allowed "other branches" "$step" || return 1
  done

  # Several refs in one push: one refused ref refuses them all, wherever git
  # puts it among the hook's lines. Git hands them over sorted by remote ref
  # name, not in refspec order: a push of `side` then `main` reached the hook
  # main first (observed with git 2.56, 2026-10-12). aaa and zzz sort before
  # and after main by name and by refspec, so an allowed ref sits on each side
  # of the refused one whichever order git uses.
  allowed "multi-ref" "$c2:refs/heads/aaa" "$c2:refs/heads/zzz" || return 1
  refused "multi-ref" "refusing to force-push main" --force \
    "$tip:refs/heads/aaa" "$tip:refs/heads/main" "$tip:refs/heads/zzz" || return 1

  # The protected branch is the remote's default as origin/HEAD records it,
  # which is what the hook reads; the remote's own HEAD is never consulted.
  allowed "remote default" "$c2:refs/heads/trunk" || return 1
  g remote set-head origin trunk > /dev/null
  refused "remote default" "refusing to force-push trunk" --force "$tip:refs/heads/trunk" || return 1
  allowed "remote default" --force main || return 1
  g remote set-head origin -d
  refused "remote default unset" "refusing to force-push main" --force "$c2:refs/heads/main" || return 1
}
check "pre-push refuses deleting or rewriting the remote's default branch, and only that" pre_push_guard

# pre-commit judges the commit, not the working tree: the checks run in a
# throwaway tree holding exactly the index git hands the hook, in strict mode,
# and the commit is refused when they fail for any reason, with what they
# printed and how to bypass; on a pass the hook adds nothing. The working
# tree, the index of a refused commit and the stash are left as they were,
# and the throwaway tree is gone after every run, an interrupted one too.
#
# A stub check.sh committed in a scratch repository stands in for the checks
# (the throwaway tree holds only indexed files). It logs the directory it ran
# in, the HEAD it sees -- the current HEAD, which gitleaks diffs the staged
# content against -- and its arguments, and any GIT_ variable that reached it
# (none may: one left set lets the tree's git calls write the user's index),
# walks HEAD's history as gitleaks does, prints a marker, sends TERM to its parent when $HANG
# is set, and fails with the code in $CODE, or 1 when any file around it
# holds the reject marker -- spelled split in the stub, so the stub itself
# does not match.
pre_commit_gate() {
  local tmp hooks out repo top before after dir
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  hooks="$tmp/hooks"
  mkdir "$hooks" && cp -p githooks/pre-commit "$hooks/"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export LOG="$tmp/log" CODE="$tmp/code" HANG='' GITENV="$tmp/gitenv"
  repo="$tmp/repo"
  git init -q "$repo"
  cat > "$repo/check.sh" << 'STUB'
#!/bin/sh
echo "$(pwd -P) $(git rev-parse -q --verify HEAD || echo unborn) $*" >> "$LOG"
env | grep '^GIT_' >> "$GITENV"
echo "stub-checks-output"
if git rev-parse -q --verify HEAD > /dev/null; then
  git rev-list HEAD > /dev/null 2>&1 || exit 3
fi
[ -n "$HANG" ] && kill -TERM "$PPID"
code=$(cat "$CODE")
[ "$code" = 0 ] && grep -rqs --exclude-dir=.git "REJ""ECT" . && code=1
exit "$code"
STUB
  chmod +x "$repo/check.sh"
  echo ok > "$repo/verdict"
  g() { git -C "$repo" -c user.name=t -c user.email=t@t "$@"; }
  g add check.sh verdict && g commit -q -m base || return 1
  top=$(cd "$repo" && pwd -P)
  commit() { git -C "${CWD:-$repo}" -c user.name=t -c user.email=t@t -c core.hooksPath="$hooks" commit -q "$@" 2>&1; }
  # The directory the stub last ran in: the judging tree, which must not be
  # the repository and must be gone once the hook returns.
  judged_elsewhere() {
    dir=$(tail -1 "$LOG" | cut -d' ' -f1)
    case "$dir" in "$top" | "$top"/*)
      echo "$1: the checks ran in the repository, not in a tree of the commit"
      return 1
      ;;
    esac
    [ ! -e "$dir" ] || {
      echo "$1: the judging tree $dir was left behind"
      return 1
    }
  }
  # Contents, modification times to the nanosecond, untracked files and the
  # stash list; with "index", also the index's entries and HEAD, which only a
  # refused commit must leave alone. Entries, not the file's bytes: git itself
  # rewrites .git/index on a refused commit, same entries, new extension
  # (a hook that only exits 1 grew it from 110 to 129 bytes, git 2.56,
  # 2026-10-12).
  snapshot() {
    (
      cd "$repo" || exit 1
      git ls-files -o --exclude-standard
      find . -path ./.git -prune -o -type f -exec stat -f '%N %Fm' {} + | sort
      find . -path ./.git -prune -o -type f -exec shasum {} + | sort
      git stash list
      [ "${1:-}" = index ] && git ls-files -s && git rev-parse HEAD
    )
  }

  echo 0 > "$CODE"
  : > "$LOG"
  # A good verdict staged, a rejected edit left unstaged on top, a rejected
  # untracked file beside it: only the staged content counts, so it lands.
  echo ok2 > "$repo/verdict"
  g add verdict
  echo "REJ""ECT" > "$repo/verdict"
  echo "REJ""ECT" > "$repo/stray"
  g update-index -q --refresh > /dev/null
  local parent
  parent=$(g rev-parse HEAD)
  before=$(snapshot)
  out=$(commit -m good) || {
    echo "unstaged and untracked: refused a commit whose staged content passes: $out"
    return 1
  }
  after=$(snapshot)
  [ "$before" = "$after" ] || {
    echo "working tree: a passing run changed files, their times, untracked files or the stash:"
    diff <(echo "$before") <(echo "$after")
    return 1
  }
  [ "$out" = stub-checks-output ] || {
    echo "passing checks: the hook printed something other than exactly the checks' output: $out"
    return 1
  }
  [ "$(cut -d' ' -f3- "$LOG")" = --strict ] || {
    echo "strict mode: expected check.sh called once with --strict, got: $(cat "$LOG")"
    return 1
  }
  [ "$(cut -d' ' -f2 "$LOG")" = "$parent" ] || {
    echo "history: the judging tree's HEAD is not the commit's parent $parent: $(cat "$LOG")"
    return 1
  }
  judged_elsewhere "passing run" || return 1
  rm "$repo/stray"

  # A rejected verdict staged under a working copy that undoes it.
  echo ok3 > "$repo/verdict"
  cp "$repo/verdict" "$tmp/clean"
  echo "REJ""ECT" > "$repo/verdict"
  g add verdict
  cp "$tmp/clean" "$repo/verdict"
  g update-index -q --refresh > /dev/null
  before=$(snapshot index)
  if out=$(commit -m bad); then
    echo "staged content: let a commit land whose staged content the checks reject"
    return 1
  fi
  after=$(snapshot index)
  [ "$before" = "$after" ] || {
    echo "working tree: a refused run changed files, their times, the index, HEAD or the stash:"
    diff <(echo "$before") <(echo "$after")
    return 1
  }
  case "$out" in *stub-checks-output*"Commit aborted"*"--no-verify"*) ;; *)
    echo "failing checks: refused without showing the checks' output and how to bypass on purpose: $out"
    return 1
    ;;
  esac
  judged_elsewhere "refused run" || return 1
  g add verdict

  # Any failure refuses, a usage error (2) as much as a failed check (1).
  echo 2 > "$CODE"
  if out=$(commit --allow-empty -m usage); then
    echo "failing checks: let the commit land when check.sh exited 2"
    return 1
  fi
  echo 0 > "$CODE"

  # commit -a and commit <paths> hand the hook an index of their own.
  echo "REJ""ECT" > "$repo/verdict"
  if out=$(commit -a -m all); then
    echo "commit -a: judged the default index instead of the one commit -a builds"
    return 1
  fi
  if out=$(commit -m paths verdict); then
    echo "commit <paths>: judged the default index instead of the one for the paths"
    return 1
  fi
  echo ok3 > "$repo/verdict"

  # A linked worktree's commit is judged on that worktree's index.
  g worktree add -q "$tmp/linked" 2> /dev/null || return 1
  echo "REJ""ECT" > "$tmp/linked/verdict"
  git -C "$tmp/linked" add verdict
  if out=$(CWD="$tmp/linked" commit -m linked); then
    echo "linked worktree: let a rejected commit land"
    return 1
  fi
  echo ok4 > "$tmp/linked/verdict"
  git -C "$tmp/linked" add verdict
  out=$(CWD="$tmp/linked" commit -m linked) || {
    echo "linked worktree: refused a passing commit: $out"
    return 1
  }

  # Interrupted: the stub sends TERM to the process that started it.
  if out=$(HANG=1 commit --allow-empty -m interrupted); then
    echo "interrupted: let the commit land"
    return 1
  fi
  judged_elsewhere "interrupted run" || return 1

  # A split index: the index file is only the split part, so the tree's
  # index has to be rebuilt from the entries, not copied.
  g config core.splitIndex true
  g update-index --split-index
  echo "REJ""ECT" > "$repo/verdict"
  g add verdict
  if out=$(commit -m split); then
    echo "split index: let a rejected commit land"
    return 1
  fi
  echo ok5 > "$repo/verdict"
  g add verdict
  out=$(commit -m split) || {
    echo "split index: refused a passing commit: $out"
    return 1
  }
  g config core.splitIndex false
  g update-index --no-split-index

  # A sparse checkout's skip-worktree entry is still part of the commit.
  echo "REJ""ECT" > "$repo/verdict"
  g add verdict
  g update-index --skip-worktree verdict
  echo ok6 > "$repo/verdict"
  if out=$(commit -m sparse); then
    echo "skip-worktree: let a commit land whose skip-worktree entry the checks reject"
    return 1
  fi
  g update-index --no-skip-worktree verdict
  g add verdict

  # A shallow clone: the tree has to know where history stops.
  git clone -q --depth 1 "file://$repo" "$tmp/shallow" 2> /dev/null || return 1
  echo ok7 > "$tmp/shallow/verdict"
  git -C "$tmp/shallow" add verdict
  out=$(CWD="$tmp/shallow" commit -m shallow) || {
    echo "shallow clone: refused a passing commit: $out"
    return 1
  }

  # A first commit has no HEAD.
  git init -q "$tmp/first"
  cp "$repo/check.sh" "$tmp/first/"
  echo ok > "$tmp/first/verdict"
  git -C "$tmp/first" add check.sh verdict
  out=$(CWD="$tmp/first" commit -m first) || {
    echo "first commit: refused a passing first commit: $out"
    return 1
  }

  # A check.sh that is gone from the commit is a gate that cannot run.
  g rm -q check.sh
  if out=$(commit -m "no checks"); then
    echo "missing checks: let the commit land with no check.sh to run"
    return 1
  fi

  [ ! -s "$GITENV" ] || {
    echo "git environment: GIT_ variables reached the checks: $(sort -u "$GITENV" | tr '\n' ' ')"
    return 1
  }
}
check "pre-commit judges the commit in a throwaway tree, strictly, and leaves the working tree as it was" pre_commit_gate
