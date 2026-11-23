#!/bin/bash
# ci-test.sh — CI / 无证书环境用：只编译 + 跑不依赖本地引擎的自测
# 不打包 .app、不碰证书（GitHub runner 上没 "SOALedger Dev"）
set -euo pipefail
cd "$(dirname "$0")/.."


# 每组超时：卡住就是 FAIL（不是「等等看」）；macOS 27 自带 /usr/bin/timeout
TMO_BIN=""
for c in /usr/bin/timeout /usr/local/bin/timeout /opt/homebrew/bin/gtimeout; do
    [ -x "$c" ] && { TMO_BIN="$c"; break; }
done
runT() {   # runT <秒> <命令...>
    local secs="$1"; shift
    if [ -n "$TMO_BIN" ]; then "$TMO_BIN" "$secs" "$@"; else "$@"; fi
    local rc=$?
    if [ "$rc" = "124" ]; then echo "FAIL  超时 ${secs}s：$*"; exit 1; fi
    return $rc
}

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
# Mail 块路径离屏验收（不碰真实 Mail）：建议>0、每条反查得到块、矩形在窗口内、同词去重、上限 20
"$BIN" --mail-selftest || { echo "Mail 块路径验收失败"; exit 1; }
# 业务英文质量回归：真实航运邮件的错例召回 ≥80%，正确句零误报
"$BIN" --quality || { echo "业务英文质量回归失败"; exit 1; }

echo "== 设置面板截图（离屏合成，用户配置零接触）=="
"$BIN" --settings-snapshot "$PWD/qa/evidence/settings-panel.png" \
    && [ -s "$PWD/qa/evidence/settings-panel.png" ] || { echo "设置面板截图失败"; exit 1; }

echo "== 浮动球三态（灰=不知道 / 绿=没问题 / 数字=N 条）=="
EW_OUT="$PWD/out" "$BIN" --ball-snapshot "$PWD/qa/evidence/ball-states.png" \
    && [ -s "$PWD/qa/evidence/ball-states.png" ] || { echo "球态快照失败"; exit 1; }

echo "== 行内几何断言（真 NSTextView + AX 交叉校验）=="
"$BIN" --demo-selfcheck

echo "== WebView UI（离屏断言，无窗口）=="
"$BIN" --webui || { echo "WebView UI 断言失败"; exit 1; }

echo "== 隐私 / 门控断言（--privacy）=="
runT 120 "$BIN" --privacy || { echo "privacy 断言失败"; exit 1; }

echo "== 改写纯函数（--rewrite-selftest：边界空格 / 错位 span / 去重 / WordDiff 往返）=="
runT 120 "$BIN" --rewrite-selftest || { echo "改写纯函数断言失败"; exit 1; }

echo "== 接受/撤销闭环 + 忽略词典（--acceptflow）=="
runT 120 "$BIN" --acceptflow || { echo "写回闭环断言失败"; exit 1; }

echo "== 点击几何诊断（--clickdiag）=="
runT 120 "$BIN" --clickdiag || { echo "点击几何断言失败"; exit 1; }

echo "== 业务英文深度回归（--quality --deep：召回 100% + 正确句零误报）=="
# NO_BUILD / NO_GOLD 不是通过，是没跑：必须见到 RESULT: PASS
DEEP_OUT=$(runT 300 "$BIN" --quality --deep 2>&1); DEEP_RC=$?
echo "$DEEP_OUT" | grep -E "^(PASS|FAIL|RESULT)|平均耗时" | tail -4
if echo "$DEEP_OUT" | grep -qE "NO_BUILD|NO_GOLD|跳过"; then
    echo "deep 质量回归未覆盖（NO_BUILD / NO_GOLD / 跳过 都算没跑，不是绿）"; exit 1
fi
[ "$DEEP_RC" -eq 0 ] || { echo "deep 质量回归失败（exit $DEEP_RC）"; exit 1; }

