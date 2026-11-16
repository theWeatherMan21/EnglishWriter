#!/bin/bash
# ext-logic-probe.sh — 一条命令重跑「扩展逻辑层」端到端验收，产出 qa/evidence/ext-logic-probe.json
#
# 为什么需要它：证据必须可复跑。logic-probe.py 只是驱动脚本，它依赖「本地页 + 带调试端口的 Chrome」，
# 这里把这两样也自己拉起来、跑完收干净，任何人 clone 下来一条命令就能复现同一份证据。
#
# 前提：英文写作助手 App 在跑（提供 127.0.0.1:17817 + LanguageTool）
# 用法：bash scripts/ext-logic-probe.sh
set -uo pipefail
cd "$(dirname "$0")/.."

PORT_HTTP=8765
PORT_CDP=9224
PROFILE=$(mktemp -d /tmp/ew-logicprobe.XXXXXX)
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
OUT=qa/evidence/ext-logic-probe.json

cleanup() {
  [ -n "${CHROME_PID:-}" ] && kill "${CHROME_PID}" 2>/dev/null
  [ -n "${HTTP_PID:-}" ] && kill "${HTTP_PID}" 2>/dev/null
  wait 2>/dev/null
  rm -rf "${PROFILE}"
}
trap cleanup EXIT

echo "== 1/4 前置检查 =="
curl -s -o /dev/null -m 3 http://127.0.0.1:17817/v1/health || { echo "FAIL App 没在跑（127.0.0.1:17817 不通）"; exit 2; }
[ -f "$HOME/Library/Application Support/EnglishWriter/api-token.txt" ] || { echo "FAIL 没有 token 文件"; exit 2; }
[ -x "${CHROME}" ] || { echo "FAIL 没找到 Chrome"; exit 2; }

echo "== 2/4 起本地探针页（127.0.0.1:${PORT_HTTP}）=="
python3 -m http.server "${PORT_HTTP}" --bind 127.0.0.1 --directory qa/chrome-ext-probe >/tmp/ew-logicprobe-http.log 2>&1 &
HTTP_PID=$!
sleep 1
curl -s -o /dev/null -m 3 "http://127.0.0.1:${PORT_HTTP}/" || { echo "FAIL 探针页起不来"; exit 2; }

echo "== 3/4 起 Chrome（不带扩展，纯页面上下文）=="
"${CHROME}" --user-data-dir="${PROFILE}" --remote-debugging-port=${PORT_CDP} \
  --no-first-run --no-default-browser-check --window-size=1200,900 \
  "http://127.0.0.1:${PORT_HTTP}/" >/tmp/ew-logicprobe-chrome.log 2>&1 &
CHROME_PID=$!
for i in $(seq 1 20); do
  sleep 0.5
  curl -s -m 2 "http://127.0.0.1:${PORT_CDP}/json/version" >/dev/null 2>&1 && break
done

echo "== 4/4 跑逻辑层验收 =="
python3 qa/chrome-ext-probe/logic-probe.py --port ${PORT_CDP}
RC=$?

if [ -f qa/chrome-ext-probe/logic-probe-report.json ]; then
  cp qa/chrome-ext-probe/logic-probe-report.json "$OUT"
  echo "证据：$OUT"
fi
exit $RC
