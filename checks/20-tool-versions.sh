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

# bump-tools.sh against a scratch copy of the two files it rewrites: a symlink
# to the real script (it cds to its own directory, and dirname of the link is
# the scratch one), synthetic pins so the check does not change meaning with
# every bump, and stubs for the network. The gh stub answers from $LATEST, one
# "api-path answer" line per tool; the curl stub writes "artifact:<url>" to
# its -o file, or fails like a 404 for a URL listed in $MISSING. The real
# shasum hashes that, so the expected hash is computed the way the script's is.
bump_tools() {
  local tmp dir out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/gh" << 'STUB'
#!/usr/bin/env bash
awk -v p="$2" '$1 == p { print $2 }' "$LATEST"
STUB
  cat > "$tmp/bin/curl" << 'STUB'
#!/usr/bin/env bash
url='' file=''
while [ $# -gt 0 ]; do
  case "$1" in
    -o) file=$2; shift ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
grep -qxF "$url" "$MISSING" && exit 22
printf 'artifact:%s' "$url" > "$file"
STUB
  chmod +x "$tmp/bin/gh" "$tmp/bin/curl"

  # The pins and checksum lines as ci.yml and tool-checksums.txt hold them.
  # taplo's and zizmor's artifact names carry no version, as upstream's do not.
  fixture() {
    dir="$tmp/$1"
    mkdir -p "$dir/.github/workflows"
    ln -s "$PWD/bump-tools.sh" "$dir/bump-tools.sh"
    cat > "$dir/.github/workflows/ci.yml" << 'YML'
env:
  SHELLCHECK_VERSION: v0.10.0
  SHFMT_VERSION: v3.13.0
  ACTIONLINT_VERSION: 1.7.0
  GHOSTTY_VERSION: 1.3.0
  TAPLO_VERSION: 0.9.0
  ZIZMOR_VERSION: 1.30.0
  GITLEAKS_VERSION: 8.30.0
YML
    cat > "$dir/.github/tool-checksums.txt" << 'SUMS'
# fixture
aaaa  shellcheck-v0.10.0.darwin.aarch64.tar.xz
bbbb  shfmt_v3.13.0_darwin_arm64
cccc  actionlint_1.7.0_darwin_arm64.tar.gz
dddd  ghostty-1.3.0-macos-universal.zip
eeee  taplo-darwin-aarch64.gz
ffff  zizmor-aarch64-apple-darwin.tar.gz
9999  gitleaks_8.30.0_darwin_arm64.tar.gz
SUMS
    cp "$dir/.github/workflows/ci.yml" "$dir/ci.before"
    cp "$dir/.github/tool-checksums.txt" "$dir/sums.before"
    : > "$dir/missing"
    # Every tool current unless a case says otherwise. Ghostty's answer is
    # its tag list, which the script filters to release-shaped tags.
    cat > "$dir/latest" << 'LATEST'
repos/koalaman/shellcheck/releases/latest v0.10.0
repos/mvdan/sh/releases/latest v3.13.0
repos/rhysd/actionlint/releases/latest v1.7.0
repos/ghostty-org/ghostty/tags?per_page=100 tip
repos/ghostty-org/ghostty/tags?per_page=100 v1.2.9
repos/ghostty-org/ghostty/tags?per_page=100 v1.3.0
repos/tamasfe/taplo/releases/latest 0.9.0
repos/zizmorcore/zizmor/releases/latest v1.30.0
repos/gitleaks/gitleaks/releases/latest v8.30.0
LATEST
  }
  latest() { sed -i '' "s|^\\($1\\) .*|\\1 $2|" "$dir/latest"; }
  run() { (cd "$dir" && LATEST="$dir/latest" MISSING="$dir/missing" PATH="$tmp/bin:$PATH" ./bump-tools.sh 2>&1); }
  untouched() {
    cmp -s "$dir/ci.before" "$dir/.github/workflows/ci.yml" &&
      cmp -s "$dir/sums.before" "$dir/.github/tool-checksums.txt"
  }
  sum_of() { printf 'artifact:%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
  # The files as they should read once the named moves are made, built from
  # the originals line by line: "VAR spelled-version old-name new-line".
  expect() {
    cp "$dir/ci.before" "$dir/ci.want"
    cp "$dir/sums.before" "$dir/sums.want"
    while [ $# -gt 0 ]; do
      sed -i '' "s|^\\(  $1: \\).*|\\1$2|" "$dir/ci.want"
      sed -i '' "s|^[^ ]*  $3\$|$4|" "$dir/sums.want"
      shift 4
    done
  }
  as_expected() {
    cmp -s "$dir/ci.want" "$dir/.github/workflows/ci.yml" &&
      cmp -s "$dir/sums.want" "$dir/.github/tool-checksums.txt"
  }

  local sc_url taplo_url
  sc_url=https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.xz
  taplo_url=https://github.com/tamasfe/taplo/releases/download/0.10.0/taplo-darwin-aarch64.gz

  fixture moved
  latest repos/koalaman/shellcheck/releases/latest v0.11.0
  latest repos/tamasfe/taplo/releases/latest 0.10.0
  out=$(run) || {
    echo "move: refused two newer, downloadable releases: $out"
    return 1
  }
  expect SHELLCHECK_VERSION v0.11.0 shellcheck-v0.10.0.darwin.aarch64.tar.xz \
    "$(sum_of "$sc_url")  shellcheck-v0.11.0.darwin.aarch64.tar.xz" \
    TAPLO_VERSION 0.10.0 taplo-darwin-aarch64.gz "$(sum_of "$taplo_url")  taplo-darwin-aarch64.gz"
  as_expected || {
    echo "move: the files differ from each pin and checksum moved together, spelling kept, nothing else changed:"
    diff "$dir/ci.want" "$dir/.github/workflows/ci.yml"
    diff "$dir/sums.want" "$dir/.github/tool-checksums.txt"
    return 1
  }

  fixture current
  out=$(run) || {
    echo "current: failed with every tool current: $out"
    return 1
  }
  untouched || {
    echo "current: changed the files with every tool current"
    return 1
  }
  case "$out" in *"Everything is on its latest release"*) ;; *)
    echo "current: did not say every tool is current: $out"
    return 1
    ;;
  esac

  fixture downgrade
  latest repos/gitleaks/gitleaks/releases/latest v8.29.0
  if out=$(run) || ! untouched; then
    echo "downgrade: did not refuse, untouched, a latest older than the pin: $out"
    return 1
  fi

  fixture undownloadable
  latest repos/rhysd/actionlint/releases/latest v1.7.1
  echo https://github.com/rhysd/actionlint/releases/download/v1.7.1/actionlint_1.7.1_darwin_arm64.tar.gz > "$dir/missing"
  if out=$(run) || ! untouched; then
    echo "undownloadable: did not refuse, untouched, a release whose artifact 404s: $out"
    return 1
  fi

  fixture no-checksum-line
  sed -i '' '/zizmor-aarch64-apple-darwin/d' "$dir/.github/tool-checksums.txt"
  cp "$dir/.github/tool-checksums.txt" "$dir/sums.before"
  latest repos/zizmorcore/zizmor/releases/latest v1.31.0
  if out=$(run) || ! untouched; then
    echo "no checksum line: did not refuse, untouched, a pin with no checksum line to replace: $out"
    return 1
  fi

  # The script moves shellcheck before it reaches shfmt.
  fixture partial
  latest repos/koalaman/shellcheck/releases/latest v0.11.0
  latest repos/mvdan/sh/releases/latest v3.14.0
  echo https://github.com/mvdan/sh/releases/download/v3.14.0/shfmt_v3.14.0_darwin_arm64 > "$dir/missing"
  if out=$(run); then
    echo "partial: succeeded although shfmt's artifact 404s"
    return 1
  fi
  expect SHELLCHECK_VERSION v0.11.0 shellcheck-v0.10.0.darwin.aarch64.tar.xz \
    "$(sum_of "$sc_url")  shellcheck-v0.11.0.darwin.aarch64.tar.xz"
  as_expected || {
    echo "partial: a failure on shfmt left shellcheck's pin and checksum disagreeing, or touched shfmt:"
    diff "$dir/ci.want" "$dir/.github/workflows/ci.yml"
    diff "$dir/sums.want" "$dir/.github/tool-checksums.txt"
    return 1
  }
}
check "bump-tools.sh moves each pin with its checksum, and refuses a downgrade, a 404 or a missing line untouched" bump_tools
