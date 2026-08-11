#!/usr/bin/env bash
# Moves the tool pins in .github/workflows/ci.yml to their latest releases and
# records the new checksums in .github/tool-checksums.txt.
#
# Usage:  ./bump-tools.sh
#
# Dependabot renews the pinned action SHA and nothing else. There is no
# ecosystem for "a version in a workflow env var plus a hash in a text file",
# and Renovate's regex managers can move the version but not regenerate the
# hash, which needs postUpgradeTasks and therefore a self-hosted instance. This
# script is the thing that renews those four pins, and the scheduled workflow
# in tool-updates.yml is what remembers to run it.
#
# It never merges anything by itself. The hashes it writes are whatever
# upstream is publishing right now, which is precisely what tool-checksums.txt
# says not to trust blindly, so a human reads the diff before this reaches CI.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

WORKFLOW=.github/workflows/ci.yml
CHECKSUMS=.github/tool-checksums.txt
TOOLS="shellcheck shfmt actionlint ghostty"

BOLD=$'\033[1m'
GREEN=$'\033[32m'
DIM=$'\033[90m'
OFF=$'\033[0m'

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# The env var each tool's version lives in, and whether ci.yml spells it with a
# leading v. Both spellings appear in that file and each tool has its own habit,
# so this is carried per tool rather than guessed.
var_of() {
  case "$1" in
    shellcheck) echo SHELLCHECK_VERSION ;;
    shfmt) echo SHFMT_VERSION ;;
    actionlint) echo ACTIONLINT_VERSION ;;
    ghostty) echo GHOSTTY_VERSION ;;
  esac
}

# How ci.yml writes the version, given a bare one.
spelled() {
  case "$1" in
    shellcheck | shfmt) echo "v$2" ;;
    *) echo "$2" ;;
  esac
}

# Latest upstream version, bare. Ghostty publishes no GitHub release for stable
# builds — only a rolling "tip" — so its tags are the source, filtered to
# release-shaped ones and ordered by version rather than by when they were cut.
latest_of() {
  case "$1" in
    shellcheck) gh api repos/koalaman/shellcheck/releases/latest --jq .tag_name | sed 's/^v//' ;;
    shfmt) gh api repos/mvdan/sh/releases/latest --jq .tag_name | sed 's/^v//' ;;
    actionlint) gh api repos/rhysd/actionlint/releases/latest --jq .tag_name | sed 's/^v//' ;;
    ghostty)
      gh api "repos/ghostty-org/ghostty/tags?per_page=100" --jq '.[].name' |
        grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1 | sed 's/^v//'
      ;;
  esac
}

# The artifact CI downloads, and the name it looks up in tool-checksums.txt.
# These mirror ci.yml. Drifting from it is not silent: verify() there refuses to
# install a file it has no line for, so a name that stops matching fails the
# build rather than quietly skipping a check.
url_of() {
  case "$1" in
    shellcheck) echo "https://github.com/koalaman/shellcheck/releases/download/v$2/shellcheck-v$2.darwin.aarch64.tar.xz" ;;
    shfmt) echo "https://github.com/mvdan/sh/releases/download/v$2/shfmt_v${2}_darwin_arm64" ;;
    actionlint) echo "https://github.com/rhysd/actionlint/releases/download/v$2/actionlint_${2}_darwin_arm64.tar.gz" ;;
    ghostty) echo "https://release.files.ghostty.org/$2/ghostty-macos-universal.zip" ;;
  esac
}

name_of() {
  case "$1" in
    shellcheck) echo "shellcheck-v$2.darwin.aarch64.tar.xz" ;;
    shfmt) echo "shfmt_v${2}_darwin_arm64" ;;
    actionlint) echo "actionlint_${2}_darwin_arm64.tar.gz" ;;
    ghostty) echo "ghostty-$2-macos-universal.zip" ;;
  esac
}

pinned_of() {
  awk -v k="$(var_of "$1"):" '$1 == k { sub(/^v/, "", $2); print $2; exit }' "$WORKFLOW"
}

changed=0
for tool in $TOOLS; do
  have=$(pinned_of "$tool")
  [ -n "$have" ] || {
    echo "$tool: no $(var_of "$tool") in $WORKFLOW" >&2
    exit 1
  }

  want=$(latest_of "$tool")
  [ -n "$want" ] || {
    echo "$tool: could not resolve the latest version" >&2
    exit 1
  }

  if [ "$want" = "$have" ]; then
    printf '  %s%s%s %s is current\n' "$DIM" "$tool" "$OFF" "$have"
    continue
  fi

  # An upstream API that answers oddly, or a tag that is a backport of an older
  # line, must not walk the pin backwards. Refuse rather than "update" into a
  # version with known fixes missing.
  if [ "$(printf '%s\n%s\n' "$have" "$want" | sort -V | tail -1)" != "$want" ]; then
    echo "$tool: latest is $want but $have is pinned; refusing to downgrade" >&2
    exit 1
  fi

  url=$(url_of "$tool" "$want")
  file="$tmp/$(name_of "$tool" "$want")"
  # A published tag does not guarantee a published artifact: Ghostty's tags
  # appear before its CDN uploads. Fail here rather than write a pin CI cannot
  # install.
  curl -fsSL "$url" -o "$file" || {
    echo "$tool: $want is tagged but $url is not downloadable yet" >&2
    exit 1
  }
  hash=$(shasum -a 256 "$file" | cut -d' ' -f1)

  # A substitution that matches nothing is not a no-op here, it is a pin moved
  # with no checksum to go with it. That does surface — verify() in ci.yml
  # refuses a file it has no line for — but as a failure in the pull request
  # rather than in the thing that caused it. Insist on the match instead.
  old_name=$(name_of "$tool" "$have")
  awk -v old="$old_name" -v line="$hash  $(name_of "$tool" "$want")" \
    '$2 == old { print line; found = 1; next } { print } END { exit !found }' \
    "$CHECKSUMS" > "$tmp/checksums" || {
    echo "$tool: $CHECKSUMS has no line for $old_name, so the pin and the hashes disagree already" >&2
    exit 1
  }

  # Both rewrites are staged and only then moved into place, so failing partway
  # cannot leave a bumped pin behind with a stale hash beside it.
  sed "s|^\([[:space:]]*$(var_of "$tool"):[[:space:]]*\).*|\1$(spelled "$tool" "$want")|" \
    "$WORKFLOW" > "$tmp/workflow"
  mv "$tmp/checksums" "$CHECKSUMS"
  mv "$tmp/workflow" "$WORKFLOW"

  printf '  %s%s%s %s -> %s%s%s\n' "$BOLD" "$tool" "$OFF" "$have" "$GREEN" "$want" "$OFF"
  changed=1
done

if [ "$changed" -eq 0 ]; then
  printf '\nEverything is on its latest release.\n\n'
  exit 0
fi

printf '\nRun ./check.sh before committing: it will disagree until the tools on\n'
printf 'this machine are upgraded to match the new pins.\n\n'
