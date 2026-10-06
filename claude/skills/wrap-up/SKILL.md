---
name: wrap-up
description: Close a work session cleanly - report git and PR state in every repo touched, close or name what is left, route each durable learning to where it belongs, push on the user's go, and print a prompt to resume in a new session.
when_to_use: The user is ending or pausing a session ("I'm closing", "wrap up", "let's leave it here", "before I go", "continue in a new session", "give me the prompt for the next session", "any learnings to save?", "leave git clean"). Not for finishing one task mid-session.
argument-hint: "[focus of the next session]"
---

# Wrap up

Focus of the next session, if given: $ARGUMENTS. Shape the resume prompt
around it.

Steps 1 to 3 only read and report. Changes happen in step 4, and only the
ones the user agrees to.

## 1. State

For every repository this session touched (the working directory, the
additional ones, any other edited here):

- `git status --short --branch`, unpushed commits (`git log @{u}..` or "no
  upstream"), `git stash list`, `git worktree list`.
- Local branches not merged into the default branch, and which hold work
  from this session.
- `gh pr list --author @me --state open`, and for each of this session's
  PRs its CI (`gh pr checks`) and whether it is draft or ready.

Show it as one short table per repo. Say plainly when a command could not
run (no remote, no gh auth).

Then what this session started outside git: every background shell or agent
still running, and any process it left behind (`pgrep -fl` on a distinctive,
fixed part of its command: the pattern is a regex),
one line each with what it does and what happens if it keeps running. They
can outlive the session: two shells were still running after /exit on
2026-10-06.

## 2. What is left

From this session's work: unfinished tasks, a red suite, review findings
not applied, TODOs added, temporary files or branches created for it,
background work still running, each with the user's choice to make: let it
finish, stop it, or stop it and take over its command.
Mark what can be closed inside what was agreed, to close in step 4. List
the rest, each with why it is open and what it needs: a decision from the
user, or a next session.

## 3. Learnings

Only what a later session would otherwise get wrong or rediscover. For each
one, name its destination and show the text before writing it:

- A mistake a tool could catch: a check with a tool the repo already has (a
  lint rule, type check, test or hook), proposed before reaching for a
  written rule. A new tool is a dependency, and asked about as one.
- A rule every change in a project must meet: that project's constitution.
- A decision a later feature would otherwise reopen: `docs/decisions/`, as
  the global CLAUDE.md describes.
- A convention or command for one project: that project's CLAUDE.md.
- A working preference across projects: the global CLAUDE.md, which lives
  in `~/dotfiles`, so it goes through a branch and PR there.
- A repeated procedure: a skill.
- State of ongoing work, a fact about the user, a pointer elsewhere: auto
  memory, following its own rules (update a file before adding one).

Nothing the repo or git history already records. If there is nothing, say
so; an empty list is a valid result.

## 4. Apply, on the user's go

Each background task still running gets the choice the user made in step 2:
it finishes on its own, it is stopped, or it is stopped and its command is
handed over for a terminal of their own, so no two copies run. A merge
waiting on CI follows the global merge rule: `gh pr merge --auto` where a
ruleset requires the checks, `merge-on-green <n>` where none can. Nothing
keeps running after the session without the user knowing.

Close the loose ends marked in step 2 and write the agreed learnings.
Commit and push following each repo's own rules and the global ones: a
branch rather than the default branch, a draft PR while its independent
review is pending, ready only when the review is back. Remove a worktree
only when it is clean and is not the one this session runs in; never with
`--force`.

## 5. Resume prompt

Print, in a code block, a prompt the user can paste into a new session:
the goal, the current state (repo, branch, PR, last commit), the next
concrete step and the skill or command to start it with, open questions,
and the files to read first.

- Point at specs, plans, PRs and commits by path or URL rather than
  summarising them.
- State facts; a plan is labelled as a plan.
- Secrets, tokens and personal data become `<REDACTED>`.

It lives in the reply, and goes to a file only if the user asks; what must
persist went to step 3.
