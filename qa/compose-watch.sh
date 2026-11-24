#!/bin/bash
# qa/compose-watch.sh —— 等爹地开写信窗，一出现就自己跑完整链路（不再要他点任何按钮）
#
# 做三件事，全带时间戳落盘：
#   ① --axdump-mail  → qa/evidence/axdump-mail-<ts>.txt   （R1 原始件）
#   ② --accept-now 0 --expect "send" → 写回 + 读回验证
#   ③ 抓 check-round / accept-* / write-layer 日志 → qa/evidence/accept-now-<ts>.log
#
# 安全：
#   · 只在「Mail 有窗口 且 compose 判定成立 且 正文含 have send」时才动手
#   · --expect 保证只接受那一条指定建议，别的一律不碰
#   · 屏幕锁着就什么都不做；单实例锁，避免两个 watcher 同时改同一封草稿
#   · 最多等 6 小时

set -u
cd "$(dirname "$0")/.." || exit 1
BIN=./build/英文写作助手
EVID=qa/evidence
OUT="$EVID/compose-watch.log"
NEEDLE="${EW_WATCH_NEEDLE:-have send the file}"
mkdir -p "$EVID"

LOCKDIR=/tmp/ew-compose-watch.lockdir
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OLD=$(cat "$LOCKDIR/pid" 2>/dev/null || echo 0)
    if [ "$OLD" != "0" ] && kill -0 "$OLD" 2>/dev/null; then
        echo "已有 compose-watch 在跑(pid=$OLD)，本实例退出"; exit 0
    fi
    rm -rf "$LOCKDIR"; mkdir "$LOCKDIR" 2>/dev/null || { echo "拿不到锁"; exit 0; }
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM

LOCKED=0
locked() { ioreg -n Root -d1 -a 2>/dev/null | grep -q CGSSessionScreenIsLocked; }

echo "== compose-watch 开始 $(date '+%F %T') ==" >> "$OUT"
for i in $(seq 1 1440); do
    if locked; then sleep 30; continue; fi
    probe=$("$BIN" --probe-mail 2>&1)
    if echo "$probe" | grep -q "信号=true" && echo "$probe" | grep -q "have send"; then
        sleep 3     # 等爹地停手
        TS=$(date '+%Y%m%d-%H%M%S')
        echo "--- 命中写信窗含「${NEEDLE}」 @ ${TS} ---" >> "$OUT"
        "$BIN" --axdump-mail > "$EVID/axdump-mail-$TS.txt" 2>&1
        tail -1 "$EVID/axdump-mail-$TS.txt" >> "$OUT"
        RUN="$EVID/accept-now-$TS.log"
        "$BIN" --accept-now 0 --expect "$NEEDLE" > "$RUN" 2>&1
        tail -6 "$RUN" >> "$OUT"
        # 先判成功（此时 RUN 里只有本次输出），再追加历史日志——
        # 反过来会命中历史行里的旧 ok，10:17 就是这么假成功的。
        SUCCESS=0
        grep -q "accept(itemID: 0) → ok" "$RUN" && SUCCESS=1
        grep -a "accept-\|web-write\|write-layer\|focus-return\|clipboard 前置\|整段替换前置\|keyboard-all" \
            ~/Library/Logs/EnglishWriter/app.log | tail -12 >> "$EVID/accept-now-$TS.log"
        # 成功判据：accept 真返回 ok（写回并读回通过）。没成就不退出，继续等下一次——
        # 窗口在他手里开开关关，抢到一次失败就收工等于白等（09:14 那次就是这样）。
        if [ "$SUCCESS" = "1" ]; then
            echo "== 成功，结束 $(date '+%F %T') ==" >> "$OUT"
            exit 0
        fi
        echo "--- 这次没成（窗口可能被关/建议未出），60 秒后再看 ---" >> "$OUT"
        sleep 60
    fi
    sleep 15
done
echo "== 超时 6 小时没等到写信窗 $(date '+%F %T') ==" >> "$OUT"
exit 1
