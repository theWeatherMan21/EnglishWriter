#!/bin/bash
# 把 web/ 里的共用 UI 资源同步进扩展目录（manifest 只能引用扩展内文件）
# 判据：扩展侧与 web 侧逐字节相同；CI 里 sync-web-check 会比对 sha256，只改一边立刻红。
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p extension/ui
cp web/sidebar/sidebar.css extension/ui/sidebar.css
cp web/sidebar/tokens.css extension/ui/tokens.css
cp web/card/card.css extension/ui/card.css
echo "synced -> extension/ui/{sidebar.css,tokens.css,card.css}"
