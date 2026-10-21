# Quickstart: validating model routing

Each scenario names the check or the run that proves it. The checks run
offline against stand-ins; the last two need the real services.

## Offline, in `./check.sh`

1. **Routing per phase** (US1 AS1–2): `checks/91-sdd-routing.sh` runs the
   workflow in a scratch repository against a stand-in `claude` that records
   `--model` and the prompt of each call and writes canned outcome files.
   Expected: specify, clarify, plan, checklist, analyze, review and converge
   on `claude-opus-5-5`, tasks on `claude-sonnet-5-5`, verify calling no model;
   in that order; and every call carrying its row's `--effort`, its profile's
   `--settings`, `--permission-mode dontAsk`, `--permission-prompts none`, `--strict-mcp-config` with no
   server, `--output-format json`, and `--json-schema` where the row has one, with the engine's run id equal to
   `SPECKIT_WORKFLOW_RUN_ID` and each attempt in the run's usage log
   (FR-025, contracts/routing.md).
2. **Gates** (US1 AS3, FR-004): with no TTY the run pauses at each gate;
   `sdd-run resume <id> approve` continues, `reject` aborts, at every gate.
3. **Clarify through a file** (US1 AS4): two canned questions pause the run at
   `answer-clarify`, and `clarify-apply` is called after approval; zero
   questions skip the gate.
4. **Outcome files** (FR-016): a missing, malformed or extra-field outcome
   fails the run at that step; valid ones drive the branches.
5. **Loops** (FR-014, FR-015): a check command that always fails gives three
   implementation passes and a pause at `fix-stuck`; `retry` gives one more;
   a converge that never converges gives three passes and `converge-stuck`.
6. **Marking** (FR-006): `sdd-step mark` refuses on a failing verify or a
   blocking review, and marks only the tasks the review lists.
7. **Patch judgment** (US2 AS3): a stand-in container runtime whose agent edits,
   creates or deletes `ruff.toml`, or drops `[tool.ruff]` from
   `pyproject.toml`, makes `implement` exit 1 naming it; the feature's
   worktree is unchanged and no commit is made.
8. **Failure leaves nothing behind** (US2 AS7): a stand-in agent that crashes
   midway leaves the feature's worktree unchanged and no checkout behind.
9. **Prerequisites** (US2 AS5, SC-004, FR-011): each missing one stops the
   step naming it, and the stand-in container runtime records no call.
10. **sdd-init** (US3): against a stand-in `specify`, a fresh repository gets
    `specify workflow add` in the same commit; one with `.specify/` gets the
    command printed and nothing changed.

## On this machine

11. **Containment** (US2 AS2, SC-003): with the real container runtime research R5 settled on, a probe image
    tries to read `~/.ssh`, the Keychain and another repository, to write the
    home directory, another repository and the feature's worktree, and to
    reach any host directly or through the proxy beyond what its pass may use,
    resolve a name over DNS, read a credential from its environment, and as the
    `node` user change the firewall. All fail; nothing on the host
    changes.
12. **SC-001 and SC-002**: on story-workers' eval harness, with the routed
    and baseline arms its own feature adds (spec SC-001); the result is that
    feature's record, linked from `docs/sdd-routing.md`.
