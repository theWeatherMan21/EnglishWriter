#!/bin/bash
# 把 build/ 产物装到 /Applications/Selfmade（先备份再替换，然后验签）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3
SRC="build/英文写作助手.app"
DST="/Applications/Selfmade/英文写作助手.app"
[ -d "$SRC" ] && [ -x "$SRC/Contents/MacOS/英文写作助手" ] || { echo "源产物不存在或不完整：$SRC"; exit 4; }
mkdir -p /Applications/Selfmade
if [ -d "$DST" ]; then
  BK="$HOME/.hermes/backups/英文写作助手-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BK" && cp -R "$DST" "$BK/" && echo "已备份 → $BK"
fi
pkill -f "Selfmade/英文写作助手.app/Contents/MacOS" 2>/dev/null; sleep 1
rm -rf "$DST"
cp -R "$SRC" "$DST" || { echo "复制失败"; exit 5; }
codesign --verify --deep --strict "$DST" && echo "签名校验通过" || { echo "签名校验失败"; exit 6; }
DST_BIN="$DST/Contents/MacOS/英文写作助手"
echo "已安装：${DST}"
echo "  二进制 mtime $(stat -f '%Sm' -t '%m-%d %H:%M:%S' "$DST_BIN")"
echo "  sha256 $(shasum -a 256 "$DST_BIN" | cut -d' ' -f1 | cut -c1-16)"
