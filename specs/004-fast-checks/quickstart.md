# Quickstart: validating fast tiered checks

From the repository root, with the tools `docs/checks.md` lists installed.

1. The runner's own checks:

   ```bash
   ./check.sh --strict      # ends "All checks passed"; the "Runner" section lists its cases
   ```

2. The hook on a docs-only change (no commit is made):

   ```bash
   echo >> docs/checks.md && git add docs/checks.md
   time githooks/pre-commit # the dim line names the sections not selected
   git restore --staged docs/checks.md && git checkout docs/checks.md
   ```

   Expected: only the sections without a `# covers:` line run.

3. The hook on a file one section covers:

   ```bash
   echo '# x' >> macos/touchid.sh && git add macos/touchid.sh
   time githooks/pre-commit # Touch ID for sudo runs, with every section whose pattern matches the path (50-install's macos/*) and the undeclared ones
   git restore --staged macos/touchid.sh && git checkout macos/touchid.sh
   ```

4. The fail-safe: stage `check.sh` (any edit) and run the hook; the dim line
   says every section is selected because `check.sh` is staged.

5. The full run in parallel: `time ./check.sh --strict` against the sum in
   research.md's Measurements.
