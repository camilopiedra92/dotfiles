# Contract: `sdd-step`

`bin/sdd-step.sh`, linked as `~/.local/bin/sdd-step`. Called by the workflow's
`shell` steps from the repository root. Every subcommand that decides
something writes or reads an outcome file in `<feature>/.sdd/`, validated
against `claude/speckit/schemas/<step>.schema.json` (research R10).
The feature directory is the one `.specify/feature.json` names — the file
Spec Kit's own scripts read — accepted only as `specs/<nnn>-<slug>`, an
existing directory.

## Subcommands

| Subcommand | Does | Prints | Exit |
|---|---|---|---|
| `agent <phase>` | runs a routing row through the contained pass (contracts/routing.md, contracts/pass.md) | — | 0 when the result is a success with no denial; non-zero naming the cause otherwise |
| `route` | reads the opt-in frozen in `$SDD_RUN_DIR/optin.json`, writes `.sdd/route.json` | `deepseek`, or `sonnet` plus a line on how to opt in and DeepSeek's terms of use and privacy policy (cdn.deepseek.com, read 2026-10-21) | 0 |
| `outcome <step>` | validates `.sdd/<step>.json` | the step's token: `yes`/`no` (clarify), `pass`/`fail` (verify), `converged`/`open` (converge), `blocking`/`clear` (review) | 0; non-zero when the file is missing or invalid |
| `egress-proxy` | the run's egress proxy container and network (contracts/pass.md): the bundle's copy of `sdd-egress-proxy.py` on the worker image's Python, its start line on stdin, `admissions/` read-only, `github.com`'s path rule in its start line; writes `proxy.json`, `proxy-ca.pem` (the authority it inspects registry traffic with) and the served names in `routing.json`, removing the first two when it stops; started by `sdd-run start` and `resume`, stopped (SIGTERM) by `sdd-run` when its `specify` child exits, and exiting by itself after a minute without a heartbeat; removes the network when the proxy stops | — | runs until stopped |
| `prepare-worker` | builds the worker image `sdd-worker:<first 12 hex of the SHA-256 of containers/worker/'s paths and contents>` when absent, before any pass, so no pass's limit pays for a build (every agent step and verify run in it); a fresh build's inventory (`containers/worker/inventory.sh` run in it) must equal `containers/worker/inventory.txt`, or the image is deleted and the step fails naming each package added or missing (FR-032); then records the tag in `worker.json`; then deletes the worker images no unfinished run uses — runs of this repository, and those registered in `~/.local/state/sdd/runs/`; a run is finished once its bundle holds `finished.json` | the image tag | 0; non-zero naming the runtime's error |
| `verify` | the contained pass with no agent (contracts/pass.md, "Verify"): the check command frozen in the bundle, inside the worker container, registries only; writes `.sdd/verify.json`: exit status, the last 200 lines of output, the time | `pass`/`fail` | 0 either way; non-zero only when `sdd.check` is unset |
| `implement` | one pass of the agent `route.json` names, steps below | a summary | 0 when a judged patch is applied and committed, or the agent made no change after the run's first implementation and outside a fix round (a change-less first implementation or fix round fails, showing what the agent said; research R27); 1 on a missing prerequisite, a guarded file, a timeout or an agent error |
| `mark` | marks `[X]` in `tasks.md` the tasks `review.json` lists as done | the tasks marked | 0; non-zero when verify is not `pass` or review is `blocking` |
| `stuck fix` / `stuck converge` | reads `.sdd/verify.json` or `.sdd/converge.json`; `clear` when it passed or converged, resetting the pass count in `$SDD_RUN_DIR/counters/`; `again` for the second and third pass; after the third, consumes and deletes `$SDD_RUN_DIR/verdicts/retry` if present and prints `retry` (exactly one more pass); else fails, naming `sdd-run resume <id> retry` and `sdd-run abort <id>` | `clear`, `again` or `retry`, no newline | 0, or non-zero to stop the run for the owner |
| `phase-done <phase>` | appends the phase to `.sdd/phases.json` | — | 0 |
| `agent specify` | as `agent`, with no feature directory yet: the prompt carries the run's `spec` input, read from `.specify/workflows/runs/<run_id>/inputs.json`; the pass must create exactly one `specs/<nnn>-<slug>/`, which `.specify/feature.json` names exactly | — | as `agent` |
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
   `implement-sonnet` row, the brief of FR-017 (`claude/speckit/brief.md`, frozen in the bundle at start,
   plus the feature's paths and, on a fix round, `.sdd/verify.json`), and the
   protected set and config-guard as the judge.
3. **Check the response** before applying: a response reporting a model other
   than the configured one, or lacking a usage field, fails the pass naming
   it, with nothing applied.
4. **Record**: `.sdd/implement.json` — the files, the commit, the pass's usage
   — written only here.

## Never

See contracts/pass.md, "Never" and "Host git": they hold for every subcommand.
