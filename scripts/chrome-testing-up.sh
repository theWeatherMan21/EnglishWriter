#!/bin/bash
# chrome-testing-up.sh — 下载/启动 Chrome for Testing（能 --load-extension 的那个版本）
#
# 为什么需要它：本机 Google Chrome 156 已移除 --load-extension（实测扩展 id 打不开），
# 但 Chrome for Testing 保留该能力 —— 自动化验收「真扩展」只能用它。
# 权威来源：googlechromelabs.github.io/chrome-for-testing（官方 Stable 清单）
#
# 用法：
#   bash scripts/chrome-testing-up.sh prepare        # 只准备二进制（幂等）
#   bash scripts/chrome-testing-up.sh launch [port] [httpPort]   # 起（装了扩展）
#   bash scripts/chrome-testing-up.sh stop           # 收干净
set -uo pipefail
cd "$(dirname "$0")/.."

TOOLS=".tools"
CFT_DIR="$TOOLS/chrome-for-testing"
UA_PROFILE="/tmp/ew-cft-profile"
CMD="${1:-prepare}"

manifest_url="https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json"

prepare() {
  if [ -x "$CFT_DIR/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" ]; then
    echo "已就绪：$CFT_DIR"
    return 0
  fi
  mkdir -p "$TOOLS"
  echo "== 拉官方 Stable 清单 =="
  curl -s -m 30 "$manifest_url" -o "$TOOLS/cft.json" || { echo "FAIL 清单拉不下来"; return 2; }
  url=$(python3 -c "
import json;d=json.load(open('$TOOLS/cft.json'))
st=d['channels']['Stable']
print(next(i['url'] for i in st['downloads']['chrome'] if i['platform']=='mac-arm64'))
")
  echo "版本 $(python3 -c "import json;print(json.load(open('$TOOLS/cft.json'))['channels']['Stable']['version'])")"
  ver=$(python3 -c "import json;print(json.load(open('$TOOLS/cft.json'))['channels']['Stable']['version'])")
  mirror="https://cdn.npmmirror.com/binaries/chrome-for-testing/$ver/mac-arm64/chrome-mac-arm64.zip"
  echo "下载（先试 npmmirror，失败再回官方）：$mirror"
  if ! curl -L --fail -m 900 "$mirror" -o "$TOOLS/cft.zip"; then
    echo "镜像失败，回退官方：$url"
    curl -L --fail -m 1800 "$url" -o "$TOOLS/cft.zip" || { echo "FAIL 下载失败（可试 HTTPS_PROXY）"; return 3; }
  fi
  echo "解压…"
  rm -rf "$CFT_DIR" && mkdir -p "$CFT_DIR"
  unzip -q "$TOOLS/cft.zip" -d "$CFT_DIR" || { echo "FAIL 解压失败"; return 4; }
  rm -f "$TOOLS/cft.zip"
  chmod +x "$CFT_DIR/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing" 2>/dev/null
  echo "就绪：$CFT_DIR"
}

launch() {
  local bin="$CFT_DIR/chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
  [ -x "$bin" ] || { echo "FAIL 先跑 prepare"; return 2; }
  CDP_PORT="${1:-9333}"
  HTTP_PORT="${2:-8765}"
  rm -rf "$UA_PROFILE"
  python3 -m http.server "$HTTP_PORT" --bind 127.0.0.1 --directory qa/chrome-ext-probe >/tmp/ew-cft-http.log 2>&1 &
  echo $! > /tmp/ew-cft-http.pid
  sleep 1
  # 静默红线：默认 headless（新版 headless 支持 MV3 扩展）；要人工看才设 EW_CHROME_HEADLESS=0，
  # 那时窗口也放到屏幕外，绝不 activate。
  local flags=(--user-data-dir="$UA_PROFILE" --remote-debugging-port="$CDP_PORT"
    --load-extension="$PWD/extension" --disable-extensions-except="$PWD/extension"
    --no-first-run --no-default-browser-check --window-size=1200,900
    --disable-background-timer-throttling --disable-renderer-backgrounding
    --disable-backgrounding-occluded-windows)
  if [ "${EW_CHROME_HEADLESS:-1}" = "1" ]; then
    flags+=(--headless=new --disable-gpu)
  else
    flags+=(--window-position=-3000,-3000)
  fi
  "$bin" "${flags[@]}" "http://127.0.0.1:$HTTP_PORT/" >/tmp/ew-cft-chrome.log 2>&1 &
  echo $! > /tmp/ew-cft-chrome.pid
  echo "CDP：http://127.0.0.1:$CDP_PORT  页面：http://127.0.0.1:$HTTP_PORT/  模式：$([ "${EW_CHROME_HEADLESS:-1}" = "1" ] && echo headless || echo offscreen-headed)"
}

stop() {
  [ -f /tmp/ew-cft-chrome.pid ] && kill "$(cat /tmp/ew-cft-chrome.pid)" 2>/dev/null
  [ -f /tmp/ew-cft-http.pid ] && kill "$(cat /tmp/ew-cft-http.pid)" 2>/dev/null
  rm -f /tmp/ew-cft-chrome.pid /tmp/ew-cft-http.pid
  rm -rf "$UA_PROFILE"
  echo "已清理"
}

case "$CMD" in
  prepare) prepare ;;
  launch)  launch "${@:2}" ;;
  stop)    stop ;;
  *) echo "用法：$0 prepare|launch|stop"; exit 2 ;;
esac
