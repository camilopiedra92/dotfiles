# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.
#
# The last case greps every section for calls that bypass this_repo_git.
# covers: claude/git-guard.sh claude/settings.json claude/mcp.json install.sh
# covers: drift.sh Brewfile uv-tools.txt macos/machines/* checks/[0-9][0-9]-*.sh

# ── Git guard ────────────────────────────────────────────────────────────────
# The guard exists because permission rules cannot express these decisions. A
# rule matches a command prefix, so `git push origin main --force` slips past
# `Bash(git push --force *)` -- git permutes flags and the matcher does not.
# And a deny rule cannot carry an exception, so blocking `git clean -fdx` would
# also block `git clean -n`, which destroys nothing and is how you check.
#
# Like the statusline, it is a pure function from a JSON payload to a verdict,
# which is the property that makes it testable rather than merely written.
printf '\n%sGit guard%s\n' "$DIM" "$OFF"

# Exit 2 is the block. Every other status falls through to the permission
# rules, which means a crashed guard fails open -- the reason the deny list
# still carries the operations that have no safe form at all.
# Absolute, because the reset cases run from a temp repository: a relative
# path there resolves to nothing, every call returns 127, and the tests pass
# while exercising the guard not at all. That is not hypothetical -- it is what
# the first run of these tests did, and only an inverted stub revealed it.
GUARD=$PWD/claude/git-guard.sh

# Runs a command without the variables a hook, or a shell, can hand git. The
# guard tests build a throwaway repository and ask git about it, and this
# script is run by the pre-commit hook: git hands that hook GIT_INDEX_FILE,
# and for `git commit -a` it is an absolute path to this repository's index
# lock. Inherited, it wins over the temp directory's own .git, so a clean temp
# tree reads as dirty and the guard blocks. Plain `git commit` passes a
# relative `.git/index`, which resolves inside the temp directory by accident
# -- every commit here since the guard tests landed was a plain one, and the
# first `-a` was refused. From the main checkout git exports neither GIT_DIR
# nor GIT_WORK_TREE; from a linked worktree it exports GIT_DIR (both measured
# with a hook that printed its environment). drop_hook_git_env clears all of
# them for the whole script; this clears them again at each call, for the
# check below that sets one at the call. The checks must mean the same thing run by hand, by
# the hook and in CI, so every git call that is about the throwaway
# repository goes through here -- and only those: `git ls-files` and `git
# grep` above are about this repository and must read the index the commit
# is being made from.
hookless() {
  env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE -u GIT_PREFIX "$@"
}

guard_verdict() {
  local payload rc
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1")
  printf '%s' "$payload" | hookless "$GUARD" > /dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 2 ]; then printf 'blocked'; else printf 'allowed'; fi
}

guard_decisions() {
  local want cmd got fails=0
  while IFS='|' read -r want cmd; do
    [ -z "$want" ] && continue
    got=$(guard_verdict "$cmd")
    if [ "$got" != "$want" ]; then
      printf 'want %s, got %s: %s\n' "$want" "$got" "$cmd"
      fails=1
    fi
  done << 'CASES'
blocked|git clean -fdx
blocked|git clean -f
blocked|git clean --force -d
blocked|mise exec -- git clean -fdx
blocked|git push --force origin main
blocked|git push origin main --force
blocked|git push -f origin main
blocked|git push --force-with-lease origin main
blocked|npm test && git clean -fdx
allowed|git clean -n
allowed|git clean --dry-run -d
allowed|git status
allowed|git push origin main
allowed|git push --force-with-lease origin feature/x
allowed|git log --oneline
allowed|echo git clean -fdx
allowed|git commit -m "clean -fdx"
CASES
  return "$fails"
}
check "guard verdicts match the table" guard_decisions

# The reset rule is the one that reads the repository rather than the command:
# `git reset --hard` with nothing uncommitted is a no-op, and blocking it is
# friction that buys nothing. These two cases differ only in whether work
# exists to lose, so a guard that ignored state would fail one of them.
guard_reset_clean_tree() {
  local dir out
  dir=$(mktemp -d)
  hookless git -C "$dir" init -q
  hookless git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  out=$(cd "$dir" && guard_verdict 'git reset --hard')
  rm -r "$dir"
  [ "$out" = allowed ] || {
    echo "clean tree should allow reset --hard, got $out"
    return 1
  }
}
check "reset --hard is allowed when nothing would be lost" guard_reset_clean_tree

