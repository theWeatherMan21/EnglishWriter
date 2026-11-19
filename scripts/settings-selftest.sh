#!/bin/bash
# settings-selftest.sh — 设置面板验收（一条命令可复跑，不开窗口、不点 UI、不联网）
#
# 断言（细节在 Sources/SelfTest.swift 的 settingsTests()，这里只负责跑 + 补静态不变量）：
#   1) 零预设：全新域读回三件套全空、引擎地址/方言/排除走默认；
#   2) 保存后独立进程 `defaults read com.wanyi.englishwriter <key>` 冷读一致（六项）；
#   3) 个人词典：本地 LT 与远端 diff 两条通道都对命中区间过滤（0 条），删词恢复；
#   4) App 排除：bundle id / 应用名都命中，无关 App 不误伤；三个挂载入口共用同一闸门；
#   5) 空配置：远端三条通道（diff / engine / rewrite）0 次网络请求（URLProtocol 打桩计数），
#      配置齐全时正控必须发出 1 次（证明计数器不是死代码）；
#   6) 方言换档后 /v2/check 的请求参数真的变；本次忽略只在内存、永久忽略落盘；
#   7) 调试 UI 门控：EW_DEBUG 未设时设置窗零调试区。
#
# 产物：qa/evidence/settings-selftest.json（断言 + UserDefaults 键表）· qa/evidence/settings-panel.png（面板截图）
# 用法：bash scripts/settings-selftest.sh
set -uo pipefail
cd "$(dirname "$0")/.."

BIN=build/settings-selftest-bin
mkdir -p build out qa/evidence

echo "== 1/4 编译 =="
swiftc -O -swift-version 5 Sources/*.swift -o "$BIN" \
    -framework AppKit -framework SwiftUI -framework ApplicationServices 2>build/settings-selftest-build.log
if [ ! -x "$BIN" ]; then echo "FAIL 编译失败（看 build/settings-selftest-build.log）"; exit 2; fi

echo "== 2/4 跑设置断言（不联网、不开窗）=="
EW_SELFTEST_OUT="$PWD/out/settings-selftest.log" "$BIN" --selftest --settings
RC=$?

echo "== 3/4 面板截图（离屏合成，用户真实配置零接触）=="
"$BIN" --settings-snapshot "$PWD/qa/evidence/settings-panel.png" || RC=1
[ -s "$PWD/qa/evidence/settings-panel.png" ] || { echo "FAIL 截图没生成"; RC=1; }

echo "== 4/4 静态不变量 =="
SFAIL=0
N_GATE=$(grep -c 'Self.excludedGate(pid:' Sources/Inline.swift || true)
if [ "$N_GATE" = "3" ]; then
    echo "PASS  排除闸门 3 个入口（attach-app / attach-el / checkNow）"
else
    echo "FAIL  排除闸门调用点 $N_GATE 处（应为 3）"; SFAIL=1
fi

N_FILTER=$(grep -l 'PersonalFilter.apply' Sources/*.swift | wc -l | tr -d ' ')
if [ "$N_FILTER" = "2" ]; then
    echo "PASS  词典/忽略过滤两条通道各一处（LocalEngine + Diff）"
else
    echo "FAIL  过滤接入点 $N_FILTER 处（应为 2）"; SFAIL=1
fi

if grep -q 'ignoreSession' Sources/CardWeb.swift && grep -q 'ignoreSession' web/card/index.html; then
    echo "PASS  卡片区分「本次忽略 / 不再提示」"
else
    echo "FAIL  卡片缺本次忽略入口"; SFAIL=1
fi
[ "$SFAIL" != "0" ] && RC=1

# 把这一轮的静态不变量与截图路径并进证据 JSON（不覆盖 Swift 写的断言）
N_GATE="$N_GATE" N_FILTER="$N_FILTER" SFAIL="$SFAIL" python3 - "$PWD/qa/evidence/settings-selftest.json" <<'PY'
import json, os, sys, time
path = sys.argv[1]
with open(path) as f:
    ev = json.load(f)
n_gate = int(os.environ["N_GATE"]); n_filter = int(os.environ["N_FILTER"])
ev["staticInvariants"] = {
    "exclusionGateCallSites": n_gate,
    "personalFilterCallSites": n_filter,
    "cardHasSessionIgnore": True,
}
snap = "qa/evidence/settings-panel.png"
if os.path.exists(snap):
    ev["snapshot"] = {"path": snap, "bytes": os.path.getsize(snap),
                      "mtime": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(os.path.getmtime(snap)))}
ev["pass"] = bool(ev.get("pass")) and n_gate == 3 and n_filter == 2 and os.environ["SFAIL"] == "0"
with open(path, "w") as f:
    json.dump(ev, f, ensure_ascii=False, indent=2, sort_keys=True)
print("证据：%s（pass=%s）" % (path, ev["pass"]))
PY

echo "截图：qa/evidence/settings-panel.png"
exit $RC
