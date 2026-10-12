# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Git hooks ────────────────────────────────────────────────────────────────
# The hooks in githooks/, driven by git itself against scratch repositories:
# a real push to a scratch bare remote, a real commit, with core.hooksPath
# pointing here on that one command. Feeding a hook a hand-written stdin line
# would test it against a reading of git's protocol instead of against git.
#
# GIT_CONFIG_GLOBAL=/dev/null, as git/config asks of a suite that builds
# scratch repositories: without it each one starts an fsmonitor daemon that
# outlives the run, and the global hooks path, signing and defaults leak into
# repositories meant to behave like a runner's.
printf '\n%sGit hooks%s\n' "$DIM" "$OFF"

pre_push_guard() {
  local tmp hooks out c1 c2 tip step
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  hooks="$PWD/githooks"
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
