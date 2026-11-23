#!/bin/bash
# soak.sh — 长跑观测：常驻 App 的内存 / CPU / 线程 / 日志体量 / 新崩溃
#
# 用法：
#   bash scripts/soak.sh                 # 采 5 次，每 60 秒一次，结果打到屏幕
#   bash scripts/soak.sh 120 30          # 采 30 次，每 120 秒一次（=1 小时）
#   bash scripts/soak.sh 60 10 --json    # 同上，但只写 qa/evidence/soak.jsonl
#
# 判据（任何一条触发就明确报警，不靠人盯）：
#   · RSS 相对首次采样涨 > 50%           → 疑似泄漏
#   · 线程数涨 > 100%                    → 疑似任务堆积
#   · 日志 > 6MB 且没有 .1 轮转文件      → 轮转失效
#   · 期间新增 英文写作助手-*.ips        → 崩溃（附栈顶）
set -uo pipefail
cd "$(dirname "$0")/.."

INTERVAL="${1:-60}"
COUNT="${2:-5}"
MODE="${3:-}"
APP_NAME="英文写作助手"
OUT="qa/evidence/soak.jsonl"
LOG="$HOME/Library/Application Support/EnglishWriter/check-log.jsonl"
CRASH_DIRS=("$HOME/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports/Retired")

pid_of() { pgrep -f "/Applications/Selfmade/$APP_NAME.app/Contents/MacOS/$APP_NAME" | head -1; }

crashes() {
    local n=0
    for d in "${CRASH_DIRS[@]}"; do
        [ -d "$d" ] || continue
        n=$((n + $(find "$d" -maxdepth 1 -name "$APP_NAME-*.ips" 2>/dev/null | wc -l | tr -d ' ')))
    done
    echo "$n"
}

first_rss=""; first_thr=""; first_crash="$(crashes)"; problems=""

for i in $(seq 1 "$COUNT"); do
    pid="$(pid_of)"
    if [ -z "$pid" ]; then
        echo "[soak] 第 $i 次：常驻实例不在（跳过这一拍）"
        sleep "$INTERVAL"
        continue
    fi
    rss=$(ps -o rss= -p "$pid" | tr -d ' ')
    cpu=$(ps -o pcpu= -p "$pid" | tr -d ' ')
    thr=$(ps -M -p "$pid" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
    logsize=$([ -f "$LOG" ] && stat -f%z "$LOG" || echo 0)
    rot=0; [ -f "$LOG.1" ] || [ -f "$(dirname "$LOG")/check-log.1.jsonl" ] && rot=1
    crash_now=$(crashes)

    [ -z "$first_rss" ] && { first_rss=$rss; first_thr=$thr; }
    line="{\"at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"pid\":$pid,\"rssKB\":$rss,\"cpu\":$cpu,\"threads\":$thr,\"logBytes\":$logsize,\"rotated\":$rot,\"crashes\":$crash_now}"

    if [ -n "$MODE" ] && [ "$MODE" = "--json" ]; then
        echo "$line" >> "$OUT"
    else
        printf '[soak] %2d/%d  rss=%6sKB cpu=%5s%% 线程=%3s 日志=%7s B 崩溃=%s\n' \
            "$i" "$COUNT" "$rss" "$cpu" "$thr" "$logsize" "$crash_now"
    fi

    # 判据
    if [ "$first_rss" -gt 0 ] && [ "$rss" -gt $((first_rss * 3 / 2)) ]; then
        problems="$problems\n  ! RSS 从 ${first_rss}KB 涨到 ${rss}KB（>50%）"
    fi
    if [ "$first_thr" -gt 0 ] && [ "$thr" -gt $((first_thr * 2)) ]; then
        problems="$problems\n  ! 线程从 ${first_thr} 涨到 ${thr}（>100%）"
    fi
    if [ "$logsize" -gt 6000000 ] && [ "$rot" = "0" ]; then
        problems="$problems\n  ! 日志 ${logsize} B 且没轮转文件"
    fi
    if [ "$crash_now" -gt "$first_crash" ]; then
        problems="$problems\n  ! 期间新增崩溃 $((crash_now - first_crash)) 份（见 $HOME/Library/Logs/DiagnosticReports）"
    fi

    [ "$i" -lt "$COUNT" ] && sleep "$INTERVAL"
done

if [ -n "$problems" ]; then
    echo -e "[soak] 发现问题：$problems"
    exit 1
fi
echo "[soak] 完成：${COUNT} 拍无异常（RSS/线程/日志/崩溃 均在阈值内）"
