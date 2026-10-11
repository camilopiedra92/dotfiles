# Maintenance

## Finding drift

```bash
./drift.sh
```

`brew bundle check` only asks whether everything declared is installed, and a
subset always answers yes to that. The gap it leaves is everything installed and
never written down, which is the direction drift actually grows in. `drift.sh`
reports both, plus VS Code extensions, plus any runtime a PATH lookup can reach
that did not come from mise — the rule stated at the top of this file.

That check used to ask Homebrew for a list of formulae, which was the wrong
question twice over. Homebrew is one way to acquire a second runtime; a vendor
`.pkg` is another, and this machine had a python.org framework under
`/usr/local/bin` for over a year that nothing here ever mentioned. And what
breaks a script is not that a second runtime exists but that some shell resolves
it, so the question is which binaries are reachable — every entry on `PATH`, not
just the winner. mise sits at the front here, so looking only at the winner sees
nothing while the shadowed copy still wins in any shell that never read
`.zshenv`. Exemptions are listed in the file, keyed by directory *and* command,
each with the reason it is exempt and what would end it.

It also asks endoflife.date whether anything mise installed has stopped being
supported. That is drift against a calendar rather than between two files: a pin
that was right when it was written becomes wrong on a date, and the only symptom
is that security fixes quietly stop arriving. It would have caught the node 25
this repo was serving through Homebrew, end of life since 2026-06-01.

And it compares the vendored schemas under `schemas/` against what starship and
mise publish today, reporting the exact `curl` to refresh one that has moved.
That is the other half of the deal made above: vendoring keeps the commit path
offline, and this keeps the vendored copy honest. Compared as parsed JSON, so an
upstream reindent is not reported as a change worth acting on.

It asks the same pair of questions about `uv tool`, which has no
`brew bundle check` of its own. `uv-tools.txt` is compared against the receipts
uv writes under `uv tool dir` — in both directions, and on the reference rather
than the version, so a pin that moved is visible and not merely a number that
happens to match. Then it asks GitHub whether a pinned tag has been superseded,
which is calendar drift again.

And it asks whether each installed tool still runs, which nothing else here would
notice. A `uv tool` environment borrows its base interpreter instead of copying
it, so removing that interpreter leaves the command on `PATH` and dead: still
installed, still declared, still the right version, `bad interpreter` when you
type it. It found exactly that on the first run — a tool built against an
Anaconda python that is no longer on this machine.

It also asks `macos/defaults.sh check` whether `macos/defaults.txt`, plus
this Mac's own `macos/machines/<profile>/defaults.txt`, matches the machine
— the same parser `install.sh` applies with, so the comparison cannot
disagree with what applying it would do.

And it asks whether every repository under `~/Development` has a remote.
On the work Mac Time Machine is banned by policy, so a remote is not a
convenience but the only backup a repository has; on the personal one Time
Machine is allowed, but its disk sits next to the laptop, and the remote is
still the only copy that is somewhere else. A repository with no remote
has no copy anywhere else. Only the top level of
`~/Development` is checked: a project is a directory directly under it with
a `.git` (or, for a worktree, a file pointing at one), and whatever
repositories that project nests inside itself are its own business, not
this script's.

It is not part of `check.sh` and CI never runs it, on purpose. Every check in
there has to mean the same thing on a runner as on this laptop; this one cannot,
because a runner arrives with its own preinstalled packages and would report
drift forever. The end-of-life check adds a second reason: it needs the network,
and a check that fails because DNS blinked has no business gating a commit.

## Updating the pins

```bash
./bump-tools.sh
```

Resolves each tool's latest release, downloads the artifact, records its SHA256
and rewrites both `ci.yml` and `.github/tool-checksums.txt`. It refuses to walk
a pin backwards, and refuses a version that is tagged but whose artifact is not
downloadable yet, which Ghostty's tags do briefly.

`.github/workflows/tool-updates.yml` runs it on the 1st of each month and opens
a pull request if anything moved. It authenticates with a GitHub App rather
than the default token, because a pull request opened with `GITHUB_TOKEN` does
not start workflows and so could never satisfy the required check.

That pull request does not auto-merge, deliberately. The hashes in it are
whatever upstream is publishing at that moment, which is exactly what
`tool-checksums.txt` exists not to take on trust. CI proves the new versions
install and everything still passes; you decide they should be trusted.

Those pins are the CI toolchain, and nothing else here updates on its own.
`install.sh` passes `--no-upgrade` to `brew bundle`, which otherwise upgrades
every outdated dependency it finds: running the script after a `git pull` to
pick up a new symlink would also pull down whatever went stale meanwhile, which
for the casks means several hundred megabytes of applications that update
themselves anyway. Upgrading is `brew upgrade`, when you mean it.

Formatting is defined in `.editorconfig`, which shfmt parses natively and the
EditorConfig extension applies in VS Code, so the editor and the hook cannot
disagree about what the code should look like.

`githooks/pre-push` refuses any push that would rewrite or delete `main`,
detected as a push whose remote tip is not an ancestor of what is being sent.
It is defence in depth, not the real defence: it only covers clones that have
it installed and `--no-verify` walks past it. The real one is the server-side
ruleset described under [Changing something](../README.md#changing-something), which
applies no matter who pushes or from where. The hook earns its place by failing
on your machine instead of after a round trip, and by still being there if the
ruleset is ever relaxed. A deliberate rewrite is still possible, it just has to
be deliberate: `git push --no-verify --force-with-lease`.