guard_reset_dirty_tree() {
  local dir out
  dir=$(mktemp -d)
  hookless git -C "$dir" init -q
  hookless git -C "$dir" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  echo change > "$dir/tracked.txt"
  hookless git -C "$dir" add tracked.txt
  out=$(cd "$dir" && guard_verdict 'git reset --hard')
  rm -r "$dir"
  [ "$out" = blocked ] || {
    echo "dirty tree should block reset --hard, got $out"
    return 1
  }
}
check "reset --hard is blocked when it would discard work" guard_reset_dirty_tree

# The same verdict with the `git commit -a` hook environment in place: an
# absolute GIT_INDEX_FILE set at the call, which is what the hook does to this
# whole script. Only that variable -- the GIT_DIR a linked worktree's hook also
# gets is covered by hook_git_env_dropped below -- and the index belongs
# to a decoy repository built here, never to this one. The first version of
# this check set GIT_DIR to this repository's own .git, and while it was red
# the fixture's `commit --allow-empty -m init` landed three empty commits on
# two real branches. A test that mutates the thing it checks when it fails is
# worse than no test. The decoy tracks one file so that, judged through its
# index, the temp repository's empty tree reads as a deletion: without
# hookless the guard sees that and blocks.
#
# Both fixtures run this way, because they fail differently. The clean one
# reads the decoy's file as deleted and blocks, which the verdict shows. The
# dirty one's verdict is blocked either way -- a file git does not know about
# is uncommitted work too -- so its failure is not in the verdict but in the
# side effect: its `git add` is the one call here that writes into the
# foreign index, which under the real hook is the commit being made. So the
# decoy's index is read back afterwards and must still list only its own file.
guard_tests_under_hook() {
  local decoy out rc=0 listed
  decoy=$(mktemp -d)
  hookless git -C "$decoy" init -q
  echo x > "$decoy/decoy.txt"
  hookless git -C "$decoy" add decoy.txt
  hookless git -C "$decoy" -c user.email=t@t -c user.name=t commit -q -m init
  out=$(GIT_INDEX_FILE="$decoy/.git/index" guard_reset_clean_tree 2>&1 &&
    GIT_INDEX_FILE="$decoy/.git/index" guard_reset_dirty_tree 2>&1) || rc=$?
  listed=$(hookless git -C "$decoy" ls-files)
  rm -r "$decoy"
  [ "$rc" -eq 0 ] || {
    echo "under a hook's git environment: $out"
    return 1
  }
  [ "$listed" = decoy.txt ] || {
    echo "the dirty fixture wrote into the foreign index: $listed"
    return 1
  }
}
check "the guard tests ignore the git environment a hook exports" guard_tests_under_hook

