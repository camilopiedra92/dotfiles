# Contract: `sdd-step`

`bin/sdd-step.sh`, linked as `~/.local/bin/sdd-step`. Called by the workflow's
`shell` steps from the repository root. Every subcommand that decides
something writes or reads an outcome file in `<feature>/.sdd/`, validated
against `claude/speckit/schemas/<step>.schema.json` (research R10).

## Subcommands

| Subcommand | Does | Prints | Exit |
|---|---|---|---|
| `route` | reads `git config --local sdd.implement` | `deepseek`, or `sonnet` plus a line on how to opt in and DeepSeek's terms | 0 |
| `outcome <step>` | validates `.sdd/<step>.json` | the step's token: `yes`/`no` (clarify), `pass`/`fail` (verify), `converged`/`open` (converge), `blocking`/`clear` (review) | 0; non-zero when the file is missing or invalid |
| `verify` | runs `git config sdd.check`, writes `.sdd/verify.json`: exit status, the last 200 lines of output, the time | `pass`/`fail` | 0 either way; non-zero only when `sdd.check` is unset |
| `implement` | one pass of the external agent, steps below | a summary | 0 when a judged patch is applied and committed or the agent made no change; 1 on a missing prerequisite, a guarded file, a timeout or an agent error |
| `mark` | marks `[X]` in `tasks.md` the tasks `review.json` lists as done | the tasks marked | 0; non-zero when verify is not `pass` or review is `blocking` |

## `implement`, step by step

1. **Prerequisites**, each stopping with exit 1 before any code leaves the
   machine (SC-004): opted in; `container` on `PATH` and its service
   answering; the Keychain item `deepseek-api` present and not blank.
2. **Checkout**: a detached git worktree of `HEAD` in a temporary directory —
   tracked files only.
3. **Image**: `sdd-pi-worker:<hash of containers/pi-worker/>`, built when
   absent.
4. **Container**: `container run --rm -i`, the checkout mounted alone at
   `/work`, the volume `sdd-cache-<run_id>` for the tool cache, network limited
   to the provider's API and the toolchain's registries (research R5,
   pending); the credential written to stdin and read once by the entrypoint;
   pi given the brief of FR-017 (`containers/pi-worker/brief.md` plus the
   feature's paths and, on a fix round, `.sdd/verify.json`). Stopped after the
   time limit (research R13).
5. **Patch**: the checkout's changes against `HEAD`, new and deleted files
   included.
6. **Judge**: each created, changed or deleted path passed to
   `claude/config-guard.sh` as a `Write` of its new content (empty when
   deleted); an `ask` stops with exit 1 naming the path, nothing applied.
7. **Apply and commit** on the feature's worktree: `worker: <feature>
   (<model>)`; `.sdd/implement.json` records the files, the commit, pi's
   tokens.
8. **Clean up**: the checkout removed whatever happened in 4–7.

## Never

The credential in a command-line argument, the environment of any host
process, a file in any repository or in the checkout, an image layer, a
container's stored configuration, the run's state or logs, or pi's session
files on the host (FR-009). A mount of anything but the checkout and the
run's cache volume (FR-007).
