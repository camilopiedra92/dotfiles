# Git

## Git config lives at its XDG paths

Git is linked to its XDG paths (`~/.config/git/config` and `~/.config/git/ignore`)
and not to `~/.gitconfig` and `~/.gitignore_global`. The two cannot coexist —
git reads both and the legacy one wins — so `install.sh` removes the old paths
after linking the new ones. Using the default ignore location is also what lets
`core.excludesfile` disappear from the config: naming a non-standard path is the
only reason that option ever needs to exist, and doing so silently disables
`~/.config/git/ignore` for everything else that expects to find it there.

## Commit signing

Every commit and tag is signed, and the signature comes from the SSH key
rather than from GPG. The same key that authenticates to GitHub signs the
commits: it lives in the agent, the Keychain unlocks it, and GitHub shows the
commit as Verified. GPG would buy nothing here and cost a second key, a second
agent, and an expiry date to remember. The one thing SSH signatures do not
carry is a web of trust, and nothing here ever used one.

The pieces are split by what they are, not by tool:

- **`git/config` holds what is safe without a key** — `gpg.format = ssh` and
  the `allowed_signers` path — because that file is live on every machine from
  the first clone, and nothing in it may break a machine that has not run
  `install.sh` yet.
- **`~/.config/git/config.local` holds the key and the switch**:
  `user.signingkey` next to the name and email, and `commit.gpgsign` and
  `tag.gpgsign` next to that. The key names a file on one machine and is
  identity in the same sense the email is, which is why the repo can be public.
  The switch is there for a less obvious reason: a signing policy that depends
  on a per-machine secret lives with the secret. Versioned, `gpgsign = true`
  would be read the moment the repo is linked and fail every commit on a
  machine whose key does not exist yet — including the commit that would fix
  it. Written by the same step that writes the key, the two cannot disagree.
- **`~/.config/git/allowed_signers` is for local verification.** GitHub keeps
  its own copy of the public key and checks against that; `git log
  --show-signature` and `git verify-commit` on this machine check against this
  file, one `email key` line per identity. `install.sh` rewrites it whole from
  the current identities and keys, so it can never hold a stale line.
- **`ssh/config` makes the key usable without typing.** `AddKeysToAgent` loads
  it into the agent on first use and `UseKeychain` stores the passphrase in the
  Keychain, so it is typed once per machine and never per push — and never
  per commit either, once the login agent below has run.
  Its `Include config.local` comes *first* because ssh takes the first value it
  finds for an option: a host that needs its own user gets a block in
  `~/.ssh/config.local`, on the machine, and its `User` wins over `Host *`
  only because it is read before it. `IdentityFile` is the exception — it
  accumulates rather than overrides — so a host block's own key is tried first
  and the shared one is still offered after it. Nothing in `config.local` can
  remove it, because `Host *` matches every host; a host that must never see
  the shared key needs the versioned pattern to exclude it (`Host * !name`).
- **`launchd/com.piedrac.ssh-add-keychain.plist` refills the agent at login.**
  The two options above act only when `ssh` runs, and here it never does: git
  talks to GitHub over HTTPS, and signing goes through `ssh-keygen -Y sign`,
  which reads no `ssh_config` and asks only the agent. After a reboot the agent
  is empty, and without this the first commit of the day would fail until
  something loaded the key. The agent runs `ssh-add --apple-load-keychain` once
  per login, which reads the passphrase from the Keychain; `install.sh` links
  it into `~/Library/LaunchAgents/`, bootstraps it once, and kickstarts it so
  the current session gets the key without a reboot. It is a launchd agent and
  not a line in a shell profile because a profile runs per shell and only for
  shells. `check.sh` lints the plist and holds its `Label` to its filename,
  the mismatch that makes an agent silently never load.

`install.sh` does the rest, once, and does nothing the second time. It
generates `~/.ssh/id_ed25519` if there is none — the passphrase is the first
of the three things this step can ask of you: `ssh-keygen` asks it to set it,
and `ssh-add --apple-use-keychain` asks it once more to store it in the
Keychain, which is the step `ssh-keygen` does not do and `ssh` would only do
on a connection that never happens. It logs `gh` in if nothing has yet, asking
for the key scopes at the same time — the browser round trip, the second thing
it can ask. It registers the public key with GitHub as both an authentication
key and a signing key, because GitHub keeps those in two lists and a key in one
is not in the other, and writes `user.signingkey`, the two `gpgsign` switches
and `allowed_signers`.
Before it can register anything it checks that `gh` holds the two scopes that
manage keys, `admin:public_key` and `admin:ssh_signing_key`, and refreshes the
login in the browser if not, which is the third thing it can ask of you, and
only the first time: a token from an earlier `gh auth login` does not carry
them, and without them `gh ssh-key list` reports a 404 on stderr and nothing
on stdout, so the key looks unregistered right before `add` fails — which is
why the scope check comes before the listing.

Because the switch is not in the versioned file, the repo no longer says
"commits are signed" on its face; this section and `drift.sh` say it instead.
`drift.sh` reports a machine where `commit.gpgsign` is not `true`, and closes
the loop from the other side: it asks GitHub whether the key `user.signingkey`
names is still registered for signing. A key GitHub has
forgotten — revoked, or the machine re-enrolled under a new title — signs every
commit with a signature the web UI marks Unverified, and nothing on the machine
notices on its own.

### A second identity, scoped to a directory

A client's GitHub account — its own email, its own key — is one file on the
machine, `~/.config/git/identities/<name>.gitconfig`, never versioned because
it names the client. It declares the directory it owns and everything git
should use there:

```ini
[identity]
	gitdir = ~/Development/<client>/
[user]
	email = me@client.example
	signingkey = ~/.ssh/id_ed25519_<client>.pub
[core]
	sshCommand = ssh -o IdentityAgent=none -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519_<client>
```

`install.sh` turns each file into an `includeIf "gitdir:…"` in `config.local`
and a line in `allowed_signers`, and a second run changes nothing; `check.sh`
proves git answers with the scoped email inside the directory and the default
one outside it. Repositories under that directory use SSH remotes, so the
`sshCommand` is what picks the account, with no `gh auth switch` whose
forgetting would push this repository as the client.

`IdentityAgent=none` is load-bearing. Observed on 2026-09-29: with the agent
holding both keys, `ssh -i <client key> -o IdentitiesOnly=yes` still
authenticated as the default account, because the agent's key was offered
first and GitHub accepted it. Without the agent, the `-i` key is tried first
and `UseKeychain` still supplies its passphrase; signing is unaffected, since
it goes through the agent, which the login agent fills with every key the
Keychain knows.

What `install.sh` does not do for a scoped identity: generate its key or
register it with GitHub, because `gh` is logged into the default account.
Both are by hand — `ssh-keygen`, `ssh-add --apple-use-keychain`, then the key
added to the client account as both an authentication and a signing key — and
`drift.sh` checks only the default key's registration, not these.
