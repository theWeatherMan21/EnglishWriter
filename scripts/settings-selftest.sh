#!/bin/bash
# settings-selftest.sh — 设置面板验收（一条命令可复跑，不开窗口、不点 UI）
#
# 断言：
#   1) 零预设：全新域读回三件套全空、引擎地址/方言/排除走默认；
#   2) 保存后独立进程 `defaults read com.wanyi.englishwriter <key>` 冷读一致（六项）；
#   3) 个人词典加词后引擎侧同词 0 条、删词恢复；
#   4) App 排除：bundle id 与 应用名都命中，无关 App 不误伤。
#
# 产物：qa/evidence/settings-selftest.json（测试值，跑完已把原值还原）
# 用法：bash scripts/settings-selftest.sh
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=build/settings-selftest-bin
mkdir -p build out qa/evidence
echo "== 1/2 编译 =="
swiftc -O -swift-version 5 Sources/*.swift -o "$BIN" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices 2>build/settings-selftest-build.log
if [ ! -x "$BIN" ]; then echo "FAIL 编译失败（看 build/settings-selftest-build.log）"; exit 2; fi

echo "== 2/2 跑设置断言 =="
EW_SELFTEST_OUT="$PWD/out/settings-selftest.log" "$BIN" --selftest --settings
RC=$?
echo "证据：qa/evidence/settings-selftest.json"
exit $RC
