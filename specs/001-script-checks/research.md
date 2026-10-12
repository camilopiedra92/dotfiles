# Research: Checks for the scripts with logic and no check

Each decision below names what was chosen, why, and what lost.

## R1. Where the checks live

- **Decision**: `githooks/pre-commit` and `githooks/pre-push` in a new
  `checks/15-githooks.sh`; `bump-tools.sh` at the end of
  `checks/20-tool-versions.sh`; `bin/dev-nuke.sh` in a new
  `checks/55-dev-nuke.sh`.
- **Rationale**: `checks/` is one file per area, sourced in name order. The
  hooks are an area of their own, and they sit beside lint because they gate
  commits the way lint does. `bump-tools.sh` moves the very pins
  `20-tool-versions.sh` compares against. The reset is an area of its own, and
  numbered after install because it is a machine-side script like install's.
- **Alternatives**: everything in one new file (lost: it mixes three areas,
  which the split in #133 undid); the hooks in `80-git-guard.sh` (lost: that
  area is Claude Code's git guard, a different mechanism).

## R2. Driving the push guard

- **Decision**: a real `git push` from a scratch clone to a scratch bare
  remote, with `git -c core.hooksPath=<repo>/githooks` on the push alone.
- **Rationale**: it proves the stdin format git hands the hook and the
  `origin/HEAD` lookup, which feeding the hook a hand-written line cannot.
  Setting the hooks path only on the push keeps the scratch commits free of
  the pre-commit hook.
- **Alternatives**: piping a line to the hook directly (lost: it checks the
  hook against my reading of git's protocol, not against git).
- **Fixtures**: the default branch is set with `git remote set-head origin
  <branch>` in the clone, since `refs/remotes/origin/HEAD` is what the hook
  reads; the unknown-default case removes it with `set-head -d`. The bare
  remote sets `receive.denyDeleteCurrent ignore`: git's default refuses
  deleting the remote's current branch on the server, which would make the
  deletion case pass whatever the hook decided. A multi-ref push puts an
  allowed ref on each side of the refused one by name, because git hands the
  refs to the hook sorted by remote ref name, not in refspec order (observed
  with git 2.56, 2026-10-12). Every allowed push must print nothing; every
  refusal must name its reason, give the bypass hint, and leave every remote
  ref where it was.

## R3. Driving the commit gate

- **Decision**: a scratch repository holding a stub `check.sh` that records
  its canonical path and arguments, prints a marker and exits with a code
  read from a file; a real `git commit` with `core.hooksPath` pointing at a
  byte-identical copy of the hook in the scratch directory (both hooks are
  run that way). Cases: passing checks land with only the checks' output;
  exits 1 and 2 refuse, showing that output and the bypass; a missing
  `check.sh` refuses.
- **Rationale**: the hook resolves `check.sh` from the repository being
  committed to, so the stub stands in without touching the hook. The copy
  matters: run from `githooks/`, a hook that looked for `check.sh` beside
  itself found this repository's, which reran this check and recursed (nine
  levels in a minute, no verdict, seen in review 2026-10-12). The path is
  compared canonically because git runs hooks from the top level with a
  canonical `PWD`, so `./check.sh` is an equivalent spelling, not a break.
- **Alternatives**: running this repository's own `check.sh` under the hook
  (lost: recursive, slow, and its verdict is not under the check's control).

## R4. Driving the pin updater

- **Decision**: a scratch directory holding a byte-identical copy of
  `bump-tools.sh`, synthetic `.github/workflows/ci.yml` and
  `.github/tool-checksums.txt` with the seven pins, and stub `gh` and `curl`
  first on `PATH`. `gh` answers from a table of latest versions; `curl` writes
  bytes derived from the URL, or fails for URLs listed as missing. `shasum` is
  the real one, so the expected hash is computed the same way. The "moved"
  case moves all seven tools against URLs and artifact names written out
  literally, so every entry of the script's per-tool tables is checked;
  Ghostty is pinned at 1.10.0 with tags that only a release-shaped filter and
  a version sort resolve.
- **Rationale**: the script `cd`s to its own directory, so a copy runs against
  the fixtures unmodified. Synthetic pins keep the check independent of
  today's versions.
- **Alternatives**: a symlink to the real script (lost in review: a later
  version resolving its link before `cd` would reach this repository's real
  pins); copies of the real `ci.yml` (lost: the check would change meaning
  with every bump); a flag pointing the script at other files (lost: an
  option only the check needs). A first version moved two tools and derived
  the expected names with the script's own shapes; review showed five tools'
  table entries and the Ghostty filter surviving mutation.

## R5. Driving the machine reset without touching the machine

- **Decision**: a hermetic `PATH`: a scratch `bin/` holding stubs for every
  command that acts on the machine or reads its identity (`id`, `dscl`,
  `stat`, `sudo`, `pgrep`, `kill`, `sleep`, `osascript`, `brew`,
  `dscacheutil`, `killall`, `purge`) and symlinks to the harmless utilities
  the script needs (`awk`, `cat`, `date`, `dirname`, `mkdir`, `tee`, `tr`,
  `xargs`), and nothing else. `rm` is a guarded stub: it logs every call and
  removes a path only inside the scratch directory, so even a script that
  ignores the socket default (R6) cannot delete the real socket. Each stub appends what it was asked to a
  calls log. `sudo -u USER cmd…` logs the user and runs `cmd…`; `kill` is
  reached through `xargs`, which runs it from `PATH`. `pgrep` answers from a
  process table file and `kill -TERM` removes the processes marked as obeying
  it, so survivors are a fixture choice.
- **Rationale**: a stub-first `PATH` that falls through to the real one would
  let a command the stubs forgot — today's or one added later — act on the
  machine. With a hermetic `PATH` it fails as "command not found" instead, so
  the check can never be the thing that kills a process or purges memory.
- **Alternatives**: stubs first on the inherited `PATH` (lost for the reason
  above); running inside a VM or container (lost: none exists here, and macOS
  commands are the point).

## R6. The socket path

- **Decision**: the script reads the socket path as
  `${DEV_NUKE_PG_SOCKET:-/tmp/.s.PGSQL.5432}`; the check points it into its
  scratch directory. This is the one change to any script (FR-005).
- **Rationale**: `[ -e ]` is a shell builtin, so no stub can answer it, and
  `/tmp/.s.PGSQL.5432` is shared: on a laptop with Postgres running it is a
  live socket the check must not remove, and the check would mean different
  things on a laptop and a runner. Under `sudo`, `env_reset` drops the
  variable unless kept on purpose, so a normal `sudo dev-nuke` always acts on
  the default; and whoever can keep it already has root, so it grants nothing.
- **Alternatives**: asserting only that `rm` was asked for the exact path
  (lost: whether it is asked depends on the real `/tmp`); a `--socket` flag
  (lost: a user-facing option nobody needs, where an environment default
  stays invisible).

## R7. Naming the failed scenario

- **Decision**: one `check` per story, titled with what it guarantees, and
  each failure echoing the scenario's case in words, the convention every
  existing check follows.
- **Alternatives**: one `check` per scenario (lost: 24 lines in the gate's
  output for four scripts, against the grain of the existing files).
