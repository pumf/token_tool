#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

BUILD="build"
UNIVERSAL_APP="$BUILD/TokenTool.app"
ARM_APP="$BUILD/TokenTool-arm64.app"
INTEL_APP="$BUILD/TokenTool-x86_64.app"

rm -rf "$UNIVERSAL_APP" "$ARM_APP" "$INTEL_APP" \
    "$BUILD/TokenTool-arm64" "$BUILD/TokenTool-x86_64"

for arch in arm64 x86_64; do
    swiftc -O -parse-as-library \
        -target "${arch}-apple-macos13.0" \
        -framework SwiftUI -framework AppKit -framework Combine -framework UserNotifications \
        Analytics.swift Views.swift TokenToolApp.swift \
        -o "$BUILD/TokenTool-${arch}"
done

lipo -create "$BUILD/TokenTool-arm64" "$BUILD/TokenTool-x86_64" \
    -output "$BUILD/TokenTool-universal"

assemble_app() {
    local app="$1" binary="$2"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$binary" "$app/Contents/MacOS/TokenTool"
    cp Info.plist "$app/Contents/Info.plist"
    cp collector.py "$app/Contents/Resources/collector.py"
    cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
    codesign --force --sign - "$app" >/dev/null
}

assemble_app "$UNIVERSAL_APP" "$BUILD/TokenTool-universal"
assemble_app "$ARM_APP" "$BUILD/TokenTool-arm64"
assemble_app "$INTEL_APP" "$BUILD/TokenTool-x86_64"

rm -f "$BUILD/TokenTool-arm64" "$BUILD/TokenTool-x86_64" "$BUILD/TokenTool-universal"

echo "built $UNIVERSAL_APP"
echo "built $ARM_APP"
echo "built $INTEL_APP"
