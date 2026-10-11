#!/usr/bin/env bash
# Installs Ghidra under ~/.local/share/ghidra and builds the decompiler that
# the release archive does not ship for macOS arm64.
#
# Usage:  install-ghidra        safe to re-run; does nothing once it is in place
#
# It exists for REA (the reverse-engineering MCP server in ~/.claude.json),
# which reads GHIDRA_INSTALL_DIR and refuses an install without a native
# decompiler for the host. Setup of REA never installs Ghidra or Java.
#
# Why a script: the archive has no mac_arm_64 decompiler (only linux_x86_64 and
# win_x86_64 in 12.1.4, 2026-10-10), and Ghidra's Makefile hardcodes
# `-arch x86_64` for Darwin, so a plain `make` builds the wrong architecture.
# Overriding ARCH_TYPE is the whole trick, and it is easy to forget.
#
# Needs: a JDK 21 (mise/config.toml declares it) and the Xcode command line
# tools for g++ and make. The zip is checked against the sha256 below.
# Moving to a newer Ghidra means changing VERSION, DATE and SHA256 together,
# then `rea setup` again so the registration points at the new directory.
set -euo pipefail

VERSION=12.1.4
DATE=20260921
SHA256=ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db

ROOT=${GHIDRA_ROOT:-$HOME/.local/share/ghidra}
NAME=ghidra_${VERSION}_PUBLIC
DEST=$ROOT/$NAME
DECOMPILER=$DEST/Ghidra/Features/Decompiler/os/mac_arm_64/decompile

if [ "$(uname -s)-$(uname -m)" != "Darwin-arm64" ]; then
  echo "install-ghidra: built for macOS arm64 only (this is $(uname -s)-$(uname -m))" >&2
  exit 1
fi
if [ -x "$DECOMPILER" ]; then
  echo "install-ghidra: $DEST is already in place"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ ! -d "$DEST" ]; then
  zip=${NAME}_$DATE.zip
  curl -fsSL -o "$tmp/$zip" \
    "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${VERSION}_build/$zip"
  echo "$SHA256  $tmp/$zip" | shasum -a 256 -c - > /dev/null || {
    echo "install-ghidra: checksum mismatch for $zip" >&2
    exit 1
  }
  mkdir -p "$ROOT"
  unzip -q "$tmp/$zip" -d "$ROOT"
fi

# Built in a copy so a failed or interrupted build leaves the install clean.
cp -R "$DEST/Ghidra/Features/Decompiler/src/decompile/cpp" "$tmp/cpp"
make -C "$tmp/cpp" -j"$(sysctl -n hw.ncpu)" ghidra_opt \
  ARCH_TYPE="-arch arm64" ADDITIONAL_FLAGS="-w -mmacosx-version-min=11.0" > "$tmp/build.log" 2>&1 || {
  tail -20 "$tmp/build.log" >&2
  echo "install-ghidra: decompiler build failed" >&2
  exit 1
}
mkdir -p "$(dirname "$DECOMPILER")"
cp "$tmp/cpp/ghidra_opt" "$DECOMPILER"

echo "install-ghidra: installed $DEST"
echo "  export GHIDRA_INSTALL_DIR=$DEST"
