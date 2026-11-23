#!/bin/bash
# 把 extension/（MV3）打成 Safari 可加载的 .appex 外壳，不需要 Xcode 图形界面。
# 产物：out/safari/英文写作助手 Safari.app/Contents/PlugIns/EnglishWriterExtension.appex
#
# 为什么要这个脚本：本机只装了 Command Line Tools，没有 safari-web-extension-converter
# （那是 Xcode 自带）。但 .appex 本质就是一个带固定 Info.plist 的 bundle，
# 手装 + 临时签名即可被 Safari 识别为「未签名的扩展」，用开发者菜单放行。
#
# 判据（脚本自己会验，不靠眼看）：
#   1. Info.plist 可 plutil -lint，且 NSExtensionPointIdentifier = com.apple.Safari.web-extension
#   2. Resources/manifest.json 是合法 JSON 且 manifest_version = 3
#   3. codesign --verify --deep --strict 通过
#   4. 包里 content.js / ui/ 与源目录逐字节一致（改源没重新打包会被抓）
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="extension"
OUT="out/safari"
APP="$OUT/英文写作助手 Safari.app"
APPEX="$APP/Contents/PlugIns/EnglishWriterExtension.appex"
BUNDLE_ID="com.wanyi.englishwriter.safari"
VER="0.1.0"

rm -rf "$OUT"
mkdir -p "$APPEX/Contents/Resources" "$APP/Contents/MacOS"

# 1) 扩展本体：manifest 与资源全部进 Resources/
cp "$SRC/manifest.json" "$SRC/content.js" "$SRC/options.html" "$SRC/options.js" "$APPEX/Contents/Resources/"
cp -R "$SRC/ui" "$APPEX/Contents/Resources/ui"

cat > "$APPEX/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>EnglishWriter</string>
  <key>CFBundleExecutable</key><string>EnglishWriterExtension</string>
  <key>CFBundleIdentifier</key><string>com.wanyi.englishwriter.safari.ext</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>EnglishWriterExtension</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.Safari.web-extension</string>
    <key>NSExtensionPrincipalClass</key><string>SafariWebExtensionHandler</string>
  </dict>
</dict>
</plist>
PLIST

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>EnglishWriter Safari</string>
  <key>CFBundleExecutable</key><string>EnglishWriterSafari</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>EnglishWriterSafari</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VER}</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
</dict>
</plist>
PLIST

# 2) 原生处理器：Safari 加载扩展时要能找到 NSExtensionPrincipalClass 对应的类，
#    没有它就只在「设置」里显示一行、内容脚本永远不会跑。用 swiftc 直接编，不需要 Xcode。
HANDLER="extension/handler/SafariWebExtensionHandler.swift"
mkdir -p "$APPEX/Contents/MacOS"
if swiftc -O -swift-version 5 -framework Foundation \
     -o "$APPEX/Contents/MacOS/EnglishWriterExtension" "$HANDLER" 2>/tmp/appex-swiftc.log; then
  echo "OK  原生处理器已编译：$(basename "$APPEX/Contents/MacOS/EnglishWriterExtension")"
else
  echo "FAIL 原生处理器编译失败，见 /tmp/appex-swiftc.log"
  tail -5 /tmp/appex-swiftc.log
  exit 1
fi

# 3) 外层 App 需要可执行体（空壳足够，Safari 只认它携带的 appex）
cat > "$APP/Contents/MacOS/EnglishWriterSafari" <<'SH'
#!/bin/sh
# 这个可执行体只为让外层 App 合法；扩展本体在 Contents/PlugIns/*.appex
exit 0
SH
chmod +x "$APP/Contents/MacOS/EnglishWriterSafari"

# 3) 临时签名（本机自用；分发需要开发者证书）
codesign --force --deep --sign - "$APPEX" >/dev/null 2>&1
codesign --force --deep --sign - "$APP" >/dev/null 2>&1

# 4) 自验
fail=0
plutil -lint "$APPEX/Contents/Info.plist" >/dev/null || { echo "FAIL Info.plist 不合法"; fail=1; }
point=$(/usr/libexec/PlistBuddy -c "Print :NSExtension:NSExtensionPointIdentifier" "$APPEX/Contents/Info.plist" 2>/dev/null || echo "")
[ "$point" = "com.apple.Safari.web-extension" ] || { echo "FAIL 扩展点不对：$point"; fail=1; }
python3 - "$APPEX/Contents/Resources/manifest.json" <<'PY' || fail=1
import json,sys
m=json.load(open(sys.argv[1]))
assert m.get("manifest_version")==3, "manifest_version != 3"
assert m.get("content_scripts"), "缺 content_scripts"
print("OK  manifest v3 · content_scripts %d 条" % len(m["content_scripts"]))
PY
codesign --verify --deep --strict "$APP" 2>/dev/null || { echo "FAIL 签名校验不过"; fail=1; }
for f in manifest.json content.js options.html options.js; do
  cmp -s "$SRC/$f" "$APPEX/Contents/Resources/$f" || { echo "FAIL $f 与源不一致"; fail=1; }
done
diff -r "$SRC/ui" "$APPEX/Contents/Resources/ui" >/dev/null || { echo "FAIL ui/ 与源不一致"; fail=1; }

if [ "$fail" -eq 0 ]; then
  echo "RESULT: READY  $APP"
  echo "  扩展点 = $point"
  echo "  下一步（要人在屏幕前点一次）：Safari → 设置 → 扩展 → 勾选 EnglishWriter"
  echo "  未签名扩展需先开：Safari → 设置 → 高级 → 显示「开发」菜单 → 允许未签名的扩展"
else
  echo "RESULT: FAIL"
  exit 1
fi
