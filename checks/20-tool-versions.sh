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
    uv) uv --version | awk '{ print $2 }' ;;
  esac
}

versions_match() {
  local status=0 tool var want have
  for pair in shellcheck:SHELLCHECK_VERSION shfmt:SHFMT_VERSION \
    actionlint:ACTIONLINT_VERSION ghostty:GHOSTTY_VERSION taplo:TAPLO_VERSION \
    zizmor:ZIZMOR_VERSION gitleaks:GITLEAKS_VERSION uv:UV_VERSION; do
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

# bump-tools.sh against a scratch copy of itself and of the two files it
# rewrites, under a PATH of stubs for the network and links to the utilities it
# uses, and nothing else, so a version that fetched with another tool fails
# rather than reaching the network. A copy rather than a symlink: the script cds
# to its own directory, and a later version that resolved its link there would
# find this repository's real pins. The pins are synthetic so the check does not
# change meaning with every bump. The gh stub answers from $LATEST, one
# "api-path answer" line per tool. The curl stub answers as GitHub's release
# downloads do: every URL redirects, so without -L the -o file gets the
# redirect's body; a URL listed in $MISSING is a 404, which fails only under -f
# and otherwise saves the error page. A real download writes "artifact:<url>".
# The real shasum hashes that, so the expected hash is computed the way the
# script's is. The expected URLs and artifact names are written out here rather
# than derived, so every entry of the script's per-tool tables is checked.
bump_tools() {
  local tmp dir out
  tmp=$(mktemp -d) || return 1
  trap 'rm -rf "$tmp"' RETURN
  mkdir -p "$tmp/bin"
  # gh answers only the exact call the script must make: `api PATH --jq
  # FILTER`, with .tag_name for a release and .[].name for a tag list.
  cat > "$tmp/bin/gh" << 'STUB'
#!/usr/bin/env bash
case "$2" in
  *'/tags?'*) want='.[].name' ;;
  *) want=.tag_name ;;
esac
[ "$1 $3 $4 $#" = "api --jq $want 4" ] || exit 93
awk -v p="$2" '$1 == p { print $2 }' "$LATEST"
STUB
  cat > "$tmp/bin/curl" << 'STUB'
#!/usr/bin/env bash
url='' file='' fail=0 follow=0
while [ $# -gt 0 ]; do
  case "$1" in
    -o) file=$2; shift ;;
    --*) ;;
    -*)
      case "$1" in *f*) fail=1 ;; esac
      case "$1" in *L*) follow=1 ;; esac
      ;;
    *) url=$1 ;;
  esac
  shift
done
if [ "$follow" -eq 0 ]; then
  printf 'redirect:%s' "$url" > "$file"
elif grep -qxF "$url" "$MISSING"; then
  [ "$fail" -eq 1 ] && exit 22
  printf '404:%s' "$url" > "$file"
else
  printf 'artifact:%s' "$url" > "$file"
fi
STUB
  chmod +x "$tmp/bin/gh" "$tmp/bin/curl"
  local tool real
  for tool in awk bash cut dirname grep mv rm sed shasum sort tail; do
    real=$(command -v "$tool") || return 1
    ln -s "$real" "$tmp/bin/$tool"
  done
  # The script stages its downloads in `mktemp -d`, which on macOS ignores
  # TMPDIR (seen 2026-10-12: TMPDIR=<dir> mktemp -d still answered under
  # /var/folders/.../T). This one makes the directory inside the fixture, so
  # whatever the script leaves behind stays in the scratch directory and shows.
  real=$(command -v mktemp) || return 1
  cat > "$tmp/bin/mktemp" << STUB
