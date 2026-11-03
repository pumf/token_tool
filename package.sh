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
    local stage="$OUT/stage${suffix:-universal}"
    # 卷宗与压缩包里一律叫 TokenTool.app：带架构后缀的名字会让用户以为装了第二个应用，
    # 拖进「应用程序」也不会覆盖已有的 TokenTool，更新时找不到正确的那一份。
    rm -rf "$stage"
    mkdir -p "$stage"
    ditto "$app" "$stage/TokenTool.app"
    # 没有这个软链接，DMG 窗口里就没有「拖到 Applications」的目标，只能自己另开 Finder。
    ln -s /Applications "$stage/Applications"
    codesign --verify --deep --strict "$stage/TokenTool.app"
    hdiutil create -quiet -volname TokenTool -srcfolder "$stage" -ov -format UDZO "$OUT/${base}.dmg"
    ditto -c -k --keepParent "$stage/TokenTool.app" "$OUT/${base}.zip"
    rm -rf "$stage"
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
