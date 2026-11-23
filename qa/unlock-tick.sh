#!/bin/bash
# qa/unlock-tick.sh —— 单次 tick 版解锁自愈（供 cron 每 5 分钟调用）
#
# 为什么是单次：长循环版（unlock-watch.sh）作为会话子进程会被 SIGTERM（实测 exit -15，
# 连 persist_on_release 也保不住）。改成「cron 反复调用、每次只做一次判断、做完即退」。
#
# 输出契约（cron no_agent=true：stdout 非空才发送，空则不打扰）：
#   锁屏          → 输出空
#   已处理过      → 输出空
#   刚解锁未处理   → 输出结论（dump 摘要 + 还原结果）
#
# 幂等：marker 文件 qa/evidence/.unlock-done，做完就落，永不重复执行写操作。

set -u
cd "$(dirname "$0")/.." || exit 1
BIN=./build/英文写作助手
EVID=qa/evidence
MARK="$EVID/.unlock-done"
mkdir -p "$EVID"

locked() { ioreg -n Root -d1 -a 2>/dev/null | grep -q CGSSessionScreenIsLocked; }

# 锁屏什么都不做
locked && exit 0
# 已处理过就安静退出
[ -f "$MARK" ] && exit 0

# 刚解锁：先静 15 秒，避免跟他抢键盘
sleep 15
locked && exit 0

echo "== 解锁自愈 $(date '+%F %T') =="

# ① AX 树 dump
"$BIN" --axdump-mail > "$EVID/axdump-mail.txt" 2>&1
echo "--- ① AX 树 ---"
tail -5 "$EVID/axdump-mail.txt"
echo "可设选区的节点数: $(grep -c 'selSet=ok' "$EVID/axdump-mail.txt" 2>/dev/null || echo 0)"
echo "报谎的节点数:     $(grep -c 'selSet=谎' "$EVID/axdump-mail.txt" 2>/dev/null || echo 0)"

# ② 只在 dump 里确实有写信窗时才尝试还原
if grep -q 'AXTextArea\|message body' "$EVID/axdump-mail.txt" 2>/dev/null; then
    if [ -x /tmp/draft-fix ]; then
        /tmp/draft-fix > "$EVID/draft-fix.log" 2>&1
        echo "--- ② 草稿还原 dry-run ---"
        tail -4 "$EVID/draft-fix.log"
        if grep -q "RESULT: DRY-RUN" "$EVID/draft-fix.log"; then
            /tmp/draft-fix --apply >> "$EVID/draft-fix.log" 2>&1
            echo "--- apply 结果 ---"
            tail -3 "$EVID/draft-fix.log"
        else
            echo "dry-run 未通过，不 apply（宁可留着错，不冒险改坏）"
        fi
    else
        echo "--- ② 缺 /tmp/draft-fix，跳过还原 ---"
    fi
else
    echo "--- ② dump 里没有写信窗，跳过还原 ---"
fi

# 落 marker：同一解锁周期只做一次
date '+%F %T' > "$MARK"
echo "== 完成（marker 已落，不再重复）=="
