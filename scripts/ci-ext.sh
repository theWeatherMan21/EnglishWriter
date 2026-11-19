#!/usr/bin/env bash
# ci-ext.sh — 扩展端到端验收（真 Chrome + 真 CDP，默认 headless，不弹窗）
#
# 跑三件事：
#   1) 点线弹卡 → 接受写回正文
#   2) 键盘 → / ← / Esc
#   3) 改写入口在「模型未配置」时给诚实文案
#
# 用法：bash scripts/ci-ext.sh
# 前置：App 常驻实例在跑（扩展要 token 与检查接口）；脚本会自己起/停 Chrome for Testing。
set -euo pipefail
cd "$(dirname "$0")/.."

PORT="${EW_CDP_PORT:-9333}"

cleanup() { bash scripts/chrome-testing-up.sh stop >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "--- 扩展端到端验收 (port ${PORT}) ---"
bash scripts/chrome-testing-up.sh launch ${PORT} >/dev/null 2>&1
sleep 3

FAIL=0
python3 qa/chrome-ext-probe/click_probe.py --port ${PORT} || FAIL=1
python3 qa/chrome-ext-probe/keyboard_probe.py --port ${PORT} || FAIL=1
python3 qa/chrome-ext-probe/ce_probe.py --port ${PORT} || FAIL=1

if [ "$FAIL" = "0" ]; then
    echo "=== 扩展验收：全部通过 ==="
else
    echo "=== 扩展验收：有失败项（见上）==="
fi
exit "$FAIL"
