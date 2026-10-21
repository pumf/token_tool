#!/bin/zsh
set -euo pipefail

cd "$(dirname "$0")"

APP="build/TokenTool.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library \
    -target arm64-apple-macos13.0 \
    -framework SwiftUI -framework AppKit -framework Combine \
    Views.swift TokenToolApp.swift \
    -o "$APP/Contents/MacOS/TokenTool"

cp Info.plist "$APP/Contents/Info.plist"
cp collector.py "$APP/Contents/Resources/collector.py"

codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "built $APP"
