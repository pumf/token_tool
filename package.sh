#!/bin/zsh
# 打包三架构六资产（arm64 / x86_64 / 通用 × DMG + ZIP）并生成 SHA256SUMS 校验清单。
# 用法：./build.sh && ./package.sh
set -euo pipefail

cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
OUT="build/dist"

if [[ ! -d build/TokenTool.app ]]; then
    echo "缺少 build/TokenTool.app，请先执行 ./build.sh" >&2
    exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"

package() {
    local app="$1"
    local suffix="$2"
    local base="TokenTool-${VERSION}${suffix}"
    hdiutil create -quiet -volname TokenTool -srcfolder "$app" -ov -format UDZO "$OUT/${base}.dmg"
    ditto -c -k --keepParent "$app" "$OUT/${base}.zip"
}

package build/TokenTool-arm64.app -arm64
package build/TokenTool-x86_64.app -x86_64
package build/TokenTool.app ""

cd "$OUT"
rm -f SHA256SUMS
shasum -a 256 TokenTool-*.dmg TokenTool-*.zip > SHA256SUMS
chmod 644 SHA256SUMS

echo "打包完成：$OUT"
cat SHA256SUMS
