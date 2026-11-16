#!/bin/bash
# ext-real-probe.sh — 真扩展端到端验收（Chrome for Testing + --load-extension）
#
# 与 ext-logic-probe.sh 的区别（这条很重要，别混）：
#   · ext-logic-probe.sh 把 content.js 注入页面主世界 → 只证明「逻辑对」，算 R2
#   · 本脚本用 Chrome for Testing 真正装载扩展，content script 跑在 isolated world →
#     证明「扩展本身能用」，算 R1
#
# 用法：bash scripts/ext-real-probe.sh [cdpPort] [httpPort]
# 产物：qa/evidence/ext-real-probe.json
set -uo pipefail
cd "$(dirname "$0")/.."

CDP_PORT="${1:-9333}"
HTTP_PORT="${2:-8765}"
OUT=qa/evidence/ext-real-probe.json

echo "== 1/4 准备 Chrome for Testing =="
bash scripts/chrome-testing-up.sh prepare || exit 2
curl -s -o /dev/null -m 3 http://127.0.0.1:17817/v1/health || { echo "FAIL App 没在跑"; exit 2; }

echo "== 2/4 装载扩展并起浏览器 =="
bash scripts/chrome-testing-up.sh stop >/dev/null 2>&1
bash scripts/chrome-testing-up.sh launch "$CDP_PORT" "$HTTP_PORT" || exit 3
for i in $(seq 1 20); do sleep 0.5; curl -s -m 2 "http://127.0.0.1:$CDP_PORT/json/list" >/dev/null 2>&1 && break; done

echo "== 3/4 跑真扩展断言（isolated world）=="
python3 qa/chrome-ext-probe/drive.py --port "$CDP_PORT"
RC=$?

echo "== 4/4 收尾 =="
if [ -f qa/chrome-ext-probe/ext-probe-report.json ]; then
  cp qa/chrome-ext-probe/ext-probe-report.json "$OUT"
  echo "证据：$OUT"
fi
bash scripts/chrome-testing-up.sh stop >/dev/null 2>&1
exit $RC
