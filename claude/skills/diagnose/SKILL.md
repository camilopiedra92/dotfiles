---
name: diagnose
description: Find the root cause of a bug before fixing it - reproduce, locate where the bad value first appears, test one written hypothesis at a time, then fix at the source behind a regression test that failed first.
when_to_use: Before fixing any bug whose cause has not been shown yet, including "X fails, fix it" - a failing or flaky test, an error, a crash, a wrong result, a regression, or "works here but not in CI / on the other machine". Also when a first fix did not hold. Not for a test written to fail first; work inside a /speckit-* command the user started; building new behaviour; Claude Code's own session problems (that is the built-in /debug).
argument-hint: "[the symptom, or the failing command]"
---

# Diagnose

The symptom: $ARGUMENTS

No fix before the cause is understood. Each step below ends with evidence
written in the conversation, not with a belief. If the user asked to look
into it rather than to fix it, stop after step 3: revert the instrumentation
and experiments, then report the cause and the proposed fix.

## 1. Reproduce

- Read the whole error: message, stack, and the lines just before it.
- Find the shortest command that shows it and run it. Record the command and
  its output.
- Intermittent: when a run is cheap and touches nothing outside the repo
  (no network, no shared database), run it in a loop until you know the
  rate (`for i in $(seq 50); do ...; done`), so a fix can be shown to change
  it.
- Cannot reproduce: say so, and gather what does exist (logs, the exact
  versions, environment, input) before guessing. Do not fix what you have
  not seen fail.

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
  receives and returns, run once, and read where the value goes wrong. Then
  trace backwards from there to where it was produced.
- A test that passes alone and fails in the suite: bisect the suite to find
  the test that leaves state behind.

## 3. Hypothesis

Write one: "X causes it, because <evidence>; if so, <change> will make
<observation>." Test it with the smallest experiment that could prove it
wrong, changing one thing at a time. A disproved hypothesis gets written
down as disproved; the next one starts from what that taught.

## 4. Fix

1. Write a test that reproduces the bug and watch it fail for the bug's
   reason, not an import or setup error.
2. Fix at the source found in step 2. A guard where the symptom appears is
   not a fix unless that is where the value is produced.
3. Remove the instrumentation.
4. Run the test, then the whole suite.
5. Waits on timing are replaced by polling for the condition, never by a
   longer sleep.

## Stop rule

A fix that did not hold sends you back to step 2 with what it showed. After
the third, stop: report the hypotheses tried and what each ruled out, and
say the design is likely wrong. That is a conversation with the user, not a
fourth patch.
