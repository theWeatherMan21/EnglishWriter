#!/bin/bash
# idle-cpu-sample.sh — DoD 取证：空闲 5 分钟，每 10s 采一次 %cpu，共 30 次
# 用法：./scripts/idle-cpu-sample.sh [pid]
set -uo pipefail
cd "$(dirname "$0")/.."
mkdir -p out
PID="${1:-$(pgrep -x "英文写作助手" | head -1)}"
if [ -z "${PID:-}" ]; then echo "找不到进程：先启动 App"; exit 1; fi

OUT="out/idle-cpu.txt"
: > "$OUT"
echo "# pid=$PID start=$(date '+%F %T')" >> "$OUT"
for i in $(seq 1 30); do
  c=$(ps -o %cpu= -p "$PID" 2>/dev/null | tr -d ' ')
  echo "$(date +%H:%M:%S) ${c:-0}" >> "$OUT"
  [ "$i" -lt 30 ] && sleep 10
done
tail -30 "$OUT" | awk 'NF==2{s+=$2;n++} END{if(n>0) printf "samples=%d mean=%.3f%%\n", n, s/n}' | tee -a "$OUT"
