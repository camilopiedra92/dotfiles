# Contract: `sdd-run`

`bin/sdd-run.sh`, linked as `~/.local/bin/sdd-run` by `install.sh`. Run from a
repository's root.

## Commands

| Command | Does |
|---|---|
| `sdd-run start --from <feature dir>` | as `start`, with `-i spec=<feature dir>/spec.md` instead of a description, for a feature whose run died: `resume_from` set to the first phase not in `.sdd/phases.json`; refused when no phase is finished (FR-022). The run works on that feature: Spec Kit's per-worktree pointer `.specify/feature.json` is set to it (a repository that tracks the pointer must already name it), and the bundle records it |
| `sdd-run start "<description>"` | `sdd-step cleanup`, the prerequisites below, unsets `CLAUDE_CODE_EFFORT_LEVEL` (research R14), merges and validates the routing layers (contracts/routing.md), applying `--set` overrides, generates the run id, writes the run bundle (contracts/routing.md) and exports `SDD_RUN_DIR`, starts the egress proxy (contracts/pass.md), sets `SPECKIT_WORKFLOW_RUN_ID` and `SDD_STEP` (the absolute path of `sdd-step` from `tools.json`), then runs `specify workflow run sdd-routed -i spec=<description>` as its child and stops the egress proxy when it exits |
| `sdd-run resume <run_id> [<verdict>]` | `sdd-step cleanup`, the same checks, the run's bundle reused unchanged and `SDD_RUN_DIR` exported, then runs `specify workflow resume <run_id>` as its child, stopping the egress proxy when it exits, binding the verdict to the input of the gate the run is paused at; with no verdict, for a run paused outside a gate (Ctrl-C), it resumes the interrupted step |
| `sdd-run routing [--set <phase>.<field>=<value> …] [--init-local]` | prints the effective routing table for this repository, each value with its layer; `--init-local` creates the git-ignored local layer (contracts/routing.md) |
| `sdd-run resume <run_id> retry` | for a run stopped at `fix_stuck` or `converge_stuck`, at any nesting (`convergence:fix_loop:<j>:fix_stuck:<i>`): writes the one-shot verdict `$SDD_RUN_DIR/verdicts/retry`, which the next `sdd-step stuck` consumes and deletes, then resumes — exactly one more round |
| `sdd-run abort <run_id>` | ends a run stopped for the owner: records it aborted in the bundle, removes its containers, network and exports, and leaves the feature's worktree as it is; a finished run is left as it is, and said so |
| `sdd-run usage <run_id>` | from the run's `usage.jsonl` (contracts/routing.md): per model, every attempt's reported cost; attempts with a start and no end, or no usage, listed as unreported; the provider's tokens priced from `models.json`; the totals |

## As built (T038, 2026-10-21)

- `bin/sdd-run.sh` checks that `/usr/bin/python3` runs, then hands over to
  `bin/sdd-run.py` on it. YAML (the routing layers, the workflow) is read
  with `check-jsonschema`'s own interpreter, which carries `ruamel.yaml`: a
  host tool this feature already declares, so the system Python needs no
  YAML library.
- Order of `start`: the prerequisites, the layers merged and validated, the
  bundle written (`lock.json` atomically: run id, pid, its `LC_ALL=C ps -o
  lstart=` start time and the worktree; the code the run executes frozen
  under `code/`, research R28), the run linked as
  `~/.local/state/sdd/runs/<run_id>`, then `sdd-step cleanup`, then `sdd-step
  prepare-worker` — before the proxy, which runs on the worker image —, then
  the egress proxy (in a session of its own, so a Ctrl-C
  meant for Spec Kit does not reach it), answering once it has written
  `proxy.json` and `proxy-ca.pem`, its heartbeat touched every 2 seconds
  while Spec Kit runs, and stopped with SIGTERM when Spec Kit exits.
- Run ids: twelve random hex digits, never one the registry or this
  repository holds, so they are unique across repositories.
