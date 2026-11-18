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
# 装之前先看清有谁在跑：绝不许无条件 pkill —— 11-18 事故：脚本把爹地正在用的实例杀了，
# 他看到的是「点了图标就崩溃」，实际上是我们自己 SIGTERM 的。
RUNNING_NORMAL=$(pgrep -f "Selfmade/英文写作助手.app/Contents/MacOS" | while read -r p; do
  if ! ps -o args= -p "$p" | grep -q -- "--probe\|--axcheck\|--axwatch\|--axaccept\|--passive\|--realshot\|--docscan\|--live-"; then echo "$p"; fi
done)
RUNNING_PROBE=$(pgrep -f "Selfmade/英文写作助手.app/Contents/MacOS" | while read -r p; do
  if ps -o args= -p "$p" | grep -q -- "--probe\|--axcheck\|--axwatch\|--axaccept\|--passive\|--realshot\|--docscan\|--live-"; then echo "$p"; fi
done)

if [ -n "$RUNNING_NORMAL" ]; then
  echo "检测到正在使用的实例（pid $(echo $RUNNING_NORMAL | tr '\n' ' ')）→ 优雅退出后重启，不用 SIGTERM 硬杀"
fi
[ -n "$RUNNING_PROBE" ] && echo "还有探针实例（pid $(echo $RUNNING_PROBE | tr '\n' ' ')）→ 只杀这些"

# 探针实例可以硬杀（它们本来就是一次性的）
[ -n "$RUNNING_PROBE" ] && kill -TERM $RUNNING_PROBE 2>/dev/null
# 用户实例走 AppleScript 优雅退出：App 自己收尾，菜单栏图标正常消失，不会像崩溃
if [ -n "$RUNNING_NORMAL" ]; then
  osascript -e 'tell application "英文写作助手" to quit' >/dev/null 2>&1
  for _ in 1 2 3 4 5 6; do
    [ -z "$(pgrep -f 'Selfmade/英文写作助手.app/Contents/MacOS')" ] && break
    sleep 0.5
  done
fi
sleep 0.5
rm -rf "$DST"
cp -R "$SRC" "$DST" || { echo "复制失败"; exit 5; }
codesign --verify --deep --strict "$DST" && echo "签名校验通过" || { echo "签名校验失败"; exit 6; }
DST_BIN="$DST/Contents/MacOS/英文写作助手"
echo "已安装：${DST}"
echo "  二进制 mtime $(stat -f '%Sm' -t '%m-%d %H:%M:%S' "$DST_BIN")"
echo "  sha256 $(shasum -a 256 "$DST_BIN" | cut -d' ' -f1 | cut -c1-16)"

# 装完必须把用户实例拉回来：不许留「装了但没在跑」的空窗，也不许让他自己去找图标
if [ -n "$RUNNING_NORMAL" ] || [ "${1:-}" = "--start" ]; then
  open -a "$DST"
  sleep 2
  NEWPID=$(pgrep -f "Selfmade/英文写作助手.app/Contents/MacOS" | head -1)
  echo "  已重启：pid ${NEWPID:-未起来}"
fi
