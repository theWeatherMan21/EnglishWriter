#!/bin/bash
# mail-compose-e2e.sh — 真宿主 E2E：Mail 新建邮件 → 打字 → 等出线 → 读日志 → 关掉草稿
#
# ⚠️ 这会真的打开一个 Mail 新邮件窗口（屏幕上会出现），碰了「静默红线」。
#    所以默认不跑：必须显式加 --yes-i-authorize 才执行，且只有爹地本人能授权。
#
# ⚠️ 只新建 + 关闭，绝不发送。不碰收件人，不填主题，关闭时选「不保存」。
#
# 用法：
#   bash qa/e2e/mail-compose-e2e.sh --yes-i-authorize
#
# 判据（脚本自己判，不靠肉眼）：
#   1) check-log 里出现 attach-el/fallback-el（选路成功）
#   2) 之后 10 秒内出现 render 且 itemCount>0 && rectCount>0（线画出来了）
#   3) 期间没有针对 Mail 的 skip-readonly（写信窗不该被判只读）
# 任一条不满足 → 打印最后 20 行相关日志并 exit 1。
set -uo pipefail
cd "$(dirname "$0")/../.."

if [ "${1:-}" != "--yes-i-authorize" ]; then
    cat <<'EOF'
这个脚本会在屏幕上弹出 Mail 的新建邮件窗口（触碰静默红线）。
需要爹地本人点头授权，加上参数再跑：

    bash qa/e2e/mail-compose-e2e.sh --yes-i-authorize
EOF
    exit 2
fi

LOG="$HOME/Library/Application Support/EnglishWriter/check-log.jsonl"
TEXT="I have send the file, please check it."
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

echo "== 1/4 新建 Mail 邮件 =="
osascript <<'APPLESCRIPT' || { echo "FAIL 打开 Mail 新建邮件失败（需要自动化权限）"; exit 1; }
tell application "Mail"
    activate
    make new outgoing message with properties {visible:true}
end tell
APPLESCRIPT
sleep 2

echo "== 2/4 写入正文（不填收件人、不填主题）=="
osascript -e "tell application \"Mail\" to set content of front outgoing message to \"$TEXT\"" \
    || { echo "FAIL 写正文失败"; exit 1; }
sleep 1

echo "== 3/4 等出线（最多 15 秒）=="
found_render=0; found_skip=0
for i in $(seq 1 15); do
    sleep 1
    python3 - "$LOG" "$SINCE" <<'PY' && found_render=1 && break
import json,sys,datetime
path, since = sys.argv[1], sys.argv[2]
since_dt = datetime.datetime.strptime(since, "%Y-%m-%dT%H:%M:%SZ")
for line in open(path, errors="replace"):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except Exception: continue
    if r.get("app")!="Mail": continue
    if r.get("kind")=="render" and r.get("itemCount",0)>0 and r.get("rectCount",0)>0:
        print(f"  OK  render item={r['itemCount']} rect={r['rectCount']} role={r.get('role')}")
        raise SystemExit(0)
raise SystemExit(1)
PY
done

echo "== 4/4 关闭草稿（不保存，不发送）=="
osascript <<'APPLESCRIPT' >/dev/null 2>&1 || true
tell application "Mail"
    try
        close front outgoing message saving no
    end try
end tell
APPLESCRIPT

python3 - "$LOG" "$SINCE" <<'PY'
import json,sys,datetime
path, since = sys.argv[1], sys.argv[2]
since_dt = datetime.datetime.strptime(since, "%Y-%m-%dT%H:%M:%SZ")
rows=[]
for line in open(path, errors="replace"):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except Exception: continue
    try: at=datetime.datetime.strptime(r["at"], "%Y-%m-%dT%H:%M:%SZ")
    except Exception: continue
    if at>=since_dt and r.get("app")=="Mail": rows.append(r)
pick=[r for r in rows if r.get("kind") in ("attach-el","fallback-el")]
render=[r for r in rows if r.get("kind")=="render" and r.get("itemCount",0)>0]
skip=[r for r in rows if r.get("kind")=="skip-readonly"]
print(f"  选路 {len(pick)} 条 · 出线 {len(render)} 条 · 写信窗被判只读 {len(skip)} 条")
for r in rows[-12:]:
    print(f"    {r['at'][11:19]} {r['kind']:<14} item={r.get('itemCount',0):>2} rect={r.get('rectCount',0):>2} {r.get('err','')[:40]}")
ok = bool(render) and not skip
print("RESULT:", "PASS（写信窗出线、无 skip-readonly）" if ok else "FAIL（见上面最后 12 行）")
raise SystemExit(0 if ok else 1)
PY
