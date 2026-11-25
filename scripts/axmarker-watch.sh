#!/bin/bash
# 等解锁 + Mail 有窗口 → 跑一次 --axmarker-probe → 写证据 → 退出。
# 只读：不建窗、不激活、不敲键。最长 6 小时。
set -u
APP=/Users/russospencer/dev/EnglishWriter/build/英文写作助手
OUT=/Users/russospencer/dev/EnglishWriter/qa/evidence
TS=$(date +%Y%m%d-%H%M%S)
LOG="$OUT/axmarker-probe-$TS.log"
mkdir -p "$OUT"
exec >>"$LOG" 2>&1
echo "等待解锁… start=$(date '+%F %T') pid=$$"

# 不用 PyObjC（本机没装）：IOConsoleLocked 就是锁屏状态
locked() {
  if ioreg -n Root -d1 2>/dev/null | grep -q '"IOConsoleLocked" = Yes'; then echo 1; else echo 0; fi
}

windows() {
  osascript -e 'tell application "Mail" to count of windows' 2>/dev/null || echo 0
}

for i in $(seq 1 720); do     # 720 × 30s = 6h
  if [ "$(locked)" = "0" ] && [ "$(windows)" -gt 0 ]; then
    echo "解锁且 Mail 有窗口（$(windows) 个）→ 跑探针 $(date '+%F %T')"
    "$APP" --axmarker-probe
    echo "RESULT_LINE_END $(date '+%F %T')"
    exit 0
  fi
  sleep 30
done
echo "TIMEOUT 6 小时未等到「解锁 + Mail 有窗口」，退出"
exit 3
