# shellcheck shell=bash
# shellcheck disable=SC2329,SC2317
# Sourced by check.sh, never run on its own: it uses check, skip, STRICT and the
# other helpers defined there. The disable is the one check.sh carries: these functions
# are only ever called through `check`.

# ── Tool versions ────────────────────────────────────────────────────────────
# CI pins these seven and verifies them by checksum; the Brewfile installs
# whatever is current. "CI and your machine run the same binaries" is therefore
# a claim nothing was enforcing, true only as long as nobody upgraded. Ghostty
# does not even need that: it is a cask that updates itself, and its own config
# here sets auto-update.
#
# Nothing renews the pins either — Dependabot covers the pinned action SHA and
# has no ecosystem for a version in an env var — so the least this can do is
# make the gap loud on the machine where it first appears, instead of leaving
# it to be discovered as a CI failure nobody can explain months later.
printf '\n%sTool versions%s\n' "$DIM" "$OFF"

# Version as written in ci.yml, with any leading v removed; the file spells it
# both ways.
pinned() { awk -v k="$1:" '$1 == k { sub(/^v/, "", $2); print $2; exit }' .github/workflows/ci.yml; }

# Each tool reports its version its own way, and shfmt reports it differently
# depending on where it came from: brew builds say 3.13.1, the release binary
# CI downloads says v3.13.1.
installed() {
  case "$1" in
    shellcheck) shellcheck --version | awk '/^version:/ { print $2 }' ;;
    shfmt) shfmt --version | sed 's/^v//' ;;
    actionlint) actionlint --version | head -1 ;;
    ghostty) ghostty +version | awk 'NR == 1 { print $2 }' ;;
    taplo) taplo --version | awk '{ print $2 }' ;;
    zizmor) zizmor --version | awk '{ print $2 }' ;;
    gitleaks) gitleaks version ;;
  esac
}

versions_match() {
  local status=0 tool var want have
  for pair in shellcheck:SHELLCHECK_VERSION shfmt:SHFMT_VERSION \
    actionlint:ACTIONLINT_VERSION ghostty:GHOSTTY_VERSION taplo:TAPLO_VERSION \
    zizmor:ZIZMOR_VERSION gitleaks:GITLEAKS_VERSION; do
    tool=${pair%%:*}
    var=${pair##*:}
    # A missing tool is already reported by its own check above; repeating it
    # here would just be noise.
    command -v "$tool" > /dev/null 2>&1 || continue
    want=$(pinned "$var")
    have=$(installed "$tool")
    if [ -z "$want" ]; then
      echo "$tool: no $var pinned in ci.yml"
      status=1
    elif [ "$want" != "$have" ]; then
      echo "$tool: installed $have, ci.yml pins $want"
      status=1
    fi
  done
  return "$status"
}
check "installed tools match the ci.yml pins" versions_match
