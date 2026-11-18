#!/bin/bash
# 装机版 vs 仓库 build 的新旧闸门
#
# 为什么有它：改完代码只 build 不装，爹地点开的是旧二进制——他会看到「什么都没变」，
# 而我报的是「已交付」。这种错我自己犯过，用脚本闸住。
#
# 用法：bash scripts/install-check.sh [--install]
#   退出码：0 = SYNC / 1 = STALE（仓库更新，需要装）/ 2 = 未安装
set -uo pipefail
cd "$(dirname "$0")/.." || exit 3

APP="/Applications/Selfmade/英文写作助手.app"
BIN="$APP/Contents/MacOS/英文写作助手"
BUILD="build/英文写作助手.app/Contents/MacOS/英文写作助手"

if [ ! -x "$BIN" ]; then
  echo "装机二进制 : 不存在（$BIN）"
  echo "RESULT: NOT_INSTALLED"
  exit 2
fi
if [ ! -x "$BUILD" ]; then
  echo "仓库 build : 不存在（先 bash scripts/build.sh）"
  echo "RESULT: NO_BUILD"
  exit 1
fi

# 用内容哈希比对，不用 mtime：cp -R 会把装机文件的 mtime 改成「复制时刻」，
# 按时间比会永远显示 SYNC，等于闸门形同虚设（这个坑当场踩到过）。
i_sha=$(shasum -a 256 "$BIN" | cut -d' ' -f1)
b_sha=$(shasum -a 256 "$BUILD" | cut -d' ' -f1)
echo "装机二进制 : $(stat -f '%Sm' -t '%m-%d %H:%M:%S' "$BIN")"
echo "仓库 build : $(stat -f '%Sm' -t '%m-%d %H:%M:%S' "$BUILD")"
echo "装机 sha256: ${i_sha:0:16}"
echo "仓库 sha256: ${b_sha:0:16}"
echo "签名       : $(codesign -dv --verbose=2 "$APP" 2>&1 | awk -F= '/^Authority|^Identifier/{printf "%s ", $2}')"

if [ "$i_sha" != "$b_sha" ]; then
  echo "RESULT: STALE（装机与仓库 build 内容不同）"
  if [ "${1:-}" = "--install" ]; then
    echo "→ 自动安装…"
    bash scripts/install.sh || exit 4
    bash scripts/install-check.sh
    exit $?
  fi
  exit 1
fi
echo "RESULT: SYNC"
exit 0