#!/usr/bin/env bash
[ "\$*" = -d ] || exit 94
exec "$real" -d "\$STAGE/tmp.XXXXXX"
STUB
  chmod +x "$tmp/bin/mktemp"

  # sed -i takes its suffix differently in BSD and GNU sed; this needs neither.
  edit() { sed "$2" "$1" > "$1.new" && mv "$1.new" "$1"; }

  # The steps use each variable without being its pin, as ci.yml's do, so a
  # rewrite that reached every line naming the variable would show.
  # Ghostty's answer is its tag list, which the script filters to
  # release-shaped tags and orders by version: 1.10.0 sorts before 1.9.0 as
  # text, and the release candidate after its release under sort -V.
  fixture() {
    dir="$tmp/$1"
    mkdir -p "$dir/.github/workflows"
    cp bump-tools.sh "$dir/"
    cat > "$dir/.github/workflows/ci.yml" << 'YML'
env:
  SHELLCHECK_VERSION: v0.10.0
  SHFMT_VERSION: v3.13.0
  ACTIONLINT_VERSION: 1.7.0
  GHOSTTY_VERSION: 1.10.0
  TAPLO_VERSION: 0.9.0
  ZIZMOR_VERSION: 1.30.0
  GITLEAKS_VERSION: 8.30.0
  UV_VERSION: 0.12.0
steps:
  - run: echo "${SHELLCHECK_VERSION} ${SHFMT_VERSION} ${ACTIONLINT_VERSION} ${GHOSTTY_VERSION}"
  - run: echo "${TAPLO_VERSION} ${ZIZMOR_VERSION} ${GITLEAKS_VERSION} ${UV_VERSION}"
YML
    cat > "$dir/.github/tool-checksums.txt" << 'SUMS'
# fixture
aaaa  shellcheck-v0.10.0.darwin.aarch64.tar.xz
bbbb  shfmt_v3.13.0_darwin_arm64
cccc  actionlint_1.7.0_darwin_arm64.tar.gz
dddd  ghostty-1.10.0-macos-universal.zip
eeee  taplo-darwin-aarch64.gz
ffff  zizmor-aarch64-apple-darwin.tar.gz
9999  gitleaks_8.30.0_darwin_arm64.tar.gz
8888  uv-0.12.0-aarch64-apple-darwin.tar.gz
SUMS
    cp "$dir/.github/workflows/ci.yml" "$dir/ci.before"
    cp "$dir/.github/tool-checksums.txt" "$dir/sums.before"
    : > "$dir/missing"
    # Every tool current unless a case says otherwise.
    cat > "$dir/latest" << 'LATEST'
repos/koalaman/shellcheck/releases/latest v0.10.0
repos/mvdan/sh/releases/latest v3.13.0
repos/rhysd/actionlint/releases/latest v1.7.0
repos/ghostty-org/ghostty/tags?per_page=100 tip
repos/ghostty-org/ghostty/tags?per_page=100 v1.9.0
repos/ghostty-org/ghostty/tags?per_page=100 v1.10.0
repos/tamasfe/taplo/releases/latest 0.9.0
repos/zizmorcore/zizmor/releases/latest v1.30.0
repos/gitleaks/gitleaks/releases/latest v8.30.0
repos/astral-sh/uv/releases/latest 0.12.0
LATEST
  }
  latest() { edit "$dir/latest" "s|^\\($1\\) .*|\\1 $2|"; }
  run() {
    mkdir -p "$dir/tmp"
    (cd "$dir" && LATEST="$dir/latest" MISSING="$dir/missing" STAGE="$dir/tmp" PATH="$tmp/bin" ./bump-tools.sh 2>&1)
  }
  untouched() {
    cmp -s "$dir/ci.before" "$dir/.github/workflows/ci.yml" &&
      cmp -s "$dir/sums.before" "$dir/.github/tool-checksums.txt"
  }
  sum_of() { printf 'artifact:%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
  as_expected() {
    cmp -s "$dir/ci.want" "$dir/.github/workflows/ci.yml" &&
      cmp -s "$dir/sums.want" "$dir/.github/tool-checksums.txt"
  }
  differences() {
    diff "$dir/ci.want" "$dir/.github/workflows/ci.yml"
    diff "$dir/sums.want" "$dir/.github/tool-checksums.txt"
  }

  local gh=https://github.com
  local sc_url=$gh/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.darwin.aarch64.tar.xz

  fixture moved
  latest repos/koalaman/shellcheck/releases/latest v0.11.0
  latest repos/mvdan/sh/releases/latest v3.14.0
  latest repos/rhysd/actionlint/releases/latest v1.7.1
  printf '%s\n' 'repos/ghostty-org/ghostty/tags?per_page=100 v1.11.0' \
    'repos/ghostty-org/ghostty/tags?per_page=100 v1.11.0-rc1' >> "$dir/latest"
  latest repos/tamasfe/taplo/releases/latest 0.10.0
  latest repos/zizmorcore/zizmor/releases/latest v1.31.0
  latest repos/gitleaks/gitleaks/releases/latest v8.31.0
  latest repos/astral-sh/uv/releases/latest 0.13.0
  out=$(run) || {
    echo "move: refused newer, downloadable releases: $out"
    return 1
  }
  cat > "$dir/ci.want" << 'YML'
env:
  SHELLCHECK_VERSION: v0.11.0
  SHFMT_VERSION: v3.14.0
  ACTIONLINT_VERSION: 1.7.1
  GHOSTTY_VERSION: 1.11.0
  TAPLO_VERSION: 0.10.0
  ZIZMOR_VERSION: 1.31.0
  GITLEAKS_VERSION: 8.31.0
  UV_VERSION: 0.13.0
steps:
  - run: echo "${SHELLCHECK_VERSION} ${SHFMT_VERSION} ${ACTIONLINT_VERSION} ${GHOSTTY_VERSION}"
  - run: echo "${TAPLO_VERSION} ${ZIZMOR_VERSION} ${GITLEAKS_VERSION} ${UV_VERSION}"
YML
  cat > "$dir/sums.want" << SUMS
# fixture
$(sum_of "$sc_url")  shellcheck-v0.11.0.darwin.aarch64.tar.xz
$(sum_of $gh/mvdan/sh/releases/download/v3.14.0/shfmt_v3.14.0_darwin_arm64)  shfmt_v3.14.0_darwin_arm64
$(sum_of $gh/rhysd/actionlint/releases/download/v1.7.1/actionlint_1.7.1_darwin_arm64.tar.gz)  actionlint_1.7.1_darwin_arm64.tar.gz
$(sum_of https://release.files.ghostty.org/1.11.0/ghostty-macos-universal.zip)  ghostty-1.11.0-macos-universal.zip
$(sum_of $gh/tamasfe/taplo/releases/download/0.10.0/taplo-darwin-aarch64.gz)  taplo-darwin-aarch64.gz
$(sum_of $gh/zizmorcore/zizmor/releases/download/v1.31.0/zizmor-aarch64-apple-darwin.tar.gz)  zizmor-aarch64-apple-darwin.tar.gz
$(sum_of $gh/gitleaks/gitleaks/releases/download/v8.31.0/gitleaks_8.31.0_darwin_arm64.tar.gz)  gitleaks_8.31.0_darwin_arm64.tar.gz
$(sum_of $gh/astral-sh/uv/releases/download/0.13.0/uv-aarch64-apple-darwin.tar.gz)  uv-0.13.0-aarch64-apple-darwin.tar.gz
SUMS
  as_expected || {
    echo "move: each pin, its spelling and its checksum line are not what moving all eight gives:"
    differences
    return 1
  }
  case "$out" in *"Everything is on its latest release"*)
    echo "move: said every tool is current after moving them: $out"
    return 1
    ;;
  esac

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
  echo $gh/rhysd/actionlint/releases/download/v1.7.1/actionlint_1.7.1_darwin_arm64.tar.gz > "$dir/missing"
  if out=$(run) || ! untouched; then
    echo "undownloadable: did not refuse, untouched, a release whose artifact 404s: $out"
    return 1
  fi

  fixture no-checksum-line
  edit "$dir/.github/tool-checksums.txt" '/zizmor-aarch64-apple-darwin/d'
  cp "$dir/.github/tool-checksums.txt" "$dir/sums.before"
  latest repos/zizmorcore/zizmor/releases/latest v1.31.0
  if out=$(run) || ! untouched; then
    echo "no checksum line: did not refuse, untouched, a pin with no checksum line to replace: $out"
    return 1
  fi

  # The script reaches shellcheck before shfmt. Moving shellcheck and then
  # stopping, or moving nothing, both leave every pin agreeing with its
  # checksum; anything else does not.
  fixture partial
  latest repos/koalaman/shellcheck/releases/latest v0.11.0
  latest repos/mvdan/sh/releases/latest v3.14.0
  echo $gh/mvdan/sh/releases/download/v3.14.0/shfmt_v3.14.0_darwin_arm64 > "$dir/missing"
  if out=$(run); then
    echo "partial: succeeded although shfmt's artifact 404s"
    return 1
  fi
  cp "$dir/ci.before" "$dir/ci.want"
  cp "$dir/sums.before" "$dir/sums.want"
  edit "$dir/ci.want" 's|SHELLCHECK_VERSION: v0.10.0|SHELLCHECK_VERSION: v0.11.0|'
  edit "$dir/sums.want" "s|^aaaa  shellcheck-v0.10.0.darwin.aarch64.tar.xz\$|$(sum_of "$sc_url")  shellcheck-v0.11.0.darwin.aarch64.tar.xz|"
  untouched || as_expected || {
    echo "partial: a failure on shfmt left a pin and its checksum disagreeing, or touched shfmt:"
    differences
    return 1
  }

  local staged
  for staged in "$tmp"/*/tmp; do
    [ -z "$(ls -A "$staged")" ] || {
      echo "staging: left its downloads behind in $staged: $(ls -A "$staged")"
      return 1
    }
  done
}
check "bump-tools.sh moves each pin with its checksum, and refuses a downgrade, a 404 or a missing line untouched" bump_tools
