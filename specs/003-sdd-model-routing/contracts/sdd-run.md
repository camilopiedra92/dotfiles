# Contract: `sdd-run`

`bin/sdd-run.sh`, linked as `~/.local/bin/sdd-run` by `install.sh`. Run from a
repository's root.

## Commands

| Command | Does |
|---|---|
| `sdd-run start --from <feature dir>` | as `start`, with `-i spec=<feature dir>/spec.md` instead of a description, for a feature whose run died: `resume_from` set to the first phase not in `.sdd/phases.json`; refused when no phase is finished (FR-022) |
| `sdd-run start "<description>"` | `sdd-step cleanup`, the prerequisites below, unsets `CLAUDE_CODE_EFFORT_LEVEL` (research R14), merges and validates the routing layers (contracts/routing.md), applying `--set` overrides, generates the run id, writes the run bundle (contracts/routing.md) and exports `SDD_RUN_DIR`, starts the egress proxy (contracts/pass.md), sets `SPECKIT_WORKFLOW_RUN_ID` and `SDD_STEP` (the absolute path of `sdd-step` from `tools.json`), then runs `specify workflow run sdd-routed -i spec=<description>` as its child and stops the egress proxy when it exits |
| `sdd-run resume <run_id> [<verdict>]` | `sdd-step cleanup`, the same checks, the run's bundle reused unchanged and `SDD_RUN_DIR` exported, then runs `specify workflow resume <run_id>` as its child, stopping the egress proxy when it exits, binding the verdict to the input of the gate the run is paused at; with no verdict, for a run paused outside a gate (Ctrl-C), it resumes the interrupted step |
| `sdd-run routing [--set <phase>.<field>=<value> …] [--init-local]` | prints the effective routing table for this repository, each value with its layer; `--init-local` creates the git-ignored local layer (contracts/routing.md) |
| `sdd-run usage <run_id>` | from the run's `usage.jsonl` (contracts/routing.md): per model, every attempt's reported cost; attempts with a start and no end, or no usage, listed as unreported; the provider's tokens priced from `models.json`; the totals |

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

The DeepSeek path's own prerequisites (the opt-in, the Keychain item
`deepseek-api`) are checked by `sdd-step implement`, at the phase that needs
them (FR-011): a repository not opted in never needs them.

## Exit status

`0` when the run completed or paused at a gate, printing the gate and the
`sdd-run resume` command that answers it; `1` for a missing prerequisite; the
`specify` exit status otherwise.
