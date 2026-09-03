#!/bin/bash
# Builds Masume.app — a native arm64, ad-hoc-signed macOS app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Masume.app"

echo "==> swift build -c $CONFIG"
cd "$ROOT"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/Masume"
if [[ ! -f "$BIN" ]]; then
    echo "error: built binary not found at $BIN" >&2
    exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Masume"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Masume.sdef" "$APP/Contents/Resources/Masume.sdef"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The masume CLI rides inside the bundle so the MCP server (and Automation
# grants) have a stable binary to point at. Under Helpers, not MacOS: on a
# case-insensitive disk MacOS/masume would overwrite MacOS/Masume.
echo "==> swift build -c $CONFIG --product masume"
swift build -c "$CONFIG" --product masume
mkdir -p "$APP/Contents/Helpers"
cp "$(swift build -c "$CONFIG" --show-bin-path)/masume" "$APP/Contents/Helpers/masume"

# The MCP server, when it has been built (cd mcp && npm install && npm run build).
if [[ -d "$ROOT/mcp/dist" ]]; then
    echo "==> bundling mcp server"
    mkdir -p "$APP/Contents/Resources/mcp"
    cp -R "$ROOT/mcp/dist" "$ROOT/mcp/package.json" "$APP/Contents/Resources/mcp/"
    [[ -d "$ROOT/mcp/node_modules" ]] && cp -R "$ROOT/mcp/node_modules" "$APP/Contents/Resources/mcp/"
else
    echo "note: mcp/dist not found; the in-app MCP server will be unavailable (run npm install && npm run build in mcp/)" >&2
fi

ICON_SRC="$ROOT/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    echo "==> copying AppIcon.icns"
    cp "$ICON_SRC" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "warning: $ICON_SRC not found" >&2
fi


# Version stamp: the VERSION env var or 2nd arg ("v" prefix tolerated), else
# the repository's VERSION file. Must happen before codesign: editing
# Info.plist afterwards breaks the seal.
VERSION="${VERSION:-${2:-}}"
if [[ -z "$VERSION" && -f "$ROOT/VERSION" ]]; then
    VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
fi
if [[ -n "$VERSION" ]]; then
    VERSION="${VERSION#v}"
    echo "==> stamping version $VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

echo "==> ad-hoc code signing"
codesign --force --sign - "$APP"

echo "==> verifying"
codesign --verify --verbose "$APP"
echo "arch: $(lipo -archs "$APP/Contents/MacOS/Masume")"
echo "Built: $APP"
