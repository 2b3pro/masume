#!/bin/bash
# Builds the masume command-line tool in release and installs it at a stable
# path, which is what the macOS Automation grant attaches to.
#
#   bash scripts/install-cli.sh [prefix]     default prefix: /usr/local
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${1:-/usr/local}"
cd "$ROOT"
echo "==> swift build -c release --product masume"
swift build -c release --product masume
BIN="$(swift build -c release --show-bin-path)/masume"
mkdir -p "$PREFIX/bin"
cp "$BIN" "$PREFIX/bin/masume"
codesign --force --sign - "$PREFIX/bin/masume"
echo "Installed: $PREFIX/bin/masume"
"$PREFIX/bin/masume" --help 2>&1 | head -3
