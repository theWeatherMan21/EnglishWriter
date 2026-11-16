#!/bin/bash
# build.sh — 编译并打包 .app，用本机稳定证书签名（重编译不丢 TCC 授权）
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="英文写作助手"
BUNDLE_ID="com.wanyi.englishwriter"
SIGN_ID="${SIGN_ID:-SOALedger Dev}"
VERSION="0.2.0"

rm -rf build
mkdir -p build

swiftc -O -swift-version 5 Sources/*.swift -o "build/$NAME" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices

APP="build/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/$NAME" "$APP/Contents/MacOS/$NAME"
cp fixtures/glossary.json "$APP/Contents/Resources/glossary.json"
cp scripts/languagetool-up.sh "$APP/Contents/Resources/languagetool-up.sh"
chmod +x "$APP/Contents/Resources/languagetool-up.sh"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${NAME}</string>
  <key>CFBundleDisplayName</key><string>${NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

xattr -cr "$APP" 2>/dev/null || true
find "$APP" -name '._*' -delete 2>/dev/null || true
dot_clean -m "$APP" 2>/dev/null || true
codesign -s "$SIGN_ID" -f "$APP"

echo "built: $APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier=|Authority=|Executable=" || true
