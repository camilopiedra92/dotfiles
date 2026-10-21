# Contract: `sdd-run`

`bin/sdd-run.sh`, linked as `~/.local/bin/sdd-run` by `install.sh`. Run from a
repository's root.

## Commands

| Command | Does |
|---|---|
| `sdd-run start "<description>"` | `sdd-step cleanup`, the prerequisites below, sets `SPECKIT_INTEGRATION_CLAUDE_EXTRA_ARGS` (research R4), then execs `specify workflow run sdd-routed -i spec=<description>` |
| `sdd-run resume <run_id> [<verdict>]` | `sdd-step cleanup`, the same checks and environment, then `specify workflow resume <run_id>`, binding the verdict to the input of the gate the run is paused at |
| `sdd-run usage <run_id>` | per Claude model, every attempt's reported cost; attempts that reported none, listed as unreported; the provider's tokens and their price; the totals |

## Prerequisites checked by `start` and `resume`

Each missing one stops with exit 1 and one line naming it and how to provide
it, before any step runs:

- the current directory is the root of a git repository with `.specify/`;
- `sdd-routed` is installed in it, at this repository's version (else: the
  `specify workflow add` command that updates it);
- `claude`, `specify`, `sdd-step`, `check-jsonschema` and `git` on `PATH`;
- `routing-settings.json` and the outcome schemas where this repository
  installs them;
- `git config --local sdd.check` is set.

The external path's prerequisites (opt-in, `container` and its service, the
Keychain item) are checked by `sdd-step implement`, at the phase that needs
them (FR-011): a repository not opted in never needs them.

## Exit status

`0` when the run completed or paused at a gate, printing the gate and the
`sdd-run resume` command that answers it; `1` for a missing prerequisite; the
`specify` exit status otherwise.
