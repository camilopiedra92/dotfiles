# Contract: `sdd-step`

`bin/sdd-step.sh`, linked as `~/.local/bin/sdd-step`. Called by the workflow's
`shell` steps from the repository root. Every subcommand that decides
something writes or reads an outcome file in `<feature>/.sdd/`, validated
against `claude/speckit/schemas/<step>.schema.json` (research R10).

## Subcommands

| Subcommand | Does | Prints | Exit |
|---|---|---|---|
| `agent <phase>` | runs a Claude routing row (contracts/routing.md) | — | 0 when the result is a success with no denial; non-zero naming the cause otherwise |
| `route` | reads `git config --local sdd.implement`, writes `.sdd/route.json` | `deepseek`, or `sonnet` plus a line on how to opt in and DeepSeek's terms | 0 |
| `outcome <step>` | validates `.sdd/<step>.json` | the step's token: `yes`/`no` (clarify), `pass`/`fail` (verify), `converged`/`open` (converge), `blocking`/`clear` (review) | 0; non-zero when the file is missing or invalid |
| `verify` | runs `git config sdd.check`, writes `.sdd/verify.json`: exit status, the last 200 lines of output, the time | `pass`/`fail` | 0 either way; non-zero only when `sdd.check` is unset |
| `implement` | one pass of the agent `route.json` names, steps below | a summary | 0 when a judged patch is applied and committed or the agent made no change; 1 on a missing prerequisite, a guarded file, a timeout or an agent error |
| `mark` | marks `[X]` in `tasks.md` the tasks `review.json` lists as done | the tasks marked | 0; non-zero when verify is not `pass` or review is `blocking` |
| `phase-done <phase>` | appends the phase to `.sdd/phases.json` | — | 0 |
| `cleanup [<run_id>]` | removes the checkouts, containers and volumes labelled with that run, or with any run that is not `running`, or whose run lock names a process that no longer exists (process id and start time, FR-022) | what it removed | 0 |

## `implement`, step by step

1. **Prerequisites**, each stopping with exit 1 before any code leaves the
   machine (SC-004); the effective implement row's `timeout` is 1–1800 seconds.
   For deepseek (as `route.json` says): still opted in — a repository opted
   out since `route` ran sends nothing and the pass runs on sonnet instead,
   saying so, after sonnet's prerequisites, and records `agent: sonnet` in
   `implement.json` (FR-010); the container runtime research R5 settled on,
   on `PATH` and answering; the Keychain item `deepseek-api` present and not
   blank. For sonnet: `claude` on `PATH`.
2. **Checkout**: the feature directory (`.sdd/` included) committed first,
   `sdd: <feature> before implement`, so every earlier phase's output is in
   `HEAD`; then a detached git worktree of `HEAD` in a temporary directory,
   named and labelled with the run id — tracked files only.
3. **Image** (deepseek): `sdd-pi-worker:<hash of containers/pi-worker/>`,
   built when absent.
4. **Agent**, with the brief of FR-017 (`containers/pi-worker/brief.md` plus
   the feature's paths and, on a fix round, `.sdd/verify.json`), stopped after
   the time limit — the effective implement row's `timeout` — which fires
   before the step's own `timeout` (research R11).
   - **Sonnet**: the `implement-sonnet` routing row, run as `sdd-step agent`
     runs a Claude row, with its working directory the checkout and the
     `implement-sonnet` profile composed for this pass (`Bash(<sdd.check>)`,
     Edit and Write limited to the checkout, FR-023).
   - **DeepSeek**: the `implement-deepseek` row, in a container (research
     R5): the checkout mounted alone at `/work`, the volume
     `sdd-cache-<run_id>`, `NET_ADMIN` and `NET_RAW` only for the firewall
     script, which runs first and denies all egress but the hosts in
     `containers/pi-worker/egress.txt`; then pi runs as the non-root user
     `node`, `pi -p --mode json --no-session --model deepseek/<row.model>
     --thinking <row.effort>`, the credential read once from stdin.
5. **Patch**: the checkout's changes against `HEAD`, new and deleted files
   included.
6. **Check the response**: a response reporting a model other than the
   configured one, or lacking a usage field, fails the pass naming it, with
   nothing applied.
7. **Judge**: each created, changed or deleted path passed to
   `claude/config-guard.sh` as a `Write` of its new content (empty when
   deleted); an `ask` stops with exit 1 naming the path, nothing applied.
8. **Apply and commit** on the feature's worktree: `worker: <feature>
   (<model>)`; `.sdd/implement.json` records the files, the commit, and
   the pass's usage: pi's tokens, or Claude's reported cost and model usage;
   the same start and end lines go to the run's `usage.jsonl`
   (contracts/routing.md).
9. **Clean up**: the checkout, the container and, when the run completes, its
   volume removed whatever happened in 4–8. A pass whose own process was
   killed cannot clean up; `sdd-run start` and `resume` call `sdd-step
   cleanup` first (US2 AS7).

## Never

The credential in a command-line argument, the environment of any host
process, any file on the host, an image layer, a container's stored
configuration, the container runtime's logs, the run's state or logs, or
pi's session files (FR-009). A mount of anything but the checkout and the
run's cache volume (FR-007).
