#!/bin/bash
# passive-selfcheck.sh — --passive 仪器自证（一条命令可复跑）
#
# 证明三件事：
#   1) 写回计数器是活的（正控：内存里 applyEdits 必须 +1）；
#   2) 只读阶段写回 / 剪贴板 / 窗口上屏全 0（走真实检查、渲染、悬停入口）；
#   3) 落盘日志每行七个必需字段齐全（ts/pid/app/role/textLen/rects/elapsed）。
#
# 附加静态不变量：源码里每个「让窗口上屏」的调用点都必须有 Audit.show() 打点，
# 否则计数会漏，自证就成了自述 —— 数量不等直接 FAIL。
#
# 全程不开窗口、不 activate、不截屏、不碰 Mail。
# 用法：bash scripts/passive-selfcheck.sh
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=build/passive-selfcheck-bin
OUT_JSON=qa/evidence/passive-selfcheck.json
OUT_LOG=out/passive-selfcheck-run.jsonl

echo "== 1/4 编译（只编，不打包、不签名）=="
mkdir -p build out qa/evidence
swiftc -O -swift-version 5 Sources/*.swift -o "$BIN" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices 2>build/passive-selfcheck-build.log
if [ ! -x "$BIN" ]; then echo "FAIL 编译失败（看 build/passive-selfcheck-build.log）"; exit 2; fi

echo "== 2/4 静态不变量：上屏调用点都要有 Audit.show() =="
SHOWS=$(grep -c "Audit.show()" Sources/*.swift | awk -F: '{s+=$2} END {print s+0}')
JUMPS=$(grep -hoE "orderFrontRegardless\(\)|makeKeyAndOrderFront\(nil\)" Sources/*.swift | wc -l | tr -d ' ')
if [ "$SHOWS" -ne "$JUMPS" ]; then
  echo "FAIL 上屏点 $JUMPS 个，Audit.show() 只有 $SHOWS 个 → 计数会漏"
  grep -n "orderFrontRegardless()\|makeKeyAndOrderFront(nil)" Sources/*.swift
  exit 3
fi
echo "OK 上屏点 $JUMPS 个 = Audit.show() $SHOWS 个"

echo "== 3/4 跑自证（真实检查/渲染/悬停入口 + 日志字段从磁盘读回）=="
"$BIN" --passive "$OUT_LOG" --selfcheck "$OUT_JSON"
RC=$?

echo "== 4/4 收尾 =="
if [ -f "$OUT_JSON" ]; then
  python3 - "$OUT_JSON" <<'PY'
import json,sys
p=sys.argv[1]; d=json.load(open(p))
print("pass =", d.get("pass"))
for r in d.get("results", []):
    print(("  PASS  " if r["pass"] else "  FAIL  ") + r["name"])
PY
  echo "证据：$OUT_JSON"
fi
exit $RC
