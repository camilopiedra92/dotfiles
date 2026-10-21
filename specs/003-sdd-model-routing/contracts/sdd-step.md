# Contract: `sdd-step`

`bin/sdd-step.sh`, linked as `~/.local/bin/sdd-step`. Called by the workflow's
`shell` steps from the repository root. Every subcommand that decides
something writes or reads an outcome file in `<feature>/.sdd/`, validated
against `claude/speckit/schemas/<step>.schema.json` (research R10).

## Subcommands

| Subcommand | Does | Prints | Exit |
|---|---|---|---|
| `route` | reads `git config --local sdd.implement`, writes `.sdd/route.json` | `deepseek`, or `sonnet` plus a line on how to opt in and DeepSeek's terms | 0 |
| `outcome <step>` | validates `.sdd/<step>.json` | the step's token: `yes`/`no` (clarify), `pass`/`fail` (verify), `converged`/`open` (converge), `blocking`/`clear` (review) | 0; non-zero when the file is missing or invalid |
| `verify` | runs `git config sdd.check`, writes `.sdd/verify.json`: exit status, the last 200 lines of output, the time | `pass`/`fail` | 0 either way; non-zero only when `sdd.check` is unset |
| `implement` | one pass of the agent `route.json` names, steps below | a summary | 0 when a judged patch is applied and committed or the agent made no change; 1 on a missing prerequisite, a guarded file, a timeout or an agent error |
| `mark` | marks `[X]` in `tasks.md` the tasks `review.json` lists as done | the tasks marked | 0; non-zero when verify is not `pass` or review is `blocking` |
| `phase-done <phase>` | appends the phase to `.sdd/phases.json` | — | 0 |
| `cleanup [<run_id>]` | removes the checkouts, containers and volumes labelled with that run, or with any run that is not `running`, or whose run lock names a process that no longer exists (process id and start time, FR-022) | what it removed | 0 |

## `implement`, step by step

1. **Prerequisites**, each stopping with exit 1 before any code leaves the
   machine (SC-004). For deepseek: opted in; `container` on `PATH` and its
   service answering; the Keychain item `deepseek-api` present and not blank.
   For sonnet: `claude` on `PATH`.
2. **Checkout**: the feature directory (`.sdd/` included) committed first,
   `sdd: <feature> before implement`, so every earlier phase's output is in
   `HEAD`; then a detached git worktree of `HEAD` in a temporary directory,
   named and labelled with the run id — tracked files only.
3. **Image** (deepseek): `sdd-pi-worker:<hash of containers/pi-worker/>`,
   built when absent.
4. **Agent**. Sonnet: `claude -p --model claude-sonnet-5-5 --permission-mode
   dontAsk --output-format json --settings <per-pass settings>` — the flags
   `sdd-run` gives Spec Kit's dispatch do not reach a direct call — with the
   same brief, its working directory the checkout, under the routing settings of
   research R4 plus `Bash(<sdd.check>)`, with `Edit` and `Write` limited to
   the checkout (FR-023), stopped after the time limit, which fires before
   the step's own `timeout` (research R11); its JSON result kept for step 7. DeepSeek, in a **container**: `container run --rm -i`, the checkout mounted alone at
   `/work`, the volume `sdd-cache-<run_id>` for the tool cache, network limited
   to the hosts in `containers/pi-worker/egress.txt` (research R5, pending); the credential written to stdin and read once by the entrypoint;
   pi given the brief of FR-017 (`containers/pi-worker/brief.md` plus the
   feature's paths and, on a fix round, `.sdd/verify.json`). Stopped after the
   time limit (research R13).
5. **Patch**: the checkout's changes against `HEAD`, new and deleted files
   included.
6. **Judge**: each created, changed or deleted path passed to
   `claude/config-guard.sh` as a `Write` of its new content (empty when
   deleted); an `ask` stops with exit 1 naming the path, nothing applied.
7. **Apply and commit** on the feature's worktree: `worker: <feature>
   (<model>)`; `.sdd/implement.json` records the files, the commit, and
   the pass's usage: pi's tokens, or Claude's reported cost and model usage.
8. **Clean up**: the checkout, the container and, when the run completes, its
   volume removed whatever happened in 4–7. A pass whose own process was
   killed cannot clean up; `sdd-run start` and `resume` call `sdd-step
   cleanup` first (US2 AS7).

## Never

The credential in a command-line argument, the environment of any host
process, any file on the host, an image layer, a container's stored
configuration, the container runtime's logs, the run's state or logs, or
pi's session files (FR-009). A mount of anything but the checkout and the
run's cache volume (FR-007).
