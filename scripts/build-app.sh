#!/bin/bash
# Builds Masume.app — a native arm64 macOS app bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/Masume.app"
SIGNING_IDENTITY="${MASUME_SIGNING_IDENTITY:-}"
# SwiftPM names executable artifacts after their products. On the default
# case-insensitive macOS filesystem, the Masume GUI and masume CLI therefore
# resolve to the same output path. Keep the products in separate scratch
# directories so building one can never replace the other.
BUILD_SCRATCH_ROOT="${MASUME_SCRATCH_PATH:-$ROOT/build/swiftpm-products}"
APP_BUILD_ARGUMENTS=(-c "$CONFIG" --scratch-path "$BUILD_SCRATCH_ROOT/app")
CLI_BUILD_ARGUMENTS=(-c "$CONFIG" --scratch-path "$BUILD_SCRATCH_ROOT/cli")

# TCC must be able to compute a designated requirement for the Apple Event
# target. Prefer a real identity so Automation grants survive rebuilds.
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
        | awk '/"(Developer ID Application|Apple Development):/{print $2; exit}')"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "warning: no signing identity; macOS Automation may reject this ad-hoc build" >&2
fi

echo "==> swift build -c $CONFIG --product Masume"
cd "$ROOT"
swift build "${APP_BUILD_ARGUMENTS[@]}" --product Masume

BIN="$(swift build "${APP_BUILD_ARGUMENTS[@]}" --show-bin-path)/Masume"
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

# Finder discovers Quick Look providers only when their .appex bundles live
# inside the owning application. SwiftPM does not assemble application
# extensions, so compile the two small extension executables directly with
# the system SDK and give them the standard NSExtensionMain entry point.
echo "==> building Quick Look extensions"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TARGET_ARCH="$(uname -m)"
QUICK_LOOK_SUPPORT="$ROOT/Sources/MasumeQuickLookSupport/QuickLookPreviewAsset.swift"

build_quick_look_extension() {
    local name="$1"
    local module="$2"
    local source="$3"
    local framework="$4"
    local bundle="$APP/Contents/PlugIns/$name.appex"

    mkdir -p "$bundle/Contents/MacOS"
    cp "$ROOT/Extensions/$name/Info.plist" "$bundle/Contents/Info.plist"
    xcrun swiftc \
        -parse-as-library \
        -emit-executable \
        -O \
        -whole-module-optimization \
        -application-extension \
        -target "$TARGET_ARCH-apple-macos15.0" \
        -sdk "$SDK_PATH" \
        -module-name "$module" \
        -Xlinker -e \
        -Xlinker _NSExtensionMain \
        "$QUICK_LOOK_SUPPORT" \
        "$ROOT/Extensions/$name/$source" \
        -framework "$framework" \
        -o "$bundle/Contents/MacOS/$name"
}

build_quick_look_extension "MasumeQuickLookPreview" "MasumeQuickLookPreview" "PreviewProvider.swift" "Quartz"
build_quick_look_extension "MasumeQuickLookThumbnail" "MasumeQuickLookThumbnail" "ThumbnailProvider.swift" "QuickLookThumbnailing"

# The CLI rides inside the app bundle for the in-app installer and MCP server.
# Under Helpers, not MacOS: on a case-insensitive disk MacOS/masume would
# overwrite MacOS/Masume.
echo "==> swift build -c $CONFIG --product masume"
swift build "${CLI_BUILD_ARGUMENTS[@]}" --product masume
mkdir -p "$APP/Contents/Helpers"
CLI_BIN="$(swift build "${CLI_BUILD_ARGUMENTS[@]}" --show-bin-path)/masume"
cp "$CLI_BIN" "$APP/Contents/Helpers/masume"
if cmp -s "$APP/Contents/MacOS/Masume" "$APP/Contents/Helpers/masume"; then
    echo "error: GUI and CLI executables are identical; SwiftPM product outputs collided" >&2
    exit 1
fi

# The MCP server, when it has been built (cd mcp && npm install && npm run build).
if [[ -d "$ROOT/mcp/dist" ]]; then
    echo "==> bundling mcp server"
    mkdir -p "$APP/Contents/Resources/mcp"
    cp -R "$ROOT/mcp/dist" "$ROOT/mcp/package.json" "$APP/Contents/Resources/mcp/"
    [[ -d "$ROOT/mcp/node_modules" ]] && cp -cR "$ROOT/mcp/node_modules" "$APP/Contents/Resources/mcp/"
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
    for extension_info in "$APP"/Contents/PlugIns/*.appex/Contents/Info.plist; do
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$extension_info"
        /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$extension_info"
    done
fi

echo "==> code signing Quick Look extensions with $SIGNING_IDENTITY"
for extension_bundle in "$APP"/Contents/PlugIns/*.appex; do
    codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
        --entitlements "$ROOT/Resources/MasumeQuickLook.entitlements" "$extension_bundle"
done
echo "==> code signing nested CLI with $SIGNING_IDENTITY"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime \
    --entitlements "$ROOT/Resources/MasumeCLI.entitlements" "$APP/Contents/Helpers/masume"
echo "==> code signing with $SIGNING_IDENTITY"
codesign --force --sign "$SIGNING_IDENTITY" --options runtime "$APP"

echo "==> verifying"
codesign --verify --deep --strict --verbose "$APP"
echo "arch: $(lipo -archs "$APP/Contents/MacOS/Masume")"
echo "Built: $APP"
