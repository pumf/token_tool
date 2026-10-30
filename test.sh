#!/bin/zsh
# 编译并运行 Analytics 回归测试。
# 本机只有 CommandLineTools，没有 Xcode，XCTest / swift-testing 均不可用，
# 因此测试与源码一起用 swiftc 编成可执行文件（与 build.sh 同一套编译方式）。
set -euo pipefail

cd "$(dirname "$0")"

ARCH="$(uname -m)"
mkdir -p build

swiftc -Onone -parse-as-library \
    -target "${ARCH}-apple-macos12.0" \
    -framework SwiftUI -framework AppKit -framework Combine -framework UserNotifications \
    Analytics.swift Providers.swift Persistence.swift Diagnostics.swift Views.swift Export.swift Update.swift \
    Tests/AnalyticsTests.swift \
    -o build/TokenToolTests

./build/TokenToolTests
