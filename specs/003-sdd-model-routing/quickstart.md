# Quickstart: validating model routing

Each scenario names the check or the run that proves it. The checks run
offline against stand-ins; the last two need the real services.

## Offline, in `./check.sh`

1. **Routing per phase** (US1 AS1–2): `checks/91-sdd-routing.sh` runs the
   workflow in a scratch repository against a stand-in `claude` that records
   `--model` and the prompt of each call. Expected: specify, clarify, plan,
   checklist, analyze, review and converge on `opus`; tasks and verify on
   `sonnet`; in that order.
2. **Gates and resume** (US1 AS3): the same run with no TTY stops `paused` at
   `review-spec`; `sdd-run resume <id> approve` continues; `reject` aborts.
3. **Clarify through a file** (US1 AS4): the stand-in writes two questions;
   the run pauses at `answer-clarify`; after answers are written and approved,
   `clarify-apply` is called with them.
4. **Loops** (FR-014, FR-015): a stand-in `verify` that always fails gives
   three worker calls and a pause at `fix-stuck`; a stand-in `converge` that
   never converges gives three passes and a pause at `converge-stuck`.
5. **Worker guard** (US2 AS3): a stand-in `container` whose "agent" edits
   `ruff.toml` makes `run` exit 1 naming it, with no commit.
6. **No credential, no runtime, no opt-in** (US2 AS5–6, SC-004): `run` exits 1
   naming each, and the stand-in `container` records no call.
7. **sdd-init** (US3): against a stand-in `specify`, a fresh repository gets
   `specify workflow add` in the same commit; one with `.specify/` gets the
   command printed and nothing changed.

## On this machine

8. **Containment** (US2 AS2, SC-003): with the real `container`, a probe image
   tries to write `/Users`, `~/.ssh` and a path outside `/work`; none exists
   inside the VM and none changes on the host.
9. **SC-001 and SC-002**: in the story-workers repository, the `checkout`
   fixture run twice — `sdd-run start` with the opt-in, and the same workflow
   with every step on `opus` and implementation through `speckit.implement` —
   then `sdd-run usage <id>` for each and the fixture's held-out tests.
   Recorded in `docs/sdd-routing.md` as it comes out.