# The variables git hands a hook from a linked worktree -- GIT_DIR and an
# absolute GIT_INDEX_FILE -- pointed at a decoy repository's worktree, then a
# throwaway repository built and committed to, as the sdd-init check does.
# After drop_hook_git_env the decoy must be untouched and the index kept for
# the calls about this repository. Never this repository: a
# check that mutates what it checks when it fails is worse than none.
hook_git_env_dropped() {
  local tmp wt before after
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  git init -q "$tmp/decoy"
  git -C "$tmp/decoy" -c user.name=t -c user.email=t@t commit -q --allow-empty -m root
  git -C "$tmp/decoy" worktree add -q "$tmp/wt" 2> /dev/null
  wt=$(git -C "$tmp/wt" rev-parse --absolute-git-dir)
  # A file, not process substitution: macOS's bash 3.2 cannot source the latter.
  sed -n '/^drop_hook_git_env() {/,/^}/p' check.sh > "$tmp/drop.sh"
  before=$(cd "$tmp/decoy" && git config --list --local && git for-each-ref && cksum < "$wt/index")
  # Also two of the variables git hands a hook for `git -c ... commit` and
  # `git --literal-pathspecs commit`, which change what a pathspec means.
  # And one no git version sets yet: the rule is every GIT_ variable, not a list.
  out=$(GIT_DIR=$wt GIT_INDEX_FILE=$wt/index GIT_LITERAL_PATHSPECS=1 \
    GIT_CONFIG_PARAMETERS="'core.bare'='true'" GIT_NOT_YET_INVENTED=1 bash -c '
    . "'"$tmp"'/drop.sh"
    drop_hook_git_env
    [ "$THIS_INDEX" = "'"$wt"'/index" ] || echo "the commit index was not kept: $THIS_INDEX"
    env | grep "^GIT_" | grep -vxE "GIT_CONFIG_(GLOBAL=/dev/null|NOSYSTEM=1)" | sed "s/^/still set: /"
    [ "${GIT_CONFIG_GLOBAL:-}" = /dev/null ] || echo "git still reads the global config"
    git init -q "'"$tmp"'/throwaway"
    echo x > "'"$tmp"'/throwaway/f"
    git -C "'"$tmp"'/throwaway" add f
    git -C "'"$tmp"'/throwaway" -c user.name=t -c user.email=t@t commit -q -m x
  ' 2>&1)
  after=$(cd "$tmp/decoy" && git config --list --local && git for-each-ref && cksum < "$wt/index")
  [ -z "$out" ] || {
    echo "$out"
    return 1
  }
  [ "$before" = "$after" ] || {
    echo "a throwaway repository's git calls reached the decoy:"
    diff <(echo "$before") <(echo "$after")
    return 1
  }
  # The function is only half of it: this script has to run it, at top level.
  grep -qx 'drop_hook_git_env' check.sh || {
    echo "check.sh never calls drop_hook_git_env"
    return 1
  }
  # That the kept index is the one the calls about this repository read is
  # checked beside exec_bits, in the lint section.
  # Every other call about this repository goes through this_repo_git too:
  # no bare `git ls-files` or `git grep` outside a comment or a `git -C`.
  # Matched anywhere on a line on purpose. A pattern for where a command
  # starts was tried and missed `if git grep`, `while`, `{` and backticks --
  # a silent miss; anywhere-on-the-line can only err loudly, on prose such as
  # a check's title, which then names the thing another way.
  out=$(grep -nE '^[^#]*(^|[^_-])git (ls-files|grep)' check.sh checks/*.sh | grep -v -- 'git -C' || true)
  [ -z "$out" ] || {
    echo "a call about this repository bypasses this_repo_git:"
    echo "$out"
    return 1
  }
}
check "checks that build throwaway repositories ignore a linked worktree hook's git environment" hook_git_env_dropped

# A guard that is not wired runs never, and because it fails open that costs
# nothing visible: no error, no warning, just no guard. The tests above prove
# the script decides correctly; this one proves the settings ask it to.
guard_is_declared() {
  python3 - << 'DECL'
import json
import sys

settings = json.load(open('claude/settings.json', encoding='utf-8'))
entries = settings.get('hooks', {}).get('PreToolUse', [])
commands = [
    hook.get('command', '')
    for entry in entries
    for hook in entry.get('hooks', [])
]
if not any('git-guard.sh' in command for command in commands):
    print('claude/settings.json declares no PreToolUse hook running git-guard.sh')
    sys.exit(1)
DECL
}
check "the guard is wired into settings" guard_is_declared

# The settings merge replaces arrays whole, which is deliberate for `deny` and
# destructive for `hooks`: this machine carries PreToolUse entries from other
# tools, and a wholesale replace deletes them without saying so. It very
# nearly did -- a dry run of the merge returned a PreToolUse array holding the
# guard and nothing else. Twice, because installing must be repeatable: the
# guard appears once however many times you run it.
install_preserves_foreign_hooks() {
  local tmp steps live commands count
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  steps="$tmp/steps.sh"
  {
    # shellcheck disable=SC2016,SC2028  # written verbatim, expanded when it runs
    echo 'log() { printf "==> %s\n" "$1"; }'
    sed -n '/^# --- 3\. Symlinks/,/^# --- 3c\./p' install.sh
  } > "$steps"

  live="$tmp/home/.claude/settings.json"
  mkdir -p "$tmp/home/.claude"
  cat > "$live" << 'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [{ "type": "command", "command": "/opt/other-tool/hook.sh" }]
      }
    ]
  }
}
JSON

  # Into a copy, for the reason given in install_is_idempotent.
  rsync -a --exclude .git "$PWD/" "$tmp/dotfiles/" || return 1
  HOME="$tmp/home" DOTFILES="$tmp/dotfiles" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1
  HOME="$tmp/home" DOTFILES="$tmp/dotfiles" bash -euo pipefail "$steps" > /dev/null 2>&1 || return 1

  commands=$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command] | join(" ")' "$live")
  case "$commands" in
    *other-tool*) ;;
    *)
      echo "the merge dropped a PreToolUse hook this repo does not own: $commands"
      return 1
      ;;
  esac

  count=$(jq '[.hooks.PreToolUse[]?.hooks[]? | select(.command | test("git-guard"))] | length' "$live")
  [ "$count" = 1 ] || {
    echo "expected the guard exactly once after two installs, found $count"
    return 1
  }
}
check "installing keeps hooks this repo does not own" install_preserves_foreign_hooks

# The merge never deletes, so a key the repo declares can still vanish from the
# live file afterwards -- `/model` clearing `model` did exactly that, and drift.sh
# reported nothing because it only looked at keys present on both sides. Run its
# settings check against fixtures: one key missing from the live file, one
# missing key the check excludes on purpose, and one that matches.
drift_reports_missing_settings() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn="$tmp/fn.sh"
  # Up to the heredoc terminator: the Python inside closes its own braces at
  # column 0, so the function's `}` is not the first one.
  {
    sed -n '/^claude_settings_drift() {$/,/^PY$/p' drift.sh
    echo '}'
  } > "$fn"
  grep -qF 'LOCAL_ONLY' "$fn" || {
    echo "could not extract claude_settings_drift from drift.sh"
    return 1
  }

  mkdir -p "$tmp/repo/claude" "$tmp/home/.claude"
  echo '{"theme": "dark", "model": "opus", "hooks": {}}' > "$tmp/repo/claude/settings.json"
  echo '{"theme": "dark"}' > "$tmp/home/.claude/settings.json"

  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cd "$tmp/repo" && HOME="$tmp/home" bash -c '. "$1" && claude_settings_drift' _ "$fn") || return 1
  [ "$out" = 'model: repo says "opus", this machine does not set it' ] || {
    echo "expected one line about model, got: ${out:-nothing}"
    return 1
  }
}
check "drift.sh reports a declared setting missing from this machine" drift_reports_missing_settings

# A server only one profile declares is declared all the same. Against fixtures:
# registered servers matching both manifests report nothing, and one the
# profile declares but this machine lacks is named.
drift_counts_profile_mcp_servers() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn="$tmp/fn.sh"
  {
    sed -n '/^mcp_servers_drift() {$/,/^MCP$/p' drift.sh
    echo '}'
  } > "$fn"
  grep -qF 'mcpServers' "$fn" || {
    echo "could not extract mcp_servers_drift from drift.sh"
    return 1
  }

  mkdir -p "$tmp/repo/claude" "$tmp/machine" "$tmp/home"
  echo '{"mcpServers": {"shared": {"type": "http", "url": "https://s.invalid"}}}' > "$tmp/repo/claude/mcp.json"
  echo '{"mcpServers": {"local": {"type": "stdio", "command": "l", "args": []}}}' > "$tmp/machine/mcp.json"
  echo '{"mcpServers": {"shared": {"type": "http", "url": "https://s.invalid"}, "local": {"type": "stdio", "command": "l", "args": []}}}' > "$tmp/home/.claude.json"

  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cd "$tmp/repo" && HOME="$tmp/home" machine_dir="$tmp/machine" bash -c '. "$1" && mcp_servers_drift' _ "$fn") || return 1
  [ -z "$out" ] || {
    echo "expected no drift with both manifests registered, got: $out"
    return 1
  }

  echo '{"mcpServers": {"shared": {"type": "http", "url": "https://s.invalid"}}}' > "$tmp/home/.claude.json"
  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cd "$tmp/repo" && HOME="$tmp/home" machine_dir="$tmp/machine" bash -c '. "$1" && mcp_servers_drift' _ "$fn") || return 1
  [ "$out" = 'declared but not registered: local' ] || {
    echo "expected the profile's server reported missing, got: ${out:-nothing}"
    return 1
  }
}
check "drift.sh counts the profile's MCP servers as declared" drift_counts_profile_mcp_servers

# A cask the profile's Brewfile declares is declared: reported as drift, it
# would send the owner to add to the shared Brewfile what the profile exists
# to keep out of it.
drift_counts_profile_brewfile() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn="$tmp/fn.sh"
  sed -n '/^declared() /p' drift.sh > "$fn"
  grep -qF 'Brewfile' "$fn" || {
    echo "could not extract declared from drift.sh"
    return 1
  }
  mkdir -p "$tmp/repo" "$tmp/machine" "$tmp/bare"
  printf 'brew "bat"\ncask "ghostty"\n' > "$tmp/repo/Brewfile"
  printf 'cask "rectangle"\ncask "someone/tap/pinned@1.2"\n' > "$tmp/machine/Brewfile"

  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cd "$tmp/repo" && machine_dir="$tmp/machine" bash -c '. "$1" && declared cask' _ "$fn" | paste -sd, -) || return 1
  # brew list --cask names a tapped cask by its token, without the tap, so a
  # declaration written with the tap has to be compared without it.
  [ "$out" = "ghostty,pinned@1.2,rectangle" ] || {
    echo "expected both Brewfiles' casks, tap prefix dropped, got: ${out:-nothing}"
    return 1
  }
  # shellcheck disable=SC2016  # expanded by the inner shell
  out=$(cd "$tmp/repo" && machine_dir="$tmp/bare" bash -c '. "$1" && declared cask' _ "$fn") || return 1
  [ "$out" = "ghostty" ] || {
    echo "a profile with no Brewfile changed the answer: ${out:-nothing}"
    return 1
  }
}
check "drift.sh counts the profile's Brewfile as declared" drift_counts_profile_brewfile

# A pin and the machine can disagree in two directions, and they close in
# opposite ways. When `specify self upgrade` moved the machine past the pin,
# drift.sh said "./install.sh", and running it put the old version back. So:
# machine ahead -> move the pin; machine behind -> install. Against a stub `uv`
# whose tool dir holds one receipt.
drift_uv_pin_direction() {
  local tmp fn out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  fn="$tmp/fn.sh"
  {
    sed -n '/^uv_tools_drift() {$/,/^PY$/p' drift.sh
    echo '}'
  } > "$fn"
  grep -qF 'uv-receipt.toml' "$fn" || {
    echo "could not extract uv_tools_drift from drift.sh"
    return 1
  }

  mkdir -p "$tmp/repo" "$tmp/bin" "$tmp/tools/demo"
  printf '#!/bin/sh\necho %s/tools\n' "$tmp" > "$tmp/bin/uv"
  chmod +x "$tmp/bin/uv"
  echo 'demo  git+https://example.invalid/demo.git@v1.9.0' > "$tmp/repo/uv-tools.txt"

  receipt() {
    printf '[tool]\nrequirements = [{ name = "demo", git = "%s?rev=%s" }]\n' "$1" "$2" \
      > "$tmp/tools/demo/uv-receipt.toml"
  }
  drift() {
    # shellcheck disable=SC2016  # expanded by the inner shell
    (cd "$tmp/repo" && PATH="$tmp/bin:$PATH" bash -c '. "$1" && uv_tools_drift' _ "$fn")
  }

  # 1.10 against 1.9: ahead by number, behind as a string, so this is the case
  # that tells the two comparisons apart.
  receipt https://example.invalid/demo.git v1.10.0
  out=$(drift) || return 1
  case "$out" in
    *'this machine is ahead'*'uv-tools.txt'*'downgrade'*) ;;
    *)
      echo "machine ahead of the pin, expected the pin moved and a downgrade warning, got: ${out:-nothing}"
      return 1
      ;;
  esac

  # Behind, the same tag spelled shorter, and a higher tag from another
  # repository all close with an install: only the same source can be ahead.
  for case in 'https://example.invalid/demo.git v1.8.0' \
    'https://example.invalid/demo.git v1.9.0.0' \
    'https://example.invalid/fork.git v2.0.0'; do
    # shellcheck disable=SC2086  # two words on purpose
    receipt $case
    out=$(drift) || return 1
    case "$out" in
      *'is ahead'*)
        echo "$case: expected ./install.sh, got: $out"
        return 1
        ;;
      *': ./install.sh') ;;
      *)
        echo "$case: expected ./install.sh, got: ${out:-nothing}"
        return 1
        ;;
    esac
  done
}
check "drift.sh says which way a moved uv pin closes" drift_uv_pin_direction
