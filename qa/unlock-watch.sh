#!/bin/bash
# qa/unlock-watch.sh —— 等解锁，一解锁就做两件已定的事（不再等爹地发话）
#   ① dump Mail 的 AX 树（判断到底哪个节点接受输入）
#   ② 精确还原被写坏的草稿（只删多出来的字符，绝不 ⌘A 全选）
#
# 为什么要有这个：11-23 屏幕从 18:06 起锁着，锁屏时 AX 树只剩骨架，
# 「找不到可编辑容器」这类结论全是假象。等他解锁再测，人手轮询没意义。
#
# 安全：
#   · 锁着就什么都不做（不键击、不点击）
#   · 解锁后先静 20 秒，避免跟他抢键盘
#   · 草稿修正先 dry-run，确认「要删的就是那 5 个字符」才 --apply
#   · 每一步结论都落盘到 qa/evidence/

set -u
cd "$(dirname "$0")/.." || exit 1

# 单实例锁：两个 watcher 同时跑会重复 dump、重复键击（11-23 实际发生过，34531 + 36549）。
# 拿不到锁就直接退出——宁可不动，也不能两个人同时改同一封草稿。
# macOS 没有 flock（util-linux 才有）。用 mkdir 的原子性做锁；
# 锁里放 pid，发现持有者已经死了就接管，避免死锁。
LOCKDIR=/tmp/ew-unlock-watch.lockdir
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    OLD=$(cat "$LOCKDIR/pid" 2>/dev/null || echo 0)
    if [ "$OLD" != "0" ] && kill -0 "$OLD" 2>/dev/null; then
        echo "已有 watcher 在跑(pid=$OLD)，本实例退出"
        exit 0
    fi
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR" 2>/dev/null || { echo "拿不到锁，退出"; exit 0; }
fi
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM
BIN=./build/英文写作助手
FIX=/tmp/draft-fix
EVID=qa/evidence
mkdir -p "$EVID"
OUT="$EVID/unlock-watch.log"
: > "$OUT"

locked() { ioreg -n Root -d1 -a 2>/dev/null | grep -q CGSSessionScreenIsLocked; }

echo "== 等解锁（最多 12 小时，每 30 秒看一次）== $(date '+%F %T')" >> "$OUT"
for i in $(seq 1 1440); do
    if ! locked; then
        echo "解锁了 $(date '+%F %T')，静 20 秒再做" >> "$OUT"
        sleep 20
        if locked; then echo "又锁上了，继续等" >> "$OUT"; continue; fi

        TS=$(date '+%Y%m%d-%H%M%S')
        echo "--- ① AX 树 dump（${TS}）---" >> "$OUT"
        "$BIN" --axdump-mail > "$EVID/axdump-mail-$TS.txt" 2>&1
        tail -3 "$EVID/axdump-mail-$TS.txt" >> "$OUT"
        grep -c "edit=1\|selRange=1" "$EVID/axdump-mail-$TS.txt" 2>/dev/null \
            | sed 's/^/可编辑或可选区节点数：/' >> "$OUT"

        echo "--- ② 草稿还原（先 dry-run）---" >> "$OUT"
        if [ -x "$FIX" ]; then
            "$FIX" > "$EVID/draft-fix-$TS.log" 2>&1
            tail -4 "$EVID/draft-fix-$TS.log" >> "$OUT"
            if grep -q "RESULT: DRY-RUN" "$EVID/draft-fix-$TS.log"; then
                echo "dry-run 通过，执行还原" >> "$OUT"
                "$FIX" --apply >> "$EVID/draft-fix-$TS.log" 2>&1
                tail -3 "$EVID/draft-fix-$TS.log" >> "$OUT"
            else
                echo "dry-run 没就绪（没窗口 / 没找到坏文本），不执行" >> "$OUT"
            fi
        else
            echo "缺 /tmp/draft-fix，跳过还原" >> "$OUT"
        fi
        echo "== 完成 $(date '+%F %T')" >> "$OUT"
        exit 0
    fi
    sleep 30
done
echo "== 超时：12 小时都没解锁，放弃 $(date '+%F %T')" >> "$OUT"
exit 1
