---
name: brainstorm
description: Shape an open idea into an agreed brief before anything is specified or built - intent questions one at a time, 2-3 approaches with a recommendation, then a hand-off to a direct change, a spike or /speckit-specify.
when_to_use: The user brings a new feature, tool or project whose intent, scope or approach is still open ("I want to build...", "I have an idea for...", "how should we approach...", "let's think through..."), before /speckit-specify or before writing code. Not for bug fixes, for requests that already say what to build and how, inside a /speckit-* command the user started, or once the feature has a spec under specs/.
argument-hint: "[the idea, in a sentence or two]"
---

# Brainstorm

The idea: $ARGUMENTS

The outcome is an understanding the user recognises as theirs and a chosen
approach with its alternatives on record. Nothing else: no files, no code, no
scaffolding, no dependencies. Reading the project is allowed throughout.

If the idea is neither above nor in the conversation, ask for it in one
sentence and stop.

## 1. Read before asking

Read what answers questions without the user: the project's CLAUDE.md, its
constitution (`.specify/memory/constitution.md`) if there is one, the code the
idea touches, recent commits, and the `specs/` and `docs/decisions/` entries
near it. Never ask what the request or the repo already says.

## 2. Find the intent

Who it is for, what outcome they want, what would show it worked, and what
is out of scope. The genre of the thing does not say why the user wants it.

- One question per message. Prefer AskUserQuestion with 2-4 options, your
  recommended one first and marked; open text when the answer can't be
  listed.
- Ask the questions whose answer changes the design, most decisive first,
  and stop when the remaining ones would not change it.

## 3. Write the understanding back

A short note: outcome, users, constraints, success criteria, out of scope.
Mark what the user said apart from what you assumed. Ask for corrections
and apply them before going on.

## 4. Approaches

Two or three that differ in substance, not in detail. For each: what it is,
what it costs, what it makes hard later, and the risk. Recommend one and say
why. When it is real, one option is smaller than asked or not building it.
If only one approach is viable, say so and why instead of inventing others.

When the way to do it is unknown and no reading settles it, that is not a
choice between approaches: propose a spike (step 5).

## 5. Hand off

Size the path with the "Spec-driven development" section of the global
CLAUDE.md and say which one and why; the user can override. Hidden complexity
found later moves the path up, never down.

- **Direct change.** The brief plus the chosen approach. Build it only after
  the user says go. The rejected approaches go in the commit message.
- **Spike.** The question it answers and the cheapest probe that answers it,
  on a throwaway branch. The output is an answer, not code to keep.
- **Spec Kit.** Two blocks, ready to run:
  - the `/speckit-specify` description: what and why only (users, outcome,
    success criteria, scope). No stack, no APIs, no structure:
    `/speckit-specify`'s quality checklist flags and strips them.
  - the `/speckit-plan` guidance: the chosen approach, the alternatives and
    why each lost. The plan only has to consider its input, so once it has
    run, check that `research.md` records them.

  A repo without `.specify/` runs `sdd-init` first.

Stop there. Run the next command only when the user says so.
