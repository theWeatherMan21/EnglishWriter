#!/bin/bash
# realshot.sh — 真机下划线截图（验收用，产物落 out/）
#
# 为什么必须 open -a 起：TCC 辅助功能授权是发给「英文写作助手.app」这个二进制的。
# 从终端直接 exec Contents/MacOS/英文写作助手 → 系统不认这个起法，permission 恒 false。
#
# 用法：scripts/realshot.sh [outDir] [bundleId] [window x,y,w,h]
#   靶子：TARGET=textedit（默认，新建空白文档，不碰任何已有文件）
#         TARGET=mail（新建草稿 → 正文打字 → 截完即关，不加收件人、不发送）
# 产物：<outDir>/realshot-status.json（App 自己写的落点）+ <outDir>/realshot.png + 分靶子副本
set -uo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$PWD/out}"
TARGET="${TARGET:-textedit}"
case "$TARGET" in
  mail) BUNDLE="${2:-com.apple.mail}" ;;
  *)    BUNDLE="${2:-com.apple.TextEdit}" ;;
esac
WINDOW="${3:-60,60,960,660}"
HOLD="${HOLD:-45}"
APP="/Applications/Selfmade/英文写作助手.app"
# 只杀带本脚本参数的探针实例（--realshot/--axcheck/…）；无参数的那个是爹地在用的，绝不许碰
PK="Selfmade/英文写作助手.app/Contents/MacOS"
kill_probes() {
  pgrep -f "$PK" | while read -r p; do
    ps -o args= -p "$p" | grep -q -- "--realshot\|--axcheck\|--axwatch\|--axaccept\|--passive\|--probe\|--docscan\|--live-" \
      && kill -TERM "$p" 2>/dev/null
  done
}
SHOT="$OUT/realshot-$TARGET.png"

mkdir -p "$OUT"
rm -f "$OUT/realshot-status.json"

echo "== 1/5 收拾旧探针进程（用户实例不碰）=="
kill_probes
sleep 1

echo "== 2/5 起靶子（TARGET=${TARGET}）=="
case "$TARGET" in
  textedit)
    # 只新建一个未命名空白窗口，不碰任何已有文档
    osascript >/dev/null 2>&1 <<'EOF2' || echo "（TextEdit 靶子启动失败）"
tell application "TextEdit"
  activate
  make new document
  delay 0.8
end tell
EOF2
    ;;
  mail)
    # 只建草稿、只在正文打字；不加收件人、不发送，截完立刻关掉（不保存）
    osascript >/dev/null 2>&1 <<'EOF3' || echo "（Mail 草稿窗口启动失败）"
tell application "Mail"
  activate
  make new outgoing message with properties {visible:true}
  delay 1.0
end tell
EOF3
    ;;
  *) echo "未知 TARGET=${TARGET}（只支持 textedit / mail）"; exit 2 ;;
esac
sleep 1

echo "== 3/5 open -a 起 App（授权只认这条路）=="
# 靶子窗口的标题：App 里据此选中对的窗口（多开了好几个时不出错）
case "$TARGET" in
  mail) NAME=$(osascript -e 'tell application "Mail" to get name of front window' 2>/dev/null || true) ;;
  *)    NAME=$(osascript -e 'tell application "TextEdit" to get name of front document' 2>/dev/null || true) ;;
esac
echo "   靶子窗口标题：${NAME:-（空）}"
open -a "$APP" --args --realshot "$OUT" --hold "$HOLD" --bundle "$BUNDLE" --window "$WINDOW" --title "${NAME:-}"

echo "== 4/5 等 App 画完线（最多 25s）=="
for _ in $(seq 1 50); do
  [ -f "$OUT/realshot-status.json" ] && break
  sleep 0.5
done
[ -f "$OUT/realshot-status.json" ] || { echo "FAIL: App 没写出 status"; kill_probes; exit 3; }

read -r RECT INFO <<<"$(/usr/bin/python3 - "$OUT/realshot-status.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
r=d.get("windowRectQuartz") or []
rect=",".join(str(v) for v in r) if len(r)==4 else "-"
print(rect, "ok=%s rects=%s typed=%s diag=%s" % (d.get("ok"), d.get("underlineCount"), d.get("textSet"), d.get("diag")))
PY
)"
echo "   $INFO"
echo "   window rect: $RECT"
[ "$RECT" != "-" ] || { echo "FAIL: 拿不到窗口矩形"; kill_probes; exit 4; }

echo "== 5/5 截窗口区域（下划线是独立浮窗，必须截屏幕）=="
screencapture -x -R "$RECT" "$SHOT"
sips -g pixelWidth -g pixelHeight "$SHOT" | tail -2

# 收尾：只关自己起的那个窗口（Mail 草稿 / TextEdit 空白文档），不碰任何已有文档
if [ "$TARGET" = "mail" ]; then
  osascript >/dev/null 2>&1 <<'EOF4' || true
tell application "Mail"
  try
    repeat with w in (every window whose name is "New Message" or name is "新邮件" or name is "无主题")
      close w saving no
    end repeat
  end try
end tell
EOF4
else
  osascript >/dev/null 2>&1 <<'EOF5' || true
tell application "TextEdit"
  try
    if name of front document is "Untitled" then close front document saving no
  end try
end tell
EOF5
fi
kill_probes

ls -la "$OUT/realshot-status.json" "$SHOT"
