#!/bin/zsh
# 编译并运行回归测试：Swift 侧是纯函数与视图口径，Python 侧是 collector.py 的解析层。
# 本机只有 CommandLineTools，没有 Xcode，XCTest / swift-testing 均不可用，
# 因此测试与源码一起用 swiftc 编成可执行文件（与 build.sh 同一套编译方式）。
set -euo pipefail

cd "$(dirname "$0")"

ARCH="$(uname -m)"
mkdir -p build

swiftc -Onone -parse-as-library \
    -target "${ARCH}-apple-macos12.0" \
    -framework SwiftUI -framework AppKit -framework Combine -framework UserNotifications -framework Carbon \
    Analytics.swift Providers.swift Persistence.swift Diagnostics.swift Models.swift CollectorRunner.swift HotKey.swift UsageStore.swift Views.swift Export.swift Update.swift \
    Tests/AnalyticsTests.swift \
    -o build/TokenToolTests

./build/TokenToolTests

# collector.py 只测解析层：喂固定文本，不启动任何 CLI 或本机 IPC。
python3 Tests/CollectorTests.py
