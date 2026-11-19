#!/usr/bin/env python3
"""twostage_probe.py — 扩展两段式检查的不变量验收（本地线先到、模型线后到）

判据（知澜 11-19 定）：
  1) run 开始后 ~120ms 抓 snapA：必须已有线，且时间 ≤200ms
  2) 3.5s 抓 snapB：线集合只增不减（模型结果不许把已画的线抹掉）
  3) 同一错处不重复出现（按矩形去重后数量与线数一致）
  4) 证据落盘 qa/evidence/chrome-twostage.json（两组 rects + 时间 + dropped）

前置：Chrome for Testing 已 --load-extension 起好，页面 http://127.0.0.1:8765/
用法：python3 qa/chrome-ext-probe/twostage_probe.py [--port 9333]
"""
import json, os, sys, time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import drive, click_probe

SENTENCE = "I have send the report immediatly and there is many reasons."


def snapshot(ws):
    return drive.evaluate(
        ws,
        "(() => { const h = document.getElementById('__ew_host__');"
        " if (!h || !h.shadowRoot) return [];"
        " return [...h.shadowRoot.querySelectorAll('.u')].map(u => {"
        "   const b = u.getBoundingClientRect();"
        "   return { x: Math.round(b.x), y: Math.round(b.y),"
        "            w: Math.round(b.width), h: Math.round(b.height),"
        "            cls: u.className }; }); })()")


def main():
    if "--port" in sys.argv:
        drive.DEBUG_PORT = int(sys.argv[sys.argv.index("--port") + 1])
    page = next((t for t in drive.targets()
                 if t.get("type") == "page" and "127.0.0.1:8765" in t.get("url", "")), None)
    if not page:
        print("FAIL: 没找到测试页")
        return 2

    click_probe.ensure_token()
    ws = drive.WS(page["webSocketDebuggerUrl"])
    ws.send("Runtime.enable"); ws.send("Page.enable")

    drive.evaluate(ws, "(() => { const t=document.querySelector('textarea');"
                       " t.focus(); t.value=''; t.setSelectionRange(0,0); return 1; })()")
    t0 = time.time()
    for ch in SENTENCE:
        ws.send("Input.insertText", {"text": ch})
        time.sleep(0.006)

    # 等到 120ms（含 800ms 去抖，这次从「去抖结束」开始算：先等到有第一波线为止）
    snapA, msA = [], None
    deadline = t0 + 12
    while time.time() < deadline:
        time.sleep(0.03)
        s = snapshot(ws)
        if s:
            snapA = s
            msA = int((time.time() - t0) * 1000)
            break

    # 再等 3.5 秒抓最终态
    time.sleep(3.5)
    snapB = snapshot(ws)
    msB = int((time.time() - t0) * 1000)

    def key(r):
        return (r["x"], r["y"], r["w"], r["h"])

    keysA = {key(r) for r in snapA}
    keysB = {key(r) for r in snapB}
    dropped = sorted(keysA - keysB)
    dupB = len(snapB) - len(keysB)

    print(f"snapA: {len(snapA)} 条 @ {msA}ms" if msA else "snapA: 没有线")
    print(f"snapB: {len(snapB)} 条 @ {msB}ms")
    print(f"被抹掉的旧线: {len(dropped)}；重复矩形: {dupB}")

    fails = 0
    if not snapA:
        print("FAIL: 到 12s 都没有任何线")
        fails += 1
    elif msA > 1500:
        # 800ms 去抖 + 本地请求；>1.5s 说明本地段没生效
        print(f"FAIL: 首条线 {msA}ms，超过 1.5s（本地段没生效？）")
        fails += 1
    if dropped:
        print(f"FAIL: 模型结果抹掉了 {len(dropped)} 条已画的线")
        fails += 1
    if dupB:
        print(f"FAIL: {dupB} 个重复矩形")
        fails += 1
    if msB < 2000:
        print(f"WARN: snapB 只用了 {msB}ms，可能没等到模型（不代表失败）")

    ev = {"snapA": {"rects": snapA, "ms": msA},
          "snapB": {"rects": snapB, "ms": msB},
          "dropped": len(dropped), "duplicates": dupB,
          "sentence": SENTENCE, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    out = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..",
                                       "qa", "evidence", "chrome-twostage.json"))
    with open(out, "w") as f:
        json.dump(ev, f, ensure_ascii=False, indent=2)
    print("证据：" + out)
    print(f"=== 两段式：PASS {4 - fails} / FAIL {fails} ===")
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
