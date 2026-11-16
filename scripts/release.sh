#!/bin/bash
# release.sh — 打包一个可分发 zip + sha256（不发布、不推远端，动作由人来做）
#
# 用法：scripts/release.sh 0.3.0
# 产物：dist/EnglishWriter-0.3.0-macos.zip  +  dist/SHA256SUMS.txt
#
# 为什么版本号写进 Info.plist 而不改 build.sh 的常量：build.sh 的 VERSION 是开发用默认值，
# 发版时用 RELEASE_VERSION 覆盖，避免每次发版都要改脚本。
set -euo pipefail
cd "$(dirname "$0")/.."

VER="${1:-}"
if [ -z "$VER" ]; then echo "用法：scripts/release.sh <version>   例：scripts/release.sh 0.3.0"; exit 2; fi
if ! printf '%s' "$VER" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "版本号必须是 X.Y.Z（十进制，小版本位 0-9）"; exit 2
fi

echo "== 1/4 自测 =="
./build/英文写作助手 --selftest --m3 >/dev/null
./build/英文写作助手 --selftest --lt  >/dev/null || { echo "自测未全绿，拒绝发版"; exit 1; }

echo "== 2/4 重编（版本号写进 Info.plist）=="
RELEASE_VERSION="$VER" bash scripts/build.sh >/dev/null

echo "== 3/4 打包 =="
mkdir -p dist
NAME="EnglishWriter-${VER}-macos"
rm -rf "dist/$NAME" "dist/$NAME.zip"
mkdir -p "dist/$NAME"
cp -R "build/英文写作助手.app" "dist/$NAME/"
cp LICENSE README.md "dist/$NAME/"
ditto -c -k --keepParent "dist/$NAME" "dist/$NAME.zip"

echo "== 4/4 校验和 =="
(cd dist && shasum -a 256 "$NAME.zip" | tee -a SHA256SUMS.txt)

echo
echo "产物：dist/$NAME.zip"
echo "发版动作（建 Release / 推 tag / public 化）不在这里做，要人点头再执行。"
