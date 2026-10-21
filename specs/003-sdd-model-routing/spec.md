# Feature Specification: Model routing per Spec Kit phase

**Feature Branch**: `003-sdd-model-routing`

**Created**: 2026-10-21

**Status**: Draft

**Input**: User description: "Run a feature's Spec Kit phases each on the model
that fits it: the judgment phases (specify, clarify, plan, checklist, analyze,
review, converge) on the most capable Claude model, the routine ones (tasks,
verify) on a lighter one, and implementation on DeepSeek through the pi coding
agent, contained so it can touch only the feature's code. Built on Spec Kit's
own workflow engine, installed by `sdd-init`. Every agent hands its work to
the next as files on disk, not as text. Goal: fit the owner's work into a
smaller Claude subscription (Max 5x → Pro) without losing quality." Spiked on
2026-10-21 on Spec Kit 1.1.3, rerun on 1.2.2, in a throwaway repository with a stand-in
`claude` that records its arguments: a workflow step with `model: opus`
dispatched `claude -p "/speckit-specify …" --model opus`; a run without a
terminal paused at the first gate; a `shell` step saw no terminal and an empty
stdin. A preset cannot carry a model: the same spike showed `model:` and
`effort:` dropped from a preset command's generated skill, and upstream
declined per-command model selection (github/spec-kit#1287).

## Clarifications

### Session 2026-10-21

Answered with clarify's recommended option, under the owner's delegation of
2026-10-21 (take the recommended option throughout); the owner may overturn
any of them. The last group came from the fresh-context review of
`checklists/routing.md` and was answered the same way.

- Q: How many converge passes may run before the run pauses for the owner? → A: Three; then it pauses with the open findings.
- Q: After a failed check command, how many fix rounds go back to the implementing agent before the run stops for the owner? → A: Two per convergence pass; then the run pauses, and work never moves to another agent on its own.
- Q: What does SC-001's usage count? → A: Every attempt of every Claude step, failed and resumed ones included, at list price, as each reports it.
- Q: Does this feature's success decide the move to the smaller plan? → A: No; the feature succeeds at SC-001's 40%, and the move is decided from a week of real usage afterwards.
- Q: How do clarify's questions reach the owner, given a workflow step gets no terminal? → A: Through a file in the feature directory, which the owner answers before approving the checkpoint.
- Q: How do agents hand over and how does the run decide what comes next? → A: Every step writes its outcome to a JSON file in the feature directory, validated against a schema; the run branches only on what a deterministic reader finds in valid outcome files, never on an agent's printed text, and a missing or invalid outcome fails the step. Proposed by the owner; checked against Anthropic's engineering posts "How we built our multi-agent research system" (subagent output to a filesystem, to avoid a "game of telephone") and "Effective harnesses for long-running agents" (state in a progress file, a JSON feature list and git; JSON because the model is less likely to overwrite it than Markdown; passing only after testing).
- Q: Does verify need a model? → A: No; whether the check command passed is its exit status, so verify is a deterministic step and models are kept for judgment.
- Q: What does the implementing agent see of the repository? → A: A export of the committed code at the run's current commit, without untracked or ignored files; its changes come back as a patch the run judges before applying.
- Q: What bounds the external provider's spend? → A: A time limit per implementation pass (30 minutes), the prepaid balance as the hard ceiling, and the provider's spend reported per run.
- Q: How is a repository's check command known? → A: Declared once per repository by the owner; a run without it stops before planning, naming how to declare it.
- Q: What effort does each step run at? → A: Set per step by the routing, so neither the owner's interactive effort nor an environment variable leaks into a run: every Claude step at `medium`, the documented default for Opus 5.5 and Sonnet 5.5 today, and the DeepSeek step at `high`, the lowest reasoning level DeepSeek's own pi configuration maps to. A higher level for a judgment phase is a change to measure on one story first, then a one-line edit of the routing.
- Q: Can a step's model, effort, permissions and context be chosen per step, given Spec Kit 1.2.2's Claude integration refuses per-step arguments? → A: Yes: the workflow engine keeps the order, checkpoints, loops and resume, and every agent step goes through one dispatcher reading a routing table with a row per phase (research R2). The owner asked for model and effort per step and for a design of the highest standard, not the smallest one, after an independent audit proposed a smaller design (2026-10-21).
- Q: Must each change of model or effort reload all the context? → A: No: each step loads only what it needs — no MCP servers, only its profile's tools — measured at half the context, with the whole prefix read from the prompt cache on the next step of the same model (research R16); effort changes do not break the cache, model changes do, so same-model steps are kept together.
- Q: Where is the routing configured? → A: In layers, lowest precedence first: defaults in this repository; a project file versioned in the repository it routes; a local file in that repository that git ignores; and one run's overrides on the command line. Layers merge per phase and per field, the merged table is validated before any step, and each run records every value with the layer it came from. No layer can send code to the external provider: that stays the repository's opt-in. Modelled on Claude Code's own settings precedence.
- Q: Which harness runs DeepSeek? → A: pi, the path DeepSeek documents and supports, in a container whose firewall denies all egress but an allow list (Anthropic's reference devcontainer pattern); Claude Code on DeepSeek worked equally in a one-task spike but is unsupported by Anthropic (research R5, R17).

## User Scenarios & Testing *(mandatory)*

The user is the owner of this machine, the only developer on every repository
it holds, who runs Spec Kit features daily. Today every phase of a feature runs
in one Claude session on one model, chosen by hand, and 83% of the last 28
days' usage (measured from the local transcripts on 2026-10-21) was on the
most capable model, including phases that do not need it. The owner wants to
move to a subscription with about a fifth of today's allowance.

### User Story 1 - A feature runs with each phase on its own model (Priority: P1)

The owner starts a feature with one command and a description. Each phase runs
as a fresh agent on the model routed to it, reading and writing only the
feature's files. The run stops at each checkpoint for the owner's approval and
carries on from there. The owner never switches a model by hand.

**Why this priority**: it is the saving that needs no new provider — only the
worker container and the owner's Claude token that every routed run needs —
and it works on its own: if it alone brings usage within
the smaller plan, the other stories are optional.

**Independent Test**: in a scratch repository, run the routed workflow against a
stand-in for the agent CLI that records each call and writes canned outcome
files; read which model each phase was dispatched with, in which order, which
files each left, and where the run paused.

**Acceptance Scenarios**:

1. **Given** a repository set up for routing, **When** the owner starts a
   feature, **Then** specify, clarify, plan, checklist, analyze, review and
   converge run on the most capable model, tasks on the lighter one, and
   verify runs the repository's check command with no model.
2. **Given** a phase has finished, **When** the next one starts, **Then** it is
   a new agent with no conversation from any earlier phase, and it finds what
   it needs in the feature's files.
3. **Given** a checkpoint is reached, **When** no answer is given, **Then** the
   run pauses and prints the one command that answers it; **When** the owner
   approves, **Then** the run continues from that checkpoint without redoing
   finished phases; **When** the owner rejects, **Then** the run stops.
4. **Given** clarify has questions, **When** it runs, **Then** they are written
   with a recommended answer each to a file the run shows at a checkpoint, and
   the owner's answers in that file reach the spec before plan starts;
   **Given** clarify has none, **Then** that checkpoint is skipped.
5. **Given** implementation and verify are done, **When** the review runs,
   **Then** it is a fresh agent on the most capable model; converge repeats
   until nothing above LOW remains; **Given** three passes have run and
   findings above LOW remain, **Then** the run pauses for the owner with them.
6. **Given** the Spec Kit CLI is upgraded, **When** the routed workflow next
   runs, **Then** the routing still applies without editing the upgraded
   files, or the run fails naming what it no longer finds.
7. **Given** a repository's copy of the routed workflow is older than this
   repository's, **When** a run starts, **Then** it stops naming the command
   that updates the copy.

---

### User Story 2 - Implementation runs on DeepSeek, contained (Priority: P2)

The implementation phase runs on DeepSeek through the pi coding agent, in a
export inside a contained runtime that sees nothing else of the
machine. Its changes come back as a patch that is judged before it lands, and
the work counts as done only after the project's check command has passed and
a fresh review on the most capable model has found nothing above LOW.

**Why this priority**: it moves the largest share of tokens off the Claude
subscription, but it adds a provider, a credential and a contained runtime, and
the code leaves the machine. It is only worth having once Story 1 works.

**Independent Test**: run the implementation step against a fixture feature with
a stand-in for the external agent that tries to read and write outside its
export, change and delete a guarded configuration file, and fail midway;
read what landed in the feature's worktree, what the run reported and what it
committed.

**Acceptance Scenarios**:

1. **Given** a feature with tasks, **When** the implementation step runs,
   **Then** the agent receives the brief defined in FR-017 and works in a
   export of the run's current commit.
2. **Given** the agent tries to read or write outside its export, or to reach
   a network address not in the egress allow list (FR-007), **Then** the
   attempt fails and nothing outside the export changes.
3. **Given** the agent's patch changes, creates or deletes a lint, format,
   type-check or test configuration file, **Then** the run fails naming the
   file, applies nothing, and the tasks stay unmarked.
4. **Given** the agent reports success, **When** the check command fails,
   **Then** the failures go back to the agent; **Given** two such fix rounds
   have failed in one convergence pass, **Then** the run pauses for the owner,
   who may allow one more round or stop the run.
5. **Given** an opted-in repository whose credential is missing or whose
   contained runtime is not available, **Then** no code is sent and the step
   says what is missing and how to provide it.
6. **Given** a repository that has not opted in, **Then** implementation runs
   on the lighter Claude model in the same contained pass — the same worker,
   export, brief, patch judgment, time limit, verify, review and loop limits;
   the run says so.
7. **Given** either implementing agent fails, times out or is cut off midway,
   **Then** the feature's worktree is unchanged, the export is
   removed, and the run can be resumed once the cause is fixed; **Given** the
   process running the pass was itself killed, **Then** the next start or
   resume removes whatever export, container or volume it left behind.

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
   runs, **Then** it prints the commands that add or update the routing, as it
   does for presets, and changes nothing.
3. **Given** a new repository, **Then** it has not opted in to the external
   provider until the owner opts it in, and the opt-in instruction names the
   provider's data terms.

### Edge Cases

- The owner works interactively in a Claude session instead of starting the
  routed workflow: nothing changes there; routing applies only to routed runs.
- A phase's agent is refused a permission it was not given: the step fails
  naming the refused action and where the allow list is widened.
- The external agent runs out of time or of prepaid credit, or the provider
  returns an error or retires a model: the step fails with the provider's
  message, nothing is applied, and the run can be resumed after the cause is
  fixed.
- The run is interrupted mid-step (terminal closed, machine asleep): the owner
  is told how to continue, and which phases, if any, will run again.
- Two features run at once: each run's agent sees only its own export and
  its own tool cache.
- The fixed cost of starting each phase cold outweighs the saving on a small
  feature: the measurement in SC-001 shows it, and the result is recorded as it
  came out.

## Definitions

- **The feature's files**: the feature directory `specs/<n>-<slug>/`, the
  project's constitution, and the code committed on the feature's branch. They
  are the only channel between phases.
- **Outcome file**: a JSON file a step writes in the feature directory, in a
  shape fixed by a schema the plan defines, saying what the step concluded
  (for example passed or failed, converged or not, findings by severity). The
  run's decisions read only outcome files that validate against their schema;
  they never read an agent's printed text. Files meant for the owner to read
  and answer, such as the clarify questions, are Markdown and are not outcome
  files.
- **Fresh agent**: a separate agent process started for one step, carrying no
  conversation from any other step. Every step that runs a model is one,
  review included.
- **Severity**: CRITICAL, HIGH, MEDIUM, LOW, the scale converge and review
  write in their outcome files. "Blocking" means any finding above LOW.
- **Export**: a copy of the repository's tracked files at the run's current
  commit, with no repository metadata, made for one pass and removed after
  it. The feature's files are committed before it is made, so it holds every
  earlier phase's output.
- **Egress proxy**: the only destination a pass's container can reach — a
  container of its own on a network made for the run, that admits a request only to the hosts that
  pass may use (its own provider's API; for implementation and verify, the
  package registries) and that alone holds the credentials, adding them to
  requests bound for the provider's API.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: A routed run MUST run each phase with the agent, model, effort,
  permissions and output schema its row of the routing assigns, with no model
  or effort switched by the owner by hand; the routing is one declarative
  table, and changing a phase's model or effort is an edit of one row.
- **FR-002**: Each phase that runs a model MUST be a fresh agent; phases MUST
  hand over only through the feature's files.
- **FR-003**: The routing MUST be a workflow run by Spec Kit's own workflow
  engine, and MUST NOT edit files Spec Kit installs (constitution V); each
  repository's copy of it MUST change only through Spec Kit's install command.
- **FR-004**: A routed run MUST pause for the owner at: the clarify questions
  (when there are any), the spec, the plan with its checklist and analysis,
  and the review before implementation is marked done; and, when a limit is
  reached, at FR-014's and FR-015's checkpoints. Every checkpoint MUST be
  answerable with one command without a terminal, and the run MUST resume
  from where it paused.
- **FR-005**: Clarify's questions MUST reach the owner in a file, each with a
  recommended answer, and the owner's answers MUST be written into the spec
  before plan runs.
- **FR-006**: Tasks MUST be marked done only from the review's outcome, after
  the owner's last checkpoint, and only when the latest verify outcome passed
  and the review has nothing blocking; no implementing agent marks tasks.
- **FR-007**: Every agent MUST work in an export inside a
  contained runtime: it MUST NOT read or write anything of the host outside
  that export and its pass's own tool cache, and MUST NOT reach any network
  destination but the egress proxy, which admits only the hosts that pass may
  use.
- **FR-008**: A patch from whichever agent implements that creates, changes or
  deletes a lint, format, type-check or test configuration file MUST fail the
  step, naming the file, with nothing applied. Which files count is decided by
  the repository's existing configuration guard, not by a second list.
- **FR-009**: Every credential the run uses — the external provider's key and
  the owner's Claude token — MUST come from the Keychain and MUST be held only
  by the run's egress proxy, which adds it to requests bound for its
  provider's API, and by the judge's scanner on the host, in memory only; no
  agent, container or check command ever holds one. It MUST NOT appear in a
  command-line argument, in the environment of any host
  process, in any file on the host (repositories, the export and
  temporary files included), in an image or a container's stored
  configuration, in the container runtime's logs, in the run's state or logs,
  or in the agent's session files — nor in a patch, an outcome or a result an
  agent returns: those are also scanned for every credential's exact value
  before anything is applied, a match failing the pass, as a second line
  behind the proxy.
- **FR-010**: Code MUST be sent to the external provider only from a repository
  the owner has opted in, as recorded when the run started — an opt-out
  during a run is honoured, an opt-in during a run is not; otherwise implementation MUST run on the lighter
  Claude model and the run MUST say so.
- **FR-011**: Every program the routed run depends on MUST be declared in this
  repository's manifests (constitution I). Before the phase that needs it, a
  run MUST stop naming any missing prerequisite and how to provide it: the
  routing's scripts, the repository's check command, the container runtime,
  the owner's Claude token, a working `/usr/bin/python3` and the run's egress
  proxy answering, for every routed run, and, for the external path, its
  credential. `/usr/bin/python3` comes with the Command Line Tools, which
  Homebrew's installer — a bootstrap the constitution allows — installs.
- **FR-012**: `sdd-init` MUST install the routing in a fresh repository in the
  same commit as Spec Kit, and MUST print the commands that add or update it
  in a repository that already has Spec Kit.
- **FR-013**: Each script with logic of its own that this feature adds MUST
  ship with a check in `checks/` seen red on its behaviour broken by hand
  (constitution III).
- **FR-014**: Converge MUST stop after three passes with blocking findings
  still open, pausing the run for the owner with those findings, whose options
  are one more convergence pass or stopping. A pass counts as converged only
  when converge reports nothing left to build and no blocking finding.
- **FR-015**: After two failed fix rounds in one convergence pass, the run MUST
  pause for the owner, whose options are exactly one more implement-and-verify
  round or stopping; the work MUST NOT move to another agent unasked. Without
  the owner's retries a run makes at most nine implementation passes; each
  retry adds exactly one.
- **FR-016**: Every step whose result a branch or a later step reads MUST
  leave it in an outcome file; a step whose output is a Spec Kit artifact
  (spec, plan, checklists, tasks) hands over through that artifact, and the
  analysis, which Spec Kit's analyze only reports, is written to a file by the
  dispatcher from analyze's result for the plan checkpoint to show. The run's branches MUST be decided by a deterministic reader that
  validates each outcome file against its schema; a missing or invalid outcome file MUST fail the
  step, never read as a pass. Agent output MUST NOT be interpolated into a
  shell command.
- **FR-021**: Each step's effort MUST be set by its row of the routing and
  MUST NOT follow the owner's interactive effort or any effort environment
  variable; it changes only through a routing layer (FR-027). Each run records
  the level every step was given, and the level each step reports where the
  CLI reports one.
- **FR-022**: A run left `running` by a process that no longer exists MUST,
  on the owner's next resume, stop naming the phases that will run again and
  the command that starts a new run from the existing feature directory at
  the first unfinished phase (Spec Kit 1.2.2 resumes only paused or failed
  runs); a new run from a feature with no finished phase is refused, and the
  owner starts again from the description. A run the engine paused outside a
  checkpoint (interrupted by the owner) is resumed with no verdict: the
  resume cleans up and runs the interrupted step again;
  finished phases' files MUST NOT be rewritten by that new run. A phase is
  finished when its checkpoint was approved, or, for tasks, when its output
  was written; each is recorded in an outcome file as it happens. Whether a
  run's process still exists is judged by its process id together with that
  process's start time, so a reused process id is not mistaken for it.
- **FR-024**: A run MUST stop before any step on a Spec Kit older than the
  version the routing requires, naming the manifest update that brings it.
- **FR-025**: The Spec Kit behaviours the routing relies on beyond its
  version — the run id it fixes, a shell step's timeout, and gate verdicts
  bound to inputs — MUST each
  be asserted by a check, so a
  Spec Kit update that drops one fails the gate before it lands instead of
  silently routing without it.
- **FR-027**: The routing MUST be configurable in four layers, lowest
  precedence first — defaults kept in this repository, a project file
  versioned in the routed repository, a local file there that git ignores,
  and one run's overrides given when the run starts — merged per phase and per
  field. The merged table MUST be validated before any step, an invalid value
  stopping the run naming the layer and field; each run MUST record every
  effective value and the layer it came from, and the owner MUST be able to
  print that table. A layer MAY change only a step's model, within its agent's
  provider, its effort, and its time limit within the phase's ceiling; it MUST
  NOT change a
  step's agent, permissions, prompt or outputs, so no layer can enable the
  external provider, widen a step, or drop a rule from a prompt. The
  effective table MUST be fixed for the whole run, kept where no step can
  change it.
- **FR-026**: Each step MUST load only the context its row names: no MCP
  server, and only the tools and permissions of its profile, read from a copy
  frozen for the run where no step can change it; no step may change a skill,
  a Spec Kit script, an outcome file, the routing, the opt-in or any profile:
  each step runs in the worker container and reaches the repository only
  through a patch limited to its writes (FR-028), so an unattended
  step can do nothing its phase does not need and same-model steps reuse the
  prompt cache.
- **FR-023**: The lighter model's implementation pass MUST be allowed to run
  the repository's check command, and nothing wider than its
  `implementer` profile; its writes reach the repository only as a patch
  judged against the protected set (FR-028).
  What the check command itself writes outside the export (caches, temporary
  files) is not judged: the same command runs unattended in verify.
- **FR-028**: Every agent step and every verify MUST run inside the worker
  container on a copy with no repository metadata, and its output MUST reach
  the repository only as a patch limited to the paths that step may write; no
  agent writes the worktree directly, no code an agent wrote runs outside the
  container, and no host tool reads anything an agent wrote as configuration.
- **FR-029**: A patch that changes the check command's own script (the file
  the frozen command names, when it names one) or a file the configuration
  guard covers MUST be flagged: verify records it, it is a blocking finding
  until the owner approves the last checkpoint, which shows the changed files,
  since a weakened check would otherwise pass its own verify. Tests are judged
  by the review (FR-019).
- **FR-030**: A patch that adds or changes a file the owner's tools may run
  later without asking — git hooks, CI workflows, editor tasks, executable
  files — MUST be listed at the owner's last checkpoint; such a file never runs
  during the run (FR-028), and whether it is merged is the owner's review.
- **FR-031**: The package registries MUST be read-only to every pass: the
  egress proxy terminates TLS for each registry host with a certificate
  authority made for the run, whose private key never leaves the proxy's
  container, and forwards only `GET` and `HEAD` — on `github.com`, only to
  release and archive downloads; any other method or path is refused and
  logged. The worker trusts that authority for the pass and nothing a pass
  runs may publish, push or upload.
- **FR-032**: The worker image MUST be built from inputs pinned by hash —
  the base image by digest, Debian packages from a dated archive snapshot at
  exact versions, npm packages from a lockfile with integrity hashes, every
  downloaded tool by checksum — and `prepare-worker` MUST refuse an image whose
  installed packages and versions differ from the inventory committed beside
  its recipe, naming the difference.
- **FR-020**: Verify MUST be deterministic: it runs the repository's check
  command and records its exit status and the failures in its outcome file,
  with no model involved.
- **FR-017**: The implementing agent's brief MUST name: the tasks to do —
  every task in `tasks.md` not marked done, converge's appended ones included
  —, the spec, the plan and every other file `/speckit-plan` wrote in the
  feature directory (research, data model, contracts, quickstart), the
  constitution, the owner's test-first rules (tests
  from the acceptance scenarios first, seen to fail, then the simplest code;
  no change to a check's configuration; nothing outside the tasks), and, on a
  fix round, the latest verify outcome. Both implementing agents get the same
  brief.
- **FR-018**: Each implementation pass, by either agent, MUST end within a
  time limit, 30 minutes of wall-clock time unless a routing layer sets another
within the phase's ceiling of 60 minutes (a value beyond it is refused, since
the workflow's own limit for the step sits just above the ceiling),
  enforced by the run itself before any outer limit can cut it off, so the
  pass always stops its agent and cleans up; a pass that spans the machine's
  sleep may reach its limit on waking, which fails it with nothing applied; the run MUST report each pass's usage — the provider's tokens and
  price for the external agent, the reported Claude usage for the lighter
  model.
- **FR-019**: A deleted or weakened test MUST be a blocking finding of the
  review.

### Key Entities

- **Workflow**: the order of phases, the checkpoints and the loop limits —
  one workflow file, copied into each repository by Spec Kit.
- **Routing table**: one row per phase — agent, model, effort, permission
  profile, output schema, time limit — merged from four layers (FR-027) and
  read by the dispatcher at every step.
- **Run**: one pass of a feature through the routed workflow, with its state,
  its pauses and the usage each step reported.
- **Outcome file**: see Definitions.
- **Opt-in**: a repository's recorded consent to send its code to the external
  provider.
- **Check command**: the one command a repository declares for verify to run.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A routed run, opted in to the external provider, uses at least
  40% less Claude subscription usage than the baseline run, by the median of
  three counted runs per arm, on each of the story-workers eval harness's two
  fixtures, `checkout` and `wordstats`, separately: both fixtures must meet
  it. The range is reported beside each median. Usage counts every attempt of every Claude step at list price as
  each reports it, summed for both arms by one tool, the harness's.
  - **What both arms run**: the routed workflow's steps from tasks to
    marking (contracts/workflow.md 11–16), on the fixture's committed spec
    and plan, from a state that removes the fixture's `tasks.md`. Every
    earlier phase runs on the most capable model in both arms, so starting at
    tasks leaves out nothing the routing changes and every difference in
    input between the arms.
  - **The baseline**: the same steps, run with a routing layer that puts
    every Claude step on the most capable model (FR-027), and each convergence pass's implement-and-verify loop
    replaced by one Spec Kit implement step on that model, with the
    story-workers preset as `sdd-init` installs it today (its workers on the
    lighter model, its decision 0001); verify runs once after it, and there
    is no `fix-stuck` stop.
  - **Checkpoints**: `review-done` is approved; a stop at `fix-stuck` or
    `converge-stuck` is answered `sdd-run abort`. The same rule counts runs in
    both arms: a run counts only if its last verify passed; one that reaches
    either stuck checkpoint, or a baseline run whose last verify failed, is
    not counted and is run again under the harness's rerun limit. If either
    arm on a fixture reaches that limit with fewer than three counted runs,
    SC-001 and SC-002 are not met on that fixture, and the counts are
    recorded.
  - **Recorded per run**: Spec Kit, Claude Code, container runtime and pi versions,
    and the dotfiles commit.
  - **Where**: the harness already fixes fixture layout, hermetic setup,
    held-out tests and version matching across arms; it runs single-step
    arms today, so a feature of its own in that repository extends it to
    multi-step arms with these checkpoints and counting rules. This criterion
    is met or not by that feature's recorded result, as it comes out.
    Whether the owner moves to the smaller plan is decided afterwards, from a
    week of real usage, not here.
- **SC-002**: On each fixture, the lowest number of held-out acceptance tests
  any of the routed arm's three counted runs passes is at least the baseline's
  median over its three, and the routed arm's own check command passes in
  every counted run.
- **SC-003**: The containment probe attempts, from inside the agent's runtime:
  reading the owner's SSH keys, the Keychain and another repository; writing
  to the feature's worktree outside the patch, to the home directory and to
  another repository; and reaching a network address outside the egress
  allow list. All of them fail, and nothing on the host changes.
- **SC-004**: With the repository not opted in, nothing is sent to the
  external provider and implementation runs on the lighter model; with it
  opted in but the credential missing or the runtime unavailable, nothing is
  sent and the step's output names what is missing.
- **SC-005**: Starting a feature takes the owner one command; each checkpoint
  takes one approval, plus writing the answers in the clarify file at that
  checkpoint; the owner never types a model name.
- **SC-006**: Every check this feature adds has been seen red with the
  behaviour it guards broken by hand.

## Assumptions

- **Threat model** (research R20, R23): the agents are protected against as
  makers of mistakes and as carriers of instructions planted in what they
  read — the repository, a dependency, a provider's response. Protected: the
  owner's credentials and machine, the run's governance, and the checks
  against silent weakening. Accepted as residual, and not defended further: a
  deliberately malicious agent smuggling repository code out encoded in the
  read requests it is allowed to make (FR-031 leaves it no way to publish,
  push or upload, and no host whose logs an attacker reads); a planted
  automation file running after the owner merges it, which FR-030 lists at
  the last checkpoint so the owner's review can catch it.
- **Reproducibility** (research R26): the worker image is reproducible in its
  installed packages and versions, verified on every build (FR-032), not in
  its bits: Apple's builder (container 1.6.0) gave two no-cache builds of one
  recipe different digests with `SOURCE_DATE_EPOCH` set, and has no output
  option to rewrite timestamps (observed 2026-10-21).

- "Most capable model" is Claude Opus and "lighter model" is Claude Sonnet,
  both through the owner's Claude subscription; the external provider is
  DeepSeek V4 Flash through its own prepaid API key, reached
  through the pi coding agent. The names, and the versions the plan pins, are
  the owner's choice of 2026-10-21 and move only by a deliberate edit to this
  repository or a routing layer (FR-027); a retired model or a moved pin surfaces as a failed step naming
  it, not as a silent change. Claude models are therefore named by full model
  id, not by an alias such as `opus` that upstream repoints. The Claude Code
  CLI and pi are pinned in the worker image and move by an edit to it, which
  `drift.sh` reports when upstream moves; the container runtime (a Homebrew
  formula) is not pinned. A changed flag or a missing field in any of their
  outputs fails the step naming it, and a missing usage figure is never read
  as zero; each run records all three versions. DeepSeek's id `deepseek-flash` names no version
  either: a pass whose response reports a model other than the one
  configured fails, naming both; if the response reports only the alias
  itself, a repoint behind it cannot be detected, and `deepseek-flash` is
  accepted as unpinned, like the container runtime; pi moves only by an edit to the worker
  image, and a pass whose output lacks a field the run reads fails naming
  it.
- The routed workflow is an addition: the interactive way of running Spec Kit
  phases in one Claude session stays as it is.
- A routed run never calls Spec Kit's implement command, so the story-workers
  preset, which extends that command, takes no part in a routed run; it stays
  installed for interactive sessions. Whether to keep it is decided from
  SC-001's result.
- Opt-in to the external provider is per repository and off by default: code
  from private repositories such as `renta` or `tli` leaves the machine only
  by the owner's explicit choice. What the provider retains is governed by its
  own terms, which this feature names but cannot change.
- That the implementing agent follows the test-first rules in its brief is an
  assumption, not a guarantee: the final patch cannot show whether a test was
  seen to fail first. SC-002's held-out tests and FR-019's review are what
  measure the result; the order of work is not measured.
- The 40% target in SC-001 is the owner's goal (Pro is a fifth of Max 5x's
  allowance) discounted for what routing cannot move: the judgment phases stay
  on the most capable model.
- Three counted runs per arm on two fixtures follow Anthropic's guidance for
  agent evals ("Demystifying evals for AI agents": multiple trials, because
  outputs vary between runs; small samples suffice for a large effect, and
  40% is one). It is still a small sample: the result reports the median and
  the range, not a significance level.
