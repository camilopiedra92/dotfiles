# macOS

## macOS defaults

```bash
macos/defaults.sh apply|check
```

One parser reads `macos/defaults.txt` for both verbs. `install.sh` calls
`apply`, `drift.sh` calls `check`, and if each had its own copy of the parsing
the two would eventually disagree about what a line means the first time one
of them was edited without the other.

Two other shapes were considered and rejected. The one every `macos.sh`
template on the internet uses — a script of bare `defaults write` lines — was
rejected because it cannot be verified: nothing can read it back without
parsing shell, which is exactly the job `check` has to do. `defaults import`
of a plist per domain was the other candidate, rejected because it replaces
the whole domain, taking with it every key the owning app wrote for itself —
Finder's window positions and VS Code's own settings alongside the handful of
keys this repo actually wants to declare.

The manifest keeps to **only non-defaults**: only values that differ from
Apple's own. Same argument as `node = "lts"` rather than a number — a default
written down is frozen, and the day Apple ships a better one this file would
put the old one back, with nobody knowing why.

Deliberately absent, and why:

- **Any key a Jamf profile sets on the work Mac** — screen lock, updates,
  firewall, FileVault, Siri. The rule is per key, not per domain: a profile
  can manage two keys of a domain and leave the rest alone, and it does —
  `com.apple.controlcenter` is managed for its Bluetooth and Wi-Fi menu items
  while `BatteryShowPercentage`, declared here in the same domain, is not.
  `ls "/Library/Managed Preferences/$USER"` lists the managed domains and
  `plutil -p` on one of them lists the keys. A managed key written here would
  be silently overruled while reading as if it applied: `defaults` reads and
  writes only the user layer, and the managed one sits above it, invisible to
  `defaults read` and consulted first by the app.
- **`sudo`.** Nothing this manifest touches needs it. The one setting that
  does is in `macos/power.sh`, below, and not here, so that stays true.
- **Killing `cfprefsd`.** `defaults` already goes through it; killing it is
  the folk remedy that produces the stale-preferences bug it is supposed to
  cure.
- **`LSQuarantine`.** Turning it off system-wide silences the "downloaded from
  the internet, are you sure?" prompt for every app forever — a security
  trade this repo does not make on your behalf.
- **Press-and-hold, globally.** The keyboard layout here is ABC and Spanish
  accents are typed through press-and-hold; turning it off everywhere to fix
  key repeat would break accents to get there. It is turned off per app
  instead, for VS Code and Ghostty, where holding a key is meant to repeat it
  — see the manifest.

`~/Library` is unhidden on every `apply` (`chflags nohidden ~/Library`) but
has no line in the manifest: it is a Finder flag, not a `defaults` key, so the
parser has no field that could hold it. It runs unconditionally and is a
no-op once done. The screenshot folder a Mac declares — CleanShot's
`exportPath` on the personal one, `com.apple.screencapture location` on the
work one — is created the same way, from the parsed line, so only where a
manifest names one.

A domain written `host:NSGlobalDomain` instead of `NSGlobalDomain` is read
and written through `defaults -currentHost`, which reaches
`~/Library/Preferences/ByHost/.GlobalPreferences.<uuid>.plist` instead of the
domain's usual plist — macOS keeps some preferences, trackpad and mouse among
them, per host rather than per user. The manifest's trackpad keys told only
part of the story for a while: every `macos.sh` template on the internet
writes `com.apple.AppleMultitouchTrackpad` and
`com.apple.driver.AppleBluetoothMultitouch.trackpad`, `check` reported those
as applied, and tap-to-click still did not work. Toggling the setting in
System Settings and diffing every plist under `~/Library/Preferences` —
`ByHost/` included, not only the domain a template writes — showed System
Settings writes to more than one place, so read-back on a single domain
could not say by itself which one the driver actually consults. A
behavioural test settled it: with the template domains' `Clicking` keys
forced to 0 and the per-host key left at 1, tapping still clicked and
System Settings still showed tap-to-click on — the driver reads the
per-host key, and the template keys were dead. See the Trackpad section of
the manifest.

## Power

```bash
macos/power.sh apply|check
```