- One run at a time in a worktree: `start` refuses while another run of it is
  paused, stopped, failed or running, naming it and the two commands that end
  it, and while another run's process is alive whatever Spec Kit holds for it
  — none yet during cleanup, `prepare-worker` and the proxy's start; a run
  whose process died is the cleanup's to finish, not a blocker.
- A run belongs to its worktree: `resume` and `abort` from another worktree of
  the repository refuse, naming the run's, before writing anything.
- `finished.json` (`outcome`: `completed`, `rejected`, `aborted`, `died`, `not
  started`) is written when a run completes, is rejected at a checkpoint (the
  engine's `aborted`), is aborted, dies mid-step (Spec Kit still
  records it `running` and its process is gone — `sdd-step cleanup` finds it)
  or fails before Spec Kit starts; its registry link goes with it, and
  cleanup drops links whose bundle is gone or finished. A paused or stopped
  run is not finished: its process is gone too, but `resume` takes it up.
- `resume` of a run that died: refused, naming `sdd-run start --from <feature
  dir>` with the run's own feature and the phases that will run again, or, for
  a run that died before its specify made a feature, starting it anew. `resume` reuses the bundle as it
  is, rewrites only the lock, and refuses when the run's worker image is gone
  or when the worktree's `.specify/feature.json` no longer names the run's
  feature. It checks only Spec Kit's version, the runtime and the token: the
  engine resumes from the run's own copy of the workflow
  (`.specify/workflows/runs/<id>/workflow.yml`), whose gates `sdd-run` reads
  too, so an installed workflow of another version does not stop it.
- The run's feature is the bundle's `feature.json`, written by `start --from`
  with the feature it names, or by the run's specify pass beside the pointer
  it writes (`sdd-pass`); never read off the worktree's
  `.specify/feature.json`, which an earlier run may have left (research R28).
  After Spec Kit exits, the bundle's `routing.json` is copied to that
  feature's `.sdd/routing.json`, once the bundle names one.
- `sdd-run routing` prints one line per phase and field: phase, field, value,
  layer. `sdd-run usage` prints one line per model (attempts and cost, and
  DeepSeek's tokens), one `unreported` line naming each attempt with no end
  or no usage, and the total.

## Prerequisites checked by `start` and `resume`

Each missing one stops with exit 1 and one line naming it and how to provide
it, before any step runs:

- `specify version` is 1.2.2 or newer (else: the `uv-tools.txt` pin and
  `./install.sh`, FR-024);
- the current directory is the root of a git repository with `.specify/`;
- `sdd-routed` is installed in it, at this repository's version (else: the
  `specify workflow add` command that updates it);
- `specify`, `sdd-step`, `check-jsonschema` and `git` found on the owner's
  `PATH`, resolved once from the bundle's directory and frozen as absolute
  paths in the bundle's `tools.json`, which every later host step uses (the
  Claude Code CLI and pi run inside the worker, not on the host);
- the container runtime answering, the Keychain item `claude-oauth` present
  and not blank, and `/usr/bin/python3` a working interpreter (on macOS it is a
  stub until the Command Line Tools are installed) — every routed run needs
  all three (research R21, R23); then the egress proxy started and answering
  on its address;
- the routing table, its profiles and the outcome schemas where this repository
  installs them;
- `git config --local sdd.check` is set.
- opted in to DeepSeek (`sdd.implement` is `deepseek`), Spec Kit's pi
  integration is committed (`.pi/prompts/speckit.implement.md` tracked):
  `specify integration install pi`, then commit `.pi/` (research R27).

The DeepSeek path's own prerequisites (the opt-in, the Keychain item
`deepseek-api`) are checked by `sdd-step implement`, at the phase that needs
them (FR-011): a repository not opted in never needs them.

## Exit status

`0` when the run completed or paused at a gate, printing the gate and the
`sdd-run resume` command that answers it; `1` for a missing prerequisite; the
`specify` exit status otherwise.
