# Contract: `check.sh` and the pre-commit hook

## Invocation

```text
./check.sh [--strict] [--staged]
```

- Flags in any order, each at most once in effect. Anything else: usage on
  stderr, exit 2 (as today).
- `--strict`, or `CI` set: a skip is a failure (unchanged).
- `--staged`: run only the sections the staged paths select (research R4).
  Without it, every section runs.

`githooks/pre-commit` runs `"$repo/check.sh" --strict --staged` and refuses
the commit on any non-zero exit, printing the checks' output and the
`--no-verify` hint (unchanged otherwise).

## Sections

- A section is `checks/<name>.sh`, directly in `checks/`. Run in file-name
  order of output.
- `checks/lib/*.sh` are sourced once by the runner before any section; their
  functions are available to every section. They are not sections.
- Each section runs in its own subshell with the runner's helpers (`check`,
  `skip`, `STRICT`, the colours, `this_repo_git`) and the shared helpers, and
  nothing another section defines.

## Coverage declaration

```text
# covers: <pattern> [<pattern>…]
```

- At the start of a line in the section file; any number of such lines; the
  patterns are their union.
- A pattern is a bash `[[ == ]]` pattern over a repository-relative path; `*`
  crosses `/`. Read with globbing off.
- No `# covers:` line: the section runs on every change.

## Output

- Each section's output, whole, in file order, then one verdict line: `All
  checks passed` (exit 0) or `Some checks failed` (exit 1).
- Under `--staged`, before the sections, one dim line:
  - `Staged changes select N of M sections; not selected: <name> …`, or
  - `Staged changes select every section: <path> is staged`, or
  - `Staged changes select every section: the staged paths could not be read`.
- A section that stops before its last line adds, in its place:
  `  FAIL <section> stopped before its last line (exit <status>)`.
- Sections not selected are neither `ok`, `FAIL` nor `skip`; they do not
  change the verdict.
