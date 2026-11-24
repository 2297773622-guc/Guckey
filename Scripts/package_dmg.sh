#!/bin/bash
# 构建 universal(arm64 + x86_64) release → .app bundle → 签名 → 压缩 DMG
#
# 用法：
#   cd Guckey && ./Scripts/package_dmg.sh
#   SIGN_IDENTITY="Developer ID Application: 顾初 (TEAMID)" HARDENED_RUNTIME=1 ./Scripts/package_dmg.sh
#   OUTPUT_DIR=/path/to/output ./Scripts/package_dmg.sh
#
# 若指定的签名证书不在钥匙串中，自动降级为 ad-hoc 签名（-）。

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$(cd "$PROJECT_DIR/.." && pwd)}"
APP_NAME="Guckey.app"
STAGING="$OUTPUT_DIR/dist"
APP="$STAGING/$APP_NAME"
# 版本号唯一来源：Resources/Info.plist，避免脚本与 plist 各写一份对不上。
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist")"
DMG="$OUTPUT_DIR/Guckey-$VERSION.dmg"
SIGN_IDENTITY="${SIGN_IDENTITY:-Apple Development: 2297773622@qq.com (BYLFLH4V4P)}"

echo "==> 1/5 构建 universal release"
swift build --package-path "$PROJECT_DIR" -c release --arch arm64 --arch x86_64 --disable-sandbox
BIN="$PROJECT_DIR/.build/apple/Products/Release/Guckey"
lipo -info "$BIN"

echo "==> 2/5 组装 .app bundle"
rm -rf "$STAGING"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# 云端连接参数：本地有就打进包（该文件在 .gitignore 里，不入库）。
if [[ -f "$PROJECT_DIR/Resources/CloudConfig.json" ]]; then
    cp "$PROJECT_DIR/Resources/CloudConfig.json" "$APP/Contents/Resources/CloudConfig.json"
    echo "已打入 CloudConfig.json"
else
    echo "⚠️ 未找到 Resources/CloudConfig.json，包内云端库将显示「未配置」"
fi
cp "$BIN" "$APP/Contents/MacOS/Guckey"
chmod 755 "$APP/Contents/MacOS/Guckey"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 3/5 代码签名"
if security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    IDENTITY="$SIGN_IDENTITY"
    echo "使用证书：$IDENTITY"
else
    IDENTITY="-"
    echo "⚠️ 钥匙串未找到证书「$SIGN_IDENTITY」，降级为 ad-hoc 签名"
fi
xattr -cr "$APP"
# 公证（notarization）要求 app 启用 hardened runtime；本地开发签名不需要。
# 不用数组展开：macOS 自带 bash 3.2 在 set -u 下展开空数组会报 unbound variable。
if [[ "${HARDENED_RUNTIME:-0}" == "1" ]]; then
    echo "启用 hardened runtime"
    codesign --force --deep --sign "$IDENTITY" --timestamp=none --options runtime "$APP"
else
    codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
fi
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> 4/5 生成 DMG"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Guckey" -srcfolder "$STAGING" -ov \
        -format UDZO -fs HFS+ "$DMG"
codesign --force --sign "$IDENTITY" --timestamp=none "$DMG"

echo "==> 5/5 校验"
hdiutil verify "$DMG"
codesign --verify --verbose=1 "$DMG"
ls -lh "$DMG"
shasum -a 256 "$DMG"
echo "完成：$DMG"
