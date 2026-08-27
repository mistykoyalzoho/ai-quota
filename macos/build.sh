#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCES_DIR="$SCRIPT_DIR/Sources"
DIST_DIR="$SCRIPT_DIR/dist"
APP_NAME="AIQuota"
BUNDLE="$DIST_DIR/$APP_NAME.app"
BIN_NAME="AIQuota"
RESOURCES_DIR="$SCRIPT_DIR/Resources"

echo "Compiling Unified AI Quota (Universal x86_64 + arm64)…"

SDK_PATH="$(xcrun --show-sdk-path --sdk macosx)"

# Collect all swift source files
SWIFT_FILES=()
while IFS= read -r -d '' f; do
    SWIFT_FILES+=("$f")
done < <(find "$SOURCES_DIR" -name "*.swift" -print0)

FRAMEWORKS=(
    -framework AppKit
    -framework SwiftUI
    -framework WebKit
    -framework Foundation
    -framework Security
    -framework ServiceManagement
    -framework LocalAuthentication
)

SWIFT_FLAGS=(
    -O
    -sdk "$SDK_PATH"
    -target "" # overridden per-arch
    "${FRAMEWORKS[@]}"
)

mkdir -p "$DIST_DIR/build"

# Compile x86_64
echo "Building x86_64 slice (Intel)…"
swiftc "${SWIFT_FLAGS[@]}" \
    -target x86_64-apple-macos13.0 \
    -o "$DIST_DIR/build/${BIN_NAME}_x86_64" \
    "${SWIFT_FILES[@]}"

# Compile arm64
echo "Building arm64 slice (Apple Silicon)…"
swiftc "${SWIFT_FLAGS[@]}" \
    -target arm64-apple-macos13.0 \
    -o "$DIST_DIR/build/${BIN_NAME}_arm64" \
    "${SWIFT_FILES[@]}"

# Create App bundle structure
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"

# Lipo create Universal binary
echo "Combining architectures into Universal binary…"
lipo -create \
    "$DIST_DIR/build/${BIN_NAME}_x86_64" \
    "$DIST_DIR/build/${BIN_NAME}_arm64" \
    -output "$BUNDLE/Contents/MacOS/$BIN_NAME"

chmod +x "$BUNDLE/Contents/MacOS/$BIN_NAME"

# Copy Info.plist and Icons
cp "$RESOURCES_DIR/Info.plist" "$BUNDLE/Contents/Info.plist"
if [ -f "$RESOURCES_DIR/AppIcon.icns" ]; then
    cp "$RESOURCES_DIR/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign
echo "Signing bundle…"
codesign --force --deep -s - "$BUNDLE"

# Clean temp build artifacts
rm -rf "$DIST_DIR/build"

echo "Built: $BUNDLE"