The settings `pmset` owns, which `defaults` cannot reach. Same two verbs and
the same callers as the manifest above, and the same rule about content: only
values that differ from Apple's own, each with its reason in the script. One
is declared for runtime — Energy Mode on battery set to Low Power,
`powermode 1` under the battery profile, with plugged-in left at Automatic.
It is the one software lever left with a runtime gain worth a line; the rest
of what `pmset -g custom` prints on this machine is what Apple ships, and
the charge limit that holds the battery at 80% is already on. The other is a
security baseline: Wake for network access off (`womp 0`) in both profiles,
which CIS lists at Level 1 (2.10.3 in the Tahoe benchmark, as quoted by
Tenable's audit; the CIS PDF was not read). Its cost, from the same audit:
Find My cannot locate, lock or erase the Mac while it sleeps. Power Nap is
left alone: CIS's Tahoe control for it is titled "for Intel Macs".

A separate script rather than a `pmset:` prefix in `defaults.txt`, because
writing through `pmset` needs root and the manifest promises nothing in it
does; keeping them apart keeps that promise true by construction. Toggling
Energy Mode in System Settings was the other candidate and lost the way
everything unwritten loses here: it does not survive a rebuild and nothing
reports when it changes. `check` reads `pmset -g custom`, which needs no
privilege, so `drift.sh` never prompts; `apply` goes through `sudo` only for
a value that differs, so `install.sh` asks for a password here at most once
and a second run asks for nothing. A `pmset -g custom` with no battery
profile at all is a broken checker (exit 2), not a match.

`powermode` is not in `man pmset` on macOS 26.6.2. It is what `pmset -g
custom` prints and what System Settings → Battery → Energy Mode writes
(`LowPowerMode` in `/Library/Preferences/com.apple.PowerManagement.<uuid>.plist`,
per profile). Applied on this machine on 2026-09-15 and verified by
read-back three ways the same day: `pmset -g custom` printed `powermode 1`
under Battery Power, the plist's `LowPowerMode` read 1 under Battery Power
and 0 under AC Power, and `system_profiler SPPowerDataType` reported Low
Power Mode Yes for Battery Power and No for AC Power. A second `apply` was
silent and asked for no password. Not checked: the System Settings pane
itself, and the runtime gain — that one is a number only a full discharge
gives.

## Touch ID for sudo

```bash
macos/touchid.sh apply|check
```

Touch ID instead of the password for `sudo`, on every Mac, through
`/etc/pam.d/sudo_local` — the file Apple provides for it, which
`/etc/pam.d/sudo` includes first and a system update leaves alone. Apple
ships `sudo_local.template` with the one line commented out; `apply` writes
that template with the line uncommented, or adds the line to a
`sudo_local` that already exists and keeps the rest. Editing
`/etc/pam.d/sudo` was the other way and lost: an update rewrites it.

Same contract as `power.sh`: `check` only reads, so `drift.sh` never
prompts; `apply` goes through `sudo` once, only while the line is missing.
No `sudo_local` and no template is a broken checker (exit 2), not a file to
invent. Inside tmux, `sudo` still asks for the password: according to
`pam_reattach`'s documentation, Touch ID needs the GUI session a tmux server
is not attached to (not tested here; `pam_reattach` is not installed).

Verified on the personal Mac on 2026-10-03: `apply`, run from a terminal,
asked for the password once and wrote Apple's template with the line
uncommented (root:wheel, 644); `check` then exited 0; and `sudo -k && sudo
true` completed without a password prompt. Run from Claude Code's `!`
prompt, which has no terminal, `apply` failed at `sudo` and wrote nothing.

## Application firewall

```bash
macos/firewall.sh apply|check
```

The firewall on and in stealth mode, on every Mac: `globalstate` and
`stealthmode`, read and written through `socketfilterfw`. Stealth mode is
meant to make the Mac ignore pings and probes to closed ports instead of
answering them (Apple's description; not tested here). CIS is said to list it
as a Level 1 control and to warn it can be unwanted on a trusted LAN, from
memory: the CIS PDF was not read. "Block all incoming connections" is not
supported: its output was not observed, so it reads as a broken checker. The
settings live in the root-owned
`/Library/Preferences/com.apple.alf.plist`, which is why they are not in
`defaults.txt`.

Same contract as `power.sh`: `check` only reads, so `drift.sh` never prompts;
`apply` goes through `sudo` once per setting that differs. Output
`socketfilterfw` prints that the script does not recognise is a broken
checker (exit 2), not a difference. Not tested: a Mac whose firewall a
configuration profile manages.

Verified on the personal Mac on 2026-10-10: stealth mode was set by hand with
`sudo socketfilterfw --setstealthmode on` and read back as `Firewall stealth
mode is on`; `macos/firewall.sh check` then exited 0. `apply` itself has run
only against the stub in `checks/`, not against the real tool.

## Dock and file handlers

```bash
macos/dock.sh apply|check
macos/handlers.sh apply|check
```

Same two verbs and callers as the two above. A machine's `dock.txt` lists
its Dock's apps left to right; `macos/handlers.txt` maps a file extension to
the app that opens it, only where that differs from Apple's choice, and a
machine's own `handlers.txt` adds the extensions only it has an app for.

Neither fits in `defaults.txt`. The Dock's app list is one ordered array of
dictionaries carrying per-machine file references, and the handlers belong
to Launch Services, whose plist is an array keyed by UTI. Saving either plist
as-is was the other candidate and lost the way `defaults import` did above:
opaque in a diff, and carrying one machine's references to the next.
`dockutil` and `duti` write them through the supported path, and the
manifests stay the part a person decides.

The Dock is rebuilt rather than patched: when it differs, every app is
removed and the declared ones added back in order, then the Dock restarts
once. Only the app section is managed; folders and stacks right of the
divider are neither touched nor compared. A spacer tile in the app section
is drift, since the manifest cannot declare one, and `apply` removes it —
with `dockutil --remove spacer-tiles`, which takes spacers in the folder
section too. Paths are compared with symlinks resolved and Unicode
composed: Safari's `/Applications` path is a symlink into the system
cryptex, which is what the Dock stores (observed); an accented name may
come back decomposed while the manifest is typed composed (guarded against,
not observed — no app in this Dock has one). Every handler line sets the role
`all`, which includes `shell` — for a script, that is what makes a
double-click open it in the editor instead of running it, and why `.sh`
and `.js` moved from Ghostty and Chrome to VS Code on 2026-10-03. The
browser and mail handlers are left out: Apple documents that changing the
default browser asks the user to confirm, so `apply` could not do it
unattended (not tested here). `check` compares the app `duti -x` reports as
the default, the one a double-click opens; it does not read each role
apart.

Without `dockutil` or `duti`, or with `dockutil --list` failing, both
scripts exit 2 — a broken checker for `drift.sh`, not an empty Dock or a
machine with no handlers.

An app a manifest names but that is not installed — on a fresh machine,
anything the Brewfile does not install — is skipped by `apply` with a line on stderr, so `install.sh`
does not stop halfway, and reported by `check` until it is installed or
removed from the manifest.

Verified on the personal Mac on 2026-10-03. Dock: `check` exited 0 against the
Dock as it stood; with Claude moved to the first slot by hand, `check`
reported the order, `apply` put it back, `check` exited 0 and a second
`apply` printed nothing. Handlers: `apply` set `js` and `sh` to VS Code, and
`duti -x` read the new handler back about three seconds later — Launch
Services takes the change asynchronously, so a `check` run immediately
after `apply` still reports the old one. After that, `check` exited 0 and a
second `apply` printed nothing. Not checked: double-clicking a file in
Finder.

## More than one Mac

```bash
macos/machine.sh dir | set <name>
```

The same repo runs on a personal Mac and a work Mac, which share most
settings and differ in a few: the Dock's apps, an app one of them does not
have. What every Mac gets stays where it was — `macos/defaults.txt`,
`macos/handlers.txt`. What only one gets lives under
`macos/machines/<profile>/`: `dock.txt`, which is only ever per machine;
`mcp.json`, the MCP servers only that Mac has — YNAB on the personal one,
`aware` and Glean on the work one — added on top of `claude/mcp.json`; `Brewfile`, the
packages only that Mac wants, installed by `install.sh` step 8a after the shared
one (a profile without one installs nothing there); and
`defaults.txt` and `handlers.txt`, read after the shared file of the same
name. A key or an extension is in the shared file or a machine's, never
both, which `check.sh` enforces: in both, it would be written twice and the
last write would win by the order of a loop rather than by anything written
down.

Which profile a Mac is comes from `~/.config/dotfiles/machine`, one word,
outside the repo. `install.sh` asks for it once, at a terminal, and stops
with the reason anywhere else rather than wait on a prompt nobody will
answer. Without it, or with a name that has no directory, `machine.sh dir`
exits 2 and so does every script that asks it: guessing would apply one
Mac's Dock to the other. A profile with no `dock.txt` is a Dock nobody has
declared yet — `check` says so, `apply` leaves it alone.

The hostname was the other candidate and lost because two Macs can share
one and a rename changes it without anything saying so; the hardware serial
lost because it would put an identifier in a public repo and need an edit
the day the Mac is replaced.

Verified on 2026-10-03 on the personal Mac: with no machine file `dir`
exited 2 and named the file and both profiles; after `set personal`, the
Dock, handlers and defaults checks read the personal manifests and matched.
The work profile was checked from the personal Mac by pointing
`MACHINE_FILE` at a file saying `work`: the Dock reported "not declared",
the handlers matched on the shared lines alone, and no CleanShot line was
read. Not tested on the work Mac itself.
