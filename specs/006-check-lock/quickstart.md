# Quickstart: validating one check suite at a time

From the repository root, with the tools `docs/checks.md` lists installed,
and no other `check.sh` running on the machine.

1. The lock's own checks, and the runner's nested runs under the lock:

   ```bash
   ./check.sh --strict      # ends "All checks passed"; the "Run lock" section lists its cases, "Runner" passes
   ```

2. Two runs from two worktrees (any two checkouts of this repository):

   ```bash
   ./check.sh > /dev/null & sleep 1
   (cd ../<other worktree> && ./check.sh)
   ```

   Expected: the second prints `check.sh: waiting for the run of pid <pid> in
   <this repository> to finish` once, then its sections, after the first ends.

3. A dead holder: start `./check.sh &`, `kill -9` it, run `./check.sh`; it
   starts at once with no waiting line.

4. Abandoning the wait: with a run in progress, start a second in a terminal
   and press `^C` at the waiting line; it ends with status 130 and prints no
   section. Then a third run starts as soon as the first ends.

5. The cost on an idle machine: `time ./check.sh --strict` against the
   numbers in research.md's Measurements.
