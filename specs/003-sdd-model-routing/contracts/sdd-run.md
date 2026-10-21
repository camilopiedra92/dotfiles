# Contract: `sdd-run`

`bin/sdd-run.sh`, linked as `~/.local/bin/sdd-run` by `install.sh`. Run from a
repository's root.

## Commands

| Command | Does |
|---|---|
| `sdd-run start "<description>"` | checks the prerequisites below, sets `SPECKIT_INTEGRATION_CLAUDE_EXTRA_ARGS` (R4), then execs `specify workflow run sdd-routed -i spec=<description>` |
| `sdd-run resume <run_id> [approve\|reject]` | the same environment, then `specify workflow resume <run_id>`, passing the verdict to whichever gate the run is paused at |
| `sdd-run usage <run_id>` | prints, per Claude model, the cost every step of that run reported, and the total |

## Prerequisites checked by `start` and `resume`

Each missing one stops with exit 1 and one line naming it and how to provide
it, before anything is dispatched:

- the current directory is the root of a git repository with `.specify/`;
- `sdd-routed` is installed in it (`specify workflow list`);
- `claude` and `specify` are on `PATH`;
- `routing-settings.json` exists where the environment variable points.

The external provider's prerequisites (the `container` CLI and its system
service, the Keychain item) are checked by the worker, at the phase that needs
them (FR-011), not here: a repository that has not opted in never needs them.

## Exit status

`0` when the run completed or paused at a gate (the paused gate and the
command that answers it are printed); `1` for a missing prerequisite; the
`specify` exit status otherwise.
