#!/bin/bash
# baseline.sh — 重建视觉基线（只有在「确认这次改动是想要的」之后才跑）
# 基线是图，进仓库；改动要跟着提交一起进，review 时看得出改了哪块。
set -euo pipefail
cd "$(dirname "$0")/.."
BIN="build/英文写作助手"
[ -x "$BIN" ] || { echo "先 bash scripts/build.sh"; exit 1; }
mkdir -p qa/baseline
"$BIN" --settings-snapshot qa/baseline/settings-panel.png >/dev/null
"$BIN" --ball-snapshot qa/baseline/ball-states.png >/dev/null
"$BIN" --sidebar-snapshot qa/baseline/sidebar-panel.png >/dev/null
ls -l qa/baseline/*.png
echo "基线已更新：记得 git add qa/baseline"
