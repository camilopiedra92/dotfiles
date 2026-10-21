# Feature Specification: Model routing per Spec Kit phase

**Feature Branch**: `003-sdd-model-routing`

**Created**: 2026-10-21

**Status**: Draft

**Input**: User description: "Run a feature's Spec Kit phases each on the model
that fits it: the judgment phases (specify, clarify, plan, checklist, analyze,
review, converge) on the most capable Claude model, the routine ones (tasks,
orchestration) on a lighter one, and implementation on DeepSeek through the pi
coding agent, contained so it can touch only the feature's worktree. Built on
Spec Kit's own workflow engine (the built-in `speckit` workflow plus a project
overlay), installed by `sdd-init`. Goal: fit the owner's work into a smaller
Claude subscription (Max 5x → Pro) without losing quality." Spiked on
2026-10-21 on Spec Kit 1.1.3, in a throwaway repository with a stand-in
`claude` that records its arguments: an overlay replacing the `specify` step
with `model: opus` composed (`specify workflow resolve` attributed it to the
overlay) and dispatched `claude -p "/speckit-specify …" --model opus`; a run
without a terminal paused at the first gate. A preset cannot carry a model:
the same spike showed `model:` and `effort:` dropped from a preset command's
generated skill, and upstream declined per-command model selection
(github/spec-kit#1287).

## Clarifications

### Session 2026-10-21

Answered with clarify's recommended option, under the owner's delegation of
2026-10-21 (take the recommended option throughout); the owner may overturn
any of them.

- Q: How many converge passes may run before the run pauses for the owner? → A: Three; then it pauses with the open findings.
- Q: After a failed suite or review, how many fix rounds go back to the external agent before the run stops for the owner? → A: Two; then the run pauses, it does not fall back to Claude on its own.
- Q: What does SC-001's usage count? → A: The Claude models' per-run cost each headless phase reports, at list price, summed over the run.
- Q: Does this feature's success decide the move to the smaller plan? → A: No; the feature succeeds at SC-001's 40%, and the move is decided from a week of real usage afterwards.
- Q: How do clarify's questions reach the owner, given a workflow step gets no terminal (probe, 2026-10-21: a `shell` step saw no TTY and an empty stdin)? → A: Clarify writes its questions, each with its recommended answer, to a file in the feature directory; the run pauses at a checkpoint showing that file; the owner writes the answers there and approves; a second pass applies them to the spec. Found during planning; FR-003 widened from "extend the built-in workflow" to "a workflow on Spec Kit's engine" for it (research R1).

## User Scenarios & Testing *(mandatory)*

The user is the owner of this machine, the only developer on every repository
it holds, who runs Spec Kit features daily. Today every phase of a feature runs
in one Claude session on one model, chosen by hand, and 83% of the last 28
days' usage (measured from the local transcripts on 2026-10-21) was on the
most capable model, including phases that do not need it. The owner wants to
move to a subscription with about a fifth of today's allowance.

### User Story 1 - A feature runs with each phase on its own model (Priority: P1)

The owner starts a feature with one command and a description. Each phase runs
in a fresh context on the model routed to it, handing over to the next through
the feature's files only. The run stops at each checkpoint for the owner's
approval and carries on from there when the owner approves. The owner never
switches a model by hand.

**Why this priority**: it is the saving that needs no new provider and no new
tool on the machine, and it works on its own: if it alone brings usage within
the smaller plan, the other stories are optional.

**Independent Test**: in a scratch repository, run the routed workflow against a
stand-in for the agent CLI that records each call, and read which model each
phase was dispatched with, in which order, and where the run paused.

**Acceptance Scenarios**:

1. **Given** a repository set up for routing, **When** the owner starts a
   feature, **Then** specify, clarify, plan, checklist and analyze are
   dispatched on the most capable model, and tasks on the lighter one.
2. **Given** a phase has finished, **When** the next one starts, **Then** it
   starts in a fresh context and reads what it needs from the feature's files.
3. **Given** a checkpoint is reached, **When** no answer is given, **Then** the
   run pauses and says how to approve or reject it; **When** the owner
   approves, **Then** the run continues from that checkpoint without redoing
   finished phases; **When** the owner rejects, **Then** the run stops.
4. **Given** clarify has questions for the owner, **When** it runs, **Then** the
   questions reach the owner and the answers reach the spec before plan starts.
5. **Given** implementation and its checks are done, **When** the review runs,
   **Then** it runs on the most capable model in a fresh context, and converge
   repeats until a pass finds nothing above LOW; **Given** three passes have
   run and findings above LOW remain, **Then** the run pauses for the owner
   with those findings.
6. **Given** the Spec Kit CLI is upgraded, **When** the routed workflow next
   runs, **Then** the routing still applies without editing the upgraded
   files, or the run fails naming what it no longer finds.

---

### User Story 2 - Implementation runs on DeepSeek, contained (Priority: P2)

The implementation phase runs on DeepSeek through the pi coding agent. It can
read and write only the feature's worktree. Its work counts as done only after
the feature's whole test suite has passed and a fresh review on the most
capable model has read it; the agent's own claim of success is not enough.

**Why this priority**: it moves the largest share of tokens off the Claude
subscription, but it adds a provider, a credential and a contained runtime, and
the code leaves the machine. It is only worth having once Story 1 works.

**Independent Test**: run the implementation step against a fixture feature with
a stand-in for the external agent that tries to write inside the worktree,
outside it, and to a guarded configuration file; read which writes landed and
what the run reported.

**Acceptance Scenarios**:

1. **Given** a feature with tasks, **When** the implementation step runs,
   **Then** the external agent receives the tasks, the project's constitution
   and the owner's test-first rules, and works only in the feature's worktree.
2. **Given** the external agent tries to read or write outside the worktree,
   **Then** the attempt fails and nothing outside the worktree changes.
3. **Given** the external agent changes a lint, format, type-check or test
   configuration file, **Then** the run fails naming the file, and the
   tasks stay unmarked.
4. **Given** the external agent reports success, **When** the suite fails,
   **Then** the tasks stay unmarked and the failures go back to the external
   agent; **Given** two such fix rounds have failed, **Then** the run pauses
   for the owner, reporting the failing tests, and does not hand the work to a
   Claude model on its own.
5. **Given** the credential is missing, or the contained runtime is not
   available, **Then** the step stops before any code is sent, naming what is
   missing and how to provide it.
6. **Given** a repository that has not opted in to sending its code to the
   external provider, **Then** implementation runs on the lighter Claude model
   instead, and the run says so.

---

### User Story 3 - New repositories get routing, existing ones are told how (Priority: P3)

`sdd-init` installs the routing in every repository it sets up, and a
repository that already has Spec Kit is given the commands that add it.

**Why this priority**: until it is installed by default, the routing exists
only where the owner remembers to add it by hand.

**Independent Test**: run `sdd-init` against stand-ins for `specify` in a fresh
repository and in one that already has `.specify/`, and read the calls made,
what landed in the commit, and what was printed.

**Acceptance Scenarios**:

1. **Given** a fresh repository, **When** `sdd-init` runs, **Then** the routing
   is installed and lands in the same commit as the rest of Spec Kit.
2. **Given** a repository that already has `.specify/`, **When** `sdd-init`
   runs, **Then** it prints the commands that add the routing, as it does for
   presets, and changes nothing.
3. **Given** a new repository, **Then** it has not opted in to the external
   provider until the owner opts it in.

### Edge Cases

- The owner works interactively in a Claude session instead of starting the
  routed workflow: nothing changes there; routing applies only to routed runs.
- A phase needs a permission the headless agent was not given: the run fails
  naming the refused action, instead of the phase silently skipping it.
- The external agent runs out of time, of prepaid credit, or returns an error:
  the step fails with the provider's message and the run can be resumed after
  the cause is fixed.
- Two features run at once in two worktrees: each run's agent sees only its own
  worktree.
- The fixed cost of starting each phase cold outweighs the saving on a small
  feature: the measurement in SC-001 shows it, and the result is recorded as it
  came out.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A routed run MUST dispatch each Spec Kit phase on the model the
  routing assigns to it, with no model switched by the owner by hand.
- **FR-002**: Each phase MUST run in a fresh agent context; phases MUST hand
  over only through the feature's files.
- **FR-003**: The routing MUST be a workflow run by Spec Kit's own workflow
  engine, and MUST NOT edit files Spec Kit installs (constitution V).
- **FR-004**: A routed run MUST pause at a checkpoint after specify (with
  clarify), after plan (with checklist and analyze), and before marking
  implementation done, and MUST resume from where it paused.
- **FR-005**: Clarification questions MUST reach the owner and the owner's
  answers MUST be written into the spec before plan runs.
- **FR-006**: Implementation MUST be marked done only after the project's whole
  suite has passed and a fresh-context review on the most capable model has
  run, whichever agent wrote the code.
- **FR-007**: The external agent MUST be contained to the feature's worktree:
  no read or write outside it, and no access to the owner's credentials other
  than the one it needs.
- **FR-008**: A change by the external agent to lint, format, type-check or
  test configuration MUST fail the run, naming the file.
- **FR-009**: The external provider's credential MUST come from the Keychain and
  MUST NOT be written to any file in a repository or in the run's state.
- **FR-010**: Code MUST be sent to the external provider only from a repository
  the owner has opted in; otherwise implementation MUST run on the lighter
  Claude model and the run MUST say so.
- **FR-011**: Every prerequisite the routed run depends on — the agent CLIs, the
  contained runtime, the credential — MUST be declared in this repository's
  manifests (constitution I), and a missing one MUST stop the run before the
  phase that needs it, naming it.
- **FR-012**: `sdd-init` MUST install the routing in a fresh repository in the
  same commit as Spec Kit, and MUST print the commands that add it to a
  repository that already has Spec Kit.
- **FR-013**: Each script with logic of its own that this feature adds MUST
  ship with a check in `checks/` seen red on its behaviour broken by hand
  (constitution III).
- **FR-014**: Converge MUST stop after three passes with findings above LOW
  still open, pausing the run for the owner with those findings.
- **FR-015**: After two failed fix rounds by the external agent, the run MUST
  pause for the owner and MUST NOT hand the work to a Claude model unasked.

### Key Entities

- **Routing**: which model and which agent each phase runs on, and where the
  checkpoints are. Lives in the repository, travels with it.
- **Run**: one pass of a feature through the routed workflow, with its state,
  its pauses and the usage each phase reported.
- **Opt-in**: a repository's recorded consent to send its code to the external
  provider.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: On the reference fixture (the `checkout` fixture of the
  story-workers preset's Eval 002), a routed run uses at least 40% less Claude
  subscription usage than the same feature run with every phase on the most
  capable model, counting the Claude models' per-run cost each phase reports,
  at list price, summed over the run. One counted run per arm; the result is
  recorded as it comes out, whichever way. Whether the owner moves to the
  smaller plan is decided afterwards, from a week of real usage, not here.
- **SC-002**: In the same comparison, the routed run passes as many of the
  fixture's held-out acceptance tests as the unrouted one, and its own suite is
  green.
- **SC-003**: In the containment probe, 0 writes outside the feature's worktree
  land and every attempt to change a guarded configuration file fails the run.
- **SC-004**: With the credential missing, the runtime unavailable or the
  repository not opted in, 0 bytes of code are sent to the external provider,
  and the owner is told what is missing in the step's output.
- **SC-005**: Starting a feature takes the owner one command, and each
  checkpoint one answer; the owner never types a model name.
- **SC-006**: Every check this feature adds has been seen red with the
  behaviour it guards broken by hand.

## Assumptions

- "Most capable model" is Claude Opus and "lighter model" is Claude Sonnet,
  both through the owner's Claude subscription; the external provider is
  DeepSeek (V4 Flash by default) through its own prepaid API key, reached
  through the pi coding agent. The names are the owner's choice of 2026-10-21
  and are expected to change.
- The routed workflow is an addition: the interactive way of running Spec Kit
  phases in one Claude session stays as it is.
- The story-workers preset (Sonnet subagents per phase inside one session)
  stays installed; a routed run's implementation step replaces what it does for
  that run only. Whether to keep it afterwards is decided from SC-001's result.
- Opt-in to the external provider is per repository and off by default: code
  from private repositories such as `renta` or `tli` leaves the machine only
  by the owner's explicit choice.
- The 40% target in SC-001 is the owner's goal (Pro is a fifth of Max 5x's
  allowance) discounted for what routing cannot move: the judgment phases stay
  on the most capable model.
- One counted run per arm, as in the story-workers evals: the result is
  directional, not statistical.
