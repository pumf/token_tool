#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP="build/TokenTool.app"
rm -rf "$APP" build/TokenTool-arm64 build/TokenTool-x86_64
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -O -parse-as-library \
        -target "${arch}-apple-macos13.0" \
        -framework SwiftUI -framework AppKit -framework Combine -framework UserNotifications \
        Views.swift TokenToolApp.swift \
        -o "build/TokenTool-${arch}"
done

lipo -create "build/TokenTool-arm64" "build/TokenTool-x86_64" \
    -output "$APP/Contents/MacOS/TokenTool"
rm -f build/TokenTool-arm64 build/TokenTool-x86_64

cp Info.plist "$APP/Contents/Info.plist"
cp collector.py "$APP/Contents/Resources/collector.py"

codesign --force --sign - "$APP" >/dev/null

echo "built $APP"
