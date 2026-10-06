---
name: diagnose
description: Find the root cause of a bug before fixing it - reproduce, locate where the bad value first appears, test ranked hypotheses one at a time, then fix at the source behind a regression test that went red first.
when_to_use: Before fixing or looking into any bug whose cause has not been shown yet, including "X fails, fix it" and "can you look into <symptom>?" - a failing or flaky test, an error, a crash, a wrong result, a slowdown, a regression, or "works here but not in CI / on the other machine". Also when a first fix did not hold. Not for a test written to fail first; work inside a /speckit-* command the user started; building new behaviour; Claude Code's own session problems (that is the built-in /debug).
argument-hint: "[the symptom, or the failing command]"
---

# Diagnose

The symptom: $ARGUMENTS

No fix before the cause is understood. Each step ends on evidence shown in
the conversation. If the user asked to look into it rather than to fix it,
stop after step 3: remove the instrumentation and experiments, then report
the cause and the proposed fix.

## 1. Reproduce

- Read the whole error: message, stack, and the lines just before it.
- Find a command that goes red on the symptom and run it. Fix only what you
  have seen go red.
- When a run is cheap and the cause is not yet in sight, make it tight: cut
  inputs and steps one at a time, re-running after each cut, until removing
  anything left turns it green. Revert every cut to tracked files. The
  minimal case becomes the regression test in step 4.
- Intermittent: when a run is cheap and touches nothing outside the repo
  (no network, no shared database), loop it until you know the rate
  (`for i in $(seq 50); do ...; done`). A low rate gets raised first, with
  parallel runs, load or narrower timing, so a fix can be shown to change it.
- A slowdown: measure a baseline before changing anything.
- Cannot reproduce: say so, and gather what does exist (logs, exact
  versions, environment, input). If nothing goes red, stop and report what
  was gathered and what would reproduce it; no fix.

Done when one command, run and shown here, goes red on the symptom the user
reported, not on a failure next to it.

## 2. Locate

Find where the bad value first appears, not where it surfaced.

- What changed: `git log` and `git diff` since the last known good state.
  With a known good commit and a reproducing script, `git bisect run` it in
  a throwaway worktree, with the script kept outside the tree so every
  commit sees it, and `git bisect reset` when done.
- Compare with a path that works: the same call with other input, the same
  code on another branch, the same command on the machine where it passes.
  List every difference: versions, env vars, cwd, locale, TZ, file order.
- Instrument at the boundaries between components: log what each layer
  receives and returns, with one unique tag on every line (`[DBG-4f2a]`),
  run once, and read where the value goes wrong. Then trace backwards to
  where it was produced.
- A test that passes alone and goes red in the suite: bisect the suite to
  find the test that leaves state behind.

Done when you can name the line, commit or input where the value first goes
wrong.

## 3. Hypotheses

When step 2 has not already shown the cause, list two to four, ranked,
each as "X causes it, because <evidence>; if so, <change> makes
<observation>." Show the list, so the user can re-rank it from what they
know, and go on without waiting: test from the top with the smallest
experiment that could prove each wrong, one change at a time. A disproved
hypothesis is marked disproved, and the next starts from what it taught.

## 4. Fix

1. Turn the minimal case into a test and watch it go red for the bug's
   reason. If no seam lets a test reach the real chain, say so and name the
   missing seam rather than write a test that passes for the wrong reason.
2. Fix where the bad value is produced, as found in step 2.
3. Remove the instrumentation: a search for its tag, untracked files
   included, returns nothing.
4. Run the test, the step 1 command as first reported, then the whole
   suite.
5. A wait on timing becomes polling for the condition; a longer sleep is
   not a fix.
6. The commit message names the hypothesis that held and the ones ruled out.

## Stop rule

A fix that did not hold sends you back to step 2 with what it showed. After
the third, stop: report the hypotheses tried and what each ruled out, and
say the design is likely wrong. That is a conversation with the user, not a
fourth patch.