echo "== 崩溃防线：运行路径里禁止 MainActor.assumeIsolated =="
# 本机 8 份崩溃报告都是 Inline.start() 的 AppKit 通知闭包里 assumeIsolated 直接崩
# （切 App 时随机崩）。CLI 探针/SelfTest/main 允许，运行路径一律不许。
BAD_AI=$(grep -rn 'MainActor\.assumeIsolated[[:space:]]*[{(]' Sources/*.swift \
    | grep -vE 'Sources/(M3MonitorProbe|SelfTest|main)\.swift' || true)
if [ -n "$BAD_AI" ]; then
    echo "$BAD_AI"
    echo "运行路径里出现 MainActor.assumeIsolated：通知闭包里会崩，改 Thread.isMainThread + DispatchQueue.main"
    exit 1
fi
echo "PASS  运行路径零 assumeIsolated"

echo "== 阈值口径防线：CJK 比例只许有 LanguageGate.cjkGate 一个来源 =="
DUP_CJK=$(grep -rnE "(cjk|CJK)[^\n]*(>|>=)[[:space:]]*0\.[0-9]+" Sources/*.swift \
    | grep -v "Sources/LanguageGate.swift" \
    | grep -v "LanguageGate\\.cjkGate" \
    | grep -v "abs(" || true)
if [ -n "$DUP_CJK" ]; then
    echo "$DUP_CJK"
    echo "重复的 CJK 阈值：改用 LanguageGate.cjkGate（11-23 已有四个副本，中文被送进 LT 就是这么来的）"
    exit 1
fi
echo "PASS  CJK 阈值单一来源"

echo "== 坐标口径防线：除 Geometry.swift 外不许手写坐标换算 =="
# 爹地 11-19 实报「悬浮点到处乱飘」：FloatBall 自己写了 h - p.y - size，
# 用的是球所在屏的高度而不是全局 topOffset，单屏看不出来、接副屏必飘。
BAD_GEO=$(grep -rnE '(frame\.height|screens\[0\]\.frame\.height)[[:space:]]*[-+]' Sources/*.swift \
    | grep -v 'Sources/Geometry.swift' || true)
if [ -n "$BAD_GEO" ]; then
    echo "$BAD_GEO"
    echo "手写坐标换算：请改用 ScreenGeom.toAppKit / toQuartz（全局 topOffset 口径）"
    exit 1
fi
echo "PASS  坐标换算只走 ScreenGeom"

echo "== 视觉基线 diff（改 CSS 就看得出跑没跑版）=="
BASELINE="$PWD/qa/baseline"
if [ -d "$BASELINE" ]; then
    # 先删再生成：生成失败时旧文件还在，会拿「旧证据 vs 基线」比出 0.000% 的假绿
    rm -f "$PWD/qa/evidence/settings-panel.png" "$PWD/qa/evidence/ball-states.png" "$PWD/qa/evidence/sidebar-panel.png"
    "$BIN" --settings-snapshot "$PWD/qa/evidence/settings-panel.png" >/dev/null 2>&1 || true
    "$BIN" --ball-snapshot "$PWD/qa/evidence/ball-states.png" >/dev/null 2>&1 || true
    "$BIN" --sidebar-snapshot "$PWD/qa/evidence/sidebar-panel.png" >/dev/null 2>&1 || true
    for f in settings-panel ball-states sidebar-panel; do
        [ -s "$PWD/qa/evidence/$f.png" ] || { echo "FAIL  快照生成失败：${f}.png"; exit 1; }
    done
    for n in settings-panel ball-states sidebar-panel; do
        if [ -s "$BASELINE/$n.png" ]; then
            "$BIN" --pngdiff "$BASELINE/$n.png" "$PWD/qa/evidence/$n.png" \
                --threshold 0.001 --out "$PWD/qa/evidence/$n-diff.png" \
                || { echo "视觉基线变化：${n}（差异图 qa/evidence/$n-diff.png；确认是预期改动就 bash scripts/baseline.sh 更新）"; exit 1; }
        else
            echo "SKIP  视觉基线 ${n} 不存在（先跑 bash scripts/baseline.sh 建基线）"
        fi
    done
else
    echo "SKIP  视觉基线目录不存在（先跑 bash scripts/baseline.sh）"
fi

echo "== KPI（画线率 / 点击命中 / 日志完整性；只报不拦）=="
"$BIN" --kpi | tail -3 || true

if [ "${EW_WITH_LIVE:-0}" = "1" ]; then
    echo "== 真模型（--live-rewrite 5 句 × 3 轮 / --live-tone）=="
    "$BIN" --live-rewrite || { echo "真模型改写失败"; exit 1; }
fi

echo "== Safari 扩展外壳（.appex 构建 + 签名 + 结构校验）=="
if bash scripts/safari-appex.sh > /tmp/ci-safari.log 2>&1; then
  grep -E "^OK|^RESULT: READY" /tmp/ci-safari.log
else
  echo "FAIL Safari 扩展外壳构建"
  tail -12 /tmp/ci-safari.log
  exit 1
fi

echo "== 浏览器扩展端到端（headless Chrome + CDP：点线弹卡 / 键盘 / contenteditable）=="
CFT_BIN="$PWD/.tools/chrome-for-testing/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
if [ -x "$CFT_BIN" ] || bash scripts/chrome-testing-up.sh prepare >/dev/null 2>&1; then
    bash scripts/ci-ext.sh || { echo "扩展端到端验收失败"; exit 1; }
else
    # 缺 Chrome for Testing 时明确记 SKIP，不许静默混成绿；CI 里要它必须跑就设 EW_CI_REQUIRE_EXT=1
    if [ "${EW_CI_REQUIRE_EXT:-0}" = "1" ]; then
        echo "FAIL  扩展端到端未跑：本机没有 Chrome for Testing"; exit 1
    fi
    echo "SKIP  扩展端到端：本机没有 Chrome for Testing（不影响原生断言）"
fi

echo "== 崩溃报告扫描（断言只覆盖写到的路径，崩溃报告才覆盖真实使用）=="
CRASH_DIRS="$HOME/Library/Logs/DiagnosticReports $HOME/Library/Logs/DiagnosticReports/Retired"
NEW_IPS=""
for base in build/英文写作助手.app/Contents/MacOS/英文写作助手 "$BIN"; do
    [ -f "$base" ] || continue
    for d in $CRASH_DIRS; do
        [ -d "$d" ] || continue
        hit=$(find "$d" -maxdepth 1 \( -name '英文写作助手-*.ips' -o -name 'ci-selftest-*.ips' \) -newer "$base" 2>/dev/null)
        [ -n "$hit" ] && NEW_IPS="$NEW_IPS$hit\n"
    done
done
if [ -n "$NEW_IPS" ]; then
    echo -e "$NEW_IPS" | sed '/^$/d' | while read -r f; do
        echo "  新崩溃报告：$f"
        python3 - "$f" <<'PYEOF' || true
import json,sys
try:
    txt=open(sys.argv[1],errors="replace").read()
    head,_,body=txt.partition("\n")
    b=json.loads(body); imgs=b.get("usedImages",[])
    for t in b.get("threads",[]):
        if t.get("triggered"):
            for fr in t.get("frames",[])[:8]:
                i=fr.get("imageIndex",0)
                print("   ", (imgs[i].get("name") if i<len(imgs) else "?"), "|", fr.get("symbol","")[:70])
            break
except Exception as e:
    print("   （解析失败）", e)
PYEOF
    done
    echo "FAIL  上次构建之后有新的崩溃报告（上面是栈顶）"; exit 1
fi
echo "PASS  上次构建之后零新崩溃报告"

echo "== 装机版 vs 仓库 build（旧则拦，别让爹地点到旧二进制）=="
if [ -x "/Applications/Selfmade/英文写作助手.app/Contents/MacOS/英文写作助手" ]; then
    bash scripts/install-check.sh || { echo "装机版落后仓库 build：先 bash scripts/install.sh"; exit 1; }
else
    echo "（本机未安装，跳过；CI 机器不装 App 属正常）"
fi

# 断言会写 qa/evidence/*.json（运行产物）。收尾把已跟踪的证据文件恢复到 HEAD，
# 免得每跑一次测试就多出一个「刷新证据」的提交（知澜 11-19 指出的流程噪音）。
# 真要把新证据入库：跑完自己 git add qa/evidence/<file>。
git checkout -- qa/evidence 2>/dev/null || true

echo "全部通过"
