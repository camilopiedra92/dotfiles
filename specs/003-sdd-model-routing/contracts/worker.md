# Contract: `sdd-implement-worker`

`bin/sdd-implement-worker.sh`, linked as `~/.local/bin/sdd-implement-worker`.
Called by the workflow's `shell` steps from the repository root.

## Commands

| Command | Prints | Exit |
|---|---|---|
| `route` | `deepseek` when `git config --local sdd.implement` is `deepseek`, else `sonnet` and one line saying implementation stays on Claude and how to opt in | 0 |
| `questions` | `yes` when the feature's `clarify-questions.md` holds at least one question, else `no` | 0 |
| `run` | a summary: tasks attempted, files changed, the commit made | 0 when the worker's changes passed the guard and are committed; 1 on a missing prerequisite or a guarded file. One pass only: the workflow's `fix-loop` decides whether there is another |

## `run`, step by step

1. **Prerequisites**, each stopping with exit 1 and a line naming it, before
   any code leaves the machine (SC-004): the repository is opted in; the
   `container` CLI is on `PATH` and its system service answers; the Keychain
   item `deepseek-api` exists and is not blank.
2. **Baseline**: the worktree is clean outside the feature directory; `HEAD` is
   recorded.
3. **Image**: `sdd-pi-worker:<first 12 hex of the Containerfile's sha256>`;
   built from `containers/pi-worker/` when absent.
4. **Container**: `container run --rm -i` with the worktree mounted at `/work`
   (read-write), a named volume for mise's cache, working directory `/work`,
   no other mount; the credential written to its stdin and read once by the
   entrypoint. pi gets a prompt naming the feature's `tasks.md`, `spec.md`,
   `plan.md`, the constitution, `brief.md`'s test-first rules and, on a fix
   round, `verify.md`.
5. **Judge**: for each path changed since the baseline, the runner builds the
   `Write` call that would have produced it and passes it to
   `claude/config-guard.sh`; any `ask` stops with exit 1 naming the path,
   leaving the tree as the worker left it for the owner to read (FR-008).
6. **Commit**: on the host, one commit of the worker's changes, message
   `worker: <feature> (<model>)`.

## Never

- The credential in an argument, an environment variable of the host process,
  a file, an image layer or the run's state (FR-009).
- A mount of anything outside the worktree (FR-007).
