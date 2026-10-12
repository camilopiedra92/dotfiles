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
  local tmp hooks out c1 c2 tip
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  hooks="$PWD/githooks"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  g() { git -C "$tmp/work" -c user.name=t -c user.email=t@t "$@"; }
  push() { git -C "$tmp/work" -c core.hooksPath="$hooks" push -q origin "$@" 2>&1; }
  remote_tip() { git -C "$tmp/remote.git" rev-parse -q --verify "refs/heads/$1"; }

  git init -q --bare -b main "$tmp/remote.git"
  git clone -q "$tmp/remote.git" "$tmp/work" 2> /dev/null
  g commit -q --allow-empty -m c1
  c1=$(g rev-parse HEAD)

  # No origin/HEAD yet, so main is protected by the fallback, and the remote
  # has no main: a first push is trivially a fast-forward.
  out=$(push main) || {
    echo "first push: refused the first push of main: $out"
    return 1
  }
  case "$out" in *force-with-lease*)
    echo "hint: printed on an allowed push: $out"
    return 1
    ;;
  esac

  # From here origin/HEAD names main, so the fallback is exercised only at
  # the end, where a broken fallback is named as such.
  g remote set-head origin main > /dev/null

  g commit -q --allow-empty -m c2
  c2=$(g rev-parse HEAD)
  out=$(push main) || {
    echo "fast-forward: refused a fast-forward push to main: $out"
    return 1
  }

  # A rewrite: c3 replaces c2, so c2 would stop existing on the remote.
  g reset -q --hard "$c1"
  g commit -q --allow-empty -m c3
  tip=$(g rev-parse HEAD)
  if out=$(push --force main); then
    echo "non-fast-forward: allowed a force push to main"
    return 1
  fi
  case "$out" in *"refusing to force-push main"*"$c2"*"$tip"*) ;; *)
    echo "non-fast-forward: refused without naming both commits: $out"
    return 1
    ;;
  esac
  case "$out" in *"--no-verify --force-with-lease"*) ;; *)
    echo "hint: refused without saying how to push past it: $out"
    return 1
    ;;
  esac
  [ "$(remote_tip main)" = "$c2" ] || {
    echo "non-fast-forward: the remote's main moved although the push was refused"
    return 1
  }

  if out=$(push :main); then
    echo "deletion: allowed deleting main"
    return 1
  fi
  case "$out" in *"refusing to delete main"*) ;; *)
    echo "deletion: refused without saying main would be deleted: $out"
    return 1
    ;;
  esac

  # Any other branch is the pusher's to rewrite or delete.
  local step
  for step in "$c2:refs/heads/feature" "+$tip:refs/heads/feature" ":feature"; do
    out=$(push "$step") || {
      echo "other branches: refused $step: $out"
      return 1
    }
  done

  # Several refs in one push: one refused ref refuses them all, wherever git
  # puts it among the hook's lines. Git does not keep refspec order there: a
  # push of a new `side` and an existing `main` reached the hook main first
  # (observed with git 2.56, 2026-10-12). aaa and zzz exist on the remote and
  # sort before and after main by name and by refspec, so an allowed ref sits
  # on each side of the refused one whichever order git uses.
  out=$(push "$c2:refs/heads/aaa" "$c2:refs/heads/zzz") || {
    echo "multi-ref: could not create aaa and zzz: $out"
    return 1
  }
  if out=$(push --force "$tip:refs/heads/aaa" "$tip:refs/heads/main" "$tip:refs/heads/zzz"); then
    echo "multi-ref: allowed rewriting main beside allowed refs"
    return 1
  fi
  if [ "$(remote_tip aaa)" != "$c2" ] || [ "$(remote_tip zzz)" != "$c2" ]; then
    echo "multi-ref: aaa or zzz moved although main in the same push was refused"
    return 1
  fi

  # The protected branch is the remote's default, read from origin/HEAD.
  out=$(push "$c2:refs/heads/trunk") || {
    echo "remote default: could not create trunk: $out"
    return 1
  }
  g remote set-head origin trunk > /dev/null
  if out=$(push --force "$tip:refs/heads/trunk"); then
    echo "remote default: allowed rewriting trunk while origin/HEAD names it"
    return 1
  fi
  out=$(push --force main) || {
    echo "remote default: protected main although origin/HEAD names trunk: $out"
    return 1
  }
  g remote set-head origin -d
  if out=$(push --force "$c2:refs/heads/main"); then
    echo "remote default: allowed rewriting main with origin/HEAD unset"
    return 1
  fi
}
check "pre-push refuses deleting or rewriting the remote's default branch, and only that" pre_push_guard
