# Quickstart: validating the script checks

From the repository root:

```bash
./check.sh
```

Expected: the sections "Git hooks", "Tool versions" and "dev-nuke" each list
their new checks as `ok`, and the run ends `All checks passed`.

## Seeing each check go red

For each acceptance scenario in [spec.md](spec.md), break the script by hand
in the working tree, run `./check.sh`, confirm the matching check fails naming
that scenario, then restore the script (`git checkout -- <script>`). Examples:

| Break | Expected failure |
|---|---|
| `githooks/pre-push`: drop the deletion refusal | push guard, deletion case |
| `githooks/pre-commit`: drop `--strict` | commit gate, strict mode |
| `bump-tools.sh`: skip `mv "$tmp/checksums"` | pin updater, pin and checksum move together |
| `bin/dev-nuke.sh`: send `-KILL` instead of `-TERM` first | reset, TERM before KILL |

## Proving the reset touches nothing

While `./check.sh` runs, nothing is signalled, no notification appears, and
`/tmp/.s.PGSQL.5432` (if Postgres is running) is still there afterwards.
