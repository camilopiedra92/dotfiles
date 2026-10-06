---
name: wrap-up
description: Close a work session cleanly - report git and PR state in every repo touched, close or name what is left, route each durable learning to where it belongs, push on the user's go, and print a prompt to resume in a new session.
when_to_use: The user is ending or pausing a session ("I'm closing", "wrap up", "let's leave it here", "before I go", "continue in a new session", "give me the prompt for the next session", "any learnings to save?", "leave git clean"). Not for finishing one task mid-session.
argument-hint: "[anything to carry into the next session]"
---

# Wrap up

Notes from the user: $ARGUMENTS

Report first, change nothing until step 4, and change only what the user
agrees to.

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

## 2. What is left

From this session's work: unfinished tasks, a red suite, review findings
not applied, TODOs added, temporary files or branches created for it.
Close what is inside the task's scope now. List the rest, each with why it
is open and what it needs: a decision from the user, or a next session.

## 3. Learnings

Only what a later session would otherwise get wrong or rediscover. For each
one, name its destination and show the text before writing it:

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

Write the agreed learnings. Commit and push following each repo's own
rules and the global ones: a branch rather than the default branch, a
draft PR while its independent review is pending, ready only when the
review is back. Remove a worktree only when it is clean; never with
`--force`.

## 5. Resume prompt

Print, in a code block, a prompt the user can paste into a new session:
the goal, the current state (repo, branch, PR, last commit), the next
concrete step, open questions, and the files to read first. It names
facts, not plans written as findings. It is not saved to a file unless the
user asks; what must persist went to step 3.
