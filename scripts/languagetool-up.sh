#!/bin/bash
# languagetool-up.sh — 幂等启动本地 LanguageTool（App 启动时自己调这个）
# 已经在跑就直接退出 0；没装就退出 2（App 回落到模型接口）
#
# 目录口径：~/Library/Application Support/EnglishWriter/lt/
#   lt/jdk-17.0.21+9/Contents/Home/bin/java
#   lt/LanguageTool-6.6/languagetool-server.jar
set -u

LT_HOME="${EW_LT_HOME:-$HOME/Library/Application Support/EnglishWriter/lt}"
PORT="${EW_LT_PORT:-8081}"
LOG="$LT_HOME/lt.log"

alive() {
  curl -s -m 1 -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/v2/languages" 2>/dev/null | grep -q 200
}

if alive; then echo "already running on $PORT"; exit 0; fi

JDK="$(ls -d "$LT_HOME"/jdk-*/Contents/Home 2>/dev/null | head -1)"
JAR="$(ls "$LT_HOME"/LanguageTool-*/languagetool-server.jar 2>/dev/null | head -1)"
if [ -z "${JDK:-}" ] || [ -z "${JAR:-}" ]; then
  echo "not installed: $LT_HOME" >&2
  exit 2
fi

mkdir -p "$LT_HOME"
# 堆封顶（2026-11-18 实测）：192m → OOM；256m → 可用，冷启动 1.8s，RSS 368MB。
# 注意：堆调小并不能把 RSS 压到理想值（metaspace + 规则对象占大头），真正省内存靠闲置退出。
nohup "$JDK/bin/java" -Xmx256m -Xms64m -XX:+UseSerialGC -XX:MaxMetaspaceSize=96m \
  -jar "$JAR" --port "$PORT" >>"$LOG" 2>&1 &
disown 2>/dev/null || true

for _ in $(seq 1 40); do
  if alive; then echo "started on $PORT"; exit 0; fi
  sleep 1
done
echo "failed to start, see $LOG" >&2
tail -5 "$LOG" >&2
exit 1
