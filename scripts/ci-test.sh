#!/bin/bash
# ci-test.sh — CI / 无证书环境用：只编译 + 跑不依赖本地引擎的自测
# 不打包 .app、不碰证书（GitHub runner 上没 "SOALedger Dev"）
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
BIN="build/ci-selftest"

echo "== 编译 =="
swiftc -O -swift-version 5 Sources/*.swift -o "$BIN" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices -framework NaturalLanguage 2>&1 \
    | grep -E "error:" && { echo "编译失败"; exit 1; } || true

echo "== 自测（门控 / 护栏 / diff 契约 / M3 / M3.3 合并去重 / 设置面板）=="
EW_OUT="$PWD/out" "$BIN" --selftest --m3 --settings

echo "== 本地规则：清晰度/风格 + 语法兜底（含反例，防误报回潮）=="
EW_OUT="$PWD/out" "$BIN" --selftest --style || { echo "本地规则断言失败"; exit 1; }

echo "== 浮动球三态（灰=不知道 / 绿=没问题 / 数字=N 条）=="
EW_OUT="$PWD/out" "$BIN" --ball-snapshot "$PWD/qa/evidence/ball-states.png" \
    && [ -s "$PWD/qa/evidence/ball-states.png" ] || { echo "球态快照失败"; exit 1; }

echo "== 行内几何断言（真 NSTextView + AX 交叉校验）=="
"$BIN" --demo-selfcheck

echo "== WebView UI（离屏断言，无窗口）=="
"$BIN" --webui || { echo "WebView UI 断言失败"; exit 1; }

echo "== 装机版 vs 仓库 build（旧则拦，别让爹地点到旧二进制）=="
if [ -x "/Applications/Selfmade/英文写作助手.app/Contents/MacOS/英文写作助手" ]; then
    bash scripts/install-check.sh || { echo "装机版落后仓库 build：先 bash scripts/install.sh"; exit 1; }
else
    echo "（本机未安装，跳过；CI 机器不装 App 属正常）"
fi

echo "全部通过"
