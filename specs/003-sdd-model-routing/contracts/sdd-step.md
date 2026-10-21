# Contract: `sdd-step`

`bin/sdd-step.sh`, linked as `~/.local/bin/sdd-step`. Called by the workflow's
`shell` steps from the repository root. Every subcommand that decides
something writes or reads an outcome file in `<feature>/.sdd/`, validated
against `claude/speckit/schemas/<step>.schema.json` (research R10).

## Subcommands

| Subcommand | Does | Prints | Exit |
|---|---|---|---|
| `agent <phase>` | runs a routing row through the contained pass (contracts/routing.md, contracts/pass.md) | — | 0 when the result is a success with no denial; non-zero naming the cause otherwise |
| `route` | reads the opt-in frozen in `$SDD_RUN_DIR/optin.json`, writes `.sdd/route.json` | `deepseek`, or `sonnet` plus a line on how to opt in and DeepSeek's terms | 0 |
| `outcome <step>` | validates `.sdd/<step>.json` | the step's token: `yes`/`no` (clarify), `pass`/`fail` (verify), `converged`/`open` (converge), `blocking`/`clear` (review) | 0; non-zero when the file is missing or invalid |
| `egress-proxy` | the run's egress proxy (contracts/pass.md), started by `sdd-run start` and `resume`, stopped when the run pauses, completes or fails | — | runs until stopped |
| `prepare-worker` | builds the worker image `sdd-worker:<hash of containers/worker/>` when absent, before any pass, so no pass's limit pays for a build (every agent step and verify run in it) | the image tag | 0; non-zero naming the runtime's error |
| `verify` | the contained pass with no agent (contracts/pass.md, "Verify"): the check command frozen in the bundle, inside the worker container, registries only; writes `.sdd/verify.json`: exit status, the last 200 lines of output, the time | `pass`/`fail` | 0 either way; non-zero only when `sdd.check` is unset |
| `implement` | one pass of the agent `route.json` names, steps below | a summary | 0 when a judged patch is applied and committed or the agent made no change; 1 on a missing prerequisite, a guarded file, a timeout or an agent error |
| `mark` | marks `[X]` in `tasks.md` the tasks `review.json` lists as done | the tasks marked | 0; non-zero when verify is not `pass` or review is `blocking` |
| `phase-done <phase>` | appends the phase to `.sdd/phases.json` | — | 0 |
| `cleanup [<run_id>]` | removes the exports, containers, volumes and the egress proxy labelled with that run, or with any run that is not `running`, or whose run lock names a process that no longer exists (process id and start time, FR-022) | what it removed | 0 |

## `implement`

1. **Prerequisites**, each stopping with exit 1 before any code leaves the
   machine (SC-004): the effective implement row's `timeout` within its
   `max_timeout`; the container runtime answering and the worker image
   present; for deepseek (as `route.json` says), opted in both in the bundle and
   now — a repository opted out since start sends nothing and the pass runs on
   sonnet instead, saying so, and records `agent: sonnet` in `implement.json`
   (FR-010) — and the Keychain item `deepseek-api` present and not blank; for
   sonnet, the Keychain item `claude-oauth` present and not blank.
2. **The pass** (contracts/pass.md) with the `implement-deepseek` or
   `implement-sonnet` row, the brief of FR-017 (`containers/worker/brief.md`
   plus the feature's paths and, on a fix round, `.sdd/verify.json`), and the
   protected set and config-guard as the judge.
3. **Check the response** before applying: a response reporting a model other
   than the configured one, or lacking a usage field, fails the pass naming
   it, with nothing applied.
4. **Record**: `.sdd/implement.json` — the files, the commit, the pass's usage
   — written only here.

## Never

See contracts/pass.md, "Never" and "Host git": they hold for every subcommand.
