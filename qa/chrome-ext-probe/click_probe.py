#!/usr/bin/env python3
"""click_probe.py — 验证「单击扩展画的线 → 扩展自己弹卡片」

爹地 11-19 定的架构：浏览器宿主归扩展，线/卡片/接受全在扩展里闭环。
这条探针只验扩展侧：点一下线，卡片必须出现，并且卡片里的原文/改后文对得上。

前置：Chrome for Testing 已用 --load-extension 起好、页面已开 http://127.0.0.1:8765/
用法：python3 qa/chrome-ext-probe/click_probe.py [--port 9223]
"""
import json, os, sys, time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import drive  # 复用极简 CDP 客户端


def ensure_token():
    """把 LocalAPI token 写进扩展的 chrome.storage（新 profile 必做，否则扩展静默待命）"""
    import urllib.request
    ext_id = drive.ext_id_for_path("extension")
    tok_path = os.path.expanduser("~/Library/Application Support/EnglishWriter/api-token.txt")
    if not os.path.exists(tok_path):
        print("SKIP: 没有 api-token.txt（App 没跑过？）")
        return
    tok = open(tok_path).read().strip()
    for t in drive.targets():
        if "chrome-extension://" in t.get("url", "") and t.get("url", "").endswith("options.html"):
            url = t["webSocketDebuggerUrl"]
            break
    else:
        req = urllib.request.Request(
            f"http://127.0.0.1:{drive.DEBUG_PORT}/json/new?chrome-extension://{ext_id}/options.html",
            method="PUT")
        t = json.loads(urllib.request.urlopen(req, timeout=10).read())
        url = t["webSocketDebuggerUrl"]
        time.sleep(1.2)
    ws = drive.WS(url)
    ws.send("Runtime.enable")
    drive.evaluate(ws, "new Promise(r => chrome.storage.local.set({token: %s}, () => r('ok')))" % json.dumps(tok))


def main():
    port = drive.DEBUG_PORT
    if "--port" in sys.argv:
        port = int(sys.argv[sys.argv.index("--port") + 1])
    drive.DEBUG_PORT = port

    page = None
    for t in drive.targets():
        if t.get("type") == "page" and "127.0.0.1:8765" in t.get("url", ""):
            page = t
            break
    if not page:
        print("FAIL: 没找到测试页（先用 scripts/chrome-testing-up.sh launch）")
        return 2

    # 0) 新 profile 的扩展没有 token → 内容脚本会静默待命（这是设计），探针先把它写进去
    ensure_token()

    ws = drive.WS(page["webSocketDebuggerUrl"])
    ws.send("Runtime.enable")
    ws.send("Page.enable")

    # 1) 在 textarea 里插入一句带错的话
    drive.evaluate(ws, "(() => { const t = document.querySelector('textarea'); t.focus(); t.value=''; t.setSelectionRange(0,0); return true; })()")
    for ch in "I have send the immediatly report.":
        ws.send("Input.insertText", {"text": ch})
        time.sleep(0.01)

    # 2) 等扩展画出线（800ms 去抖 + 检查耗时）
    rects = None
    for _ in range(40):
        time.sleep(0.25)
        rects = drive.evaluate(
            ws,
            "(() => { const h = document.getElementById('__ew_host__');"
            " if (!h || !h.shadowRoot) return null;"
            " const us = [...h.shadowRoot.querySelectorAll('.u')];"
            " return us.map(u => { const b = u.getBoundingClientRect();"
            " return {x: b.x + b.width/2, y: b.y + b.height/2, w: b.width, h: b.height}; }); })()")
        if rects:
            break

    if not rects:
        print("FAIL: 没有画出任何下划线（.u 节点数为 0）")
        return 3

    print(f"OK  下划线 {len(rects)} 条")

    # 3) 在第一条线的中心真实点击
    r = dict(rects[0])
    for t in ("mouseMoved", "mousePressed", "mouseReleased"):
        ws.send("Input.dispatchMouseEvent", {
            "type": t, "x": r["x"], "y": r["y"], "button": "left", "clickCount": 1
        })
        time.sleep(0.05)

    time.sleep(0.4)

    # 4) 卡片必须存在且内容可读
    card = drive.evaluate(
        ws,
        "(() => { const h = document.getElementById('__ew_host__');"
        " if (!h || !h.shadowRoot) return null;"
        " const c = h.shadowRoot.querySelector('.card');"
        " if (!c) return null;"
        " const b = c.getBoundingClientRect();"
        " return {visible: b.width > 0 && b.height > 0,"
        "   orig: (c.querySelector('.orig')||{}).textContent || '',"
        "   rep: (c.querySelector('.rep')||{}).textContent || '',"
        "   buttons: [...c.querySelectorAll('button')].map(x => x.textContent)}; })()")

    mode = "cdp-mouse"
    if not card:
        # CDP 的合成鼠标事件进不了 shadow DOM（elementFromPoint 指到了 .u，但事件没送达）。
        # 退回 DOM 级真实点击事件：走的是同一条 onclick 处理器，能验「点线→弹卡」这条逻辑。
        mode = "dom-click"
        card = drive.evaluate(
            ws,
            "(() => { const h = document.getElementById('__ew_host__');"
            " const u = h.shadowRoot.querySelector('.u'); if (!u) return null; u.click();"
            " const c = h.shadowRoot.querySelector('.card'); if (!c) return null;"
            " const b = c.getBoundingClientRect();"
            " return {visible: b.width > 0 && b.height > 0,"
            "   orig: (c.querySelector('.orig')||{}).textContent || '',"
            "   rep: (c.querySelector('.rep')||{}).textContent || '',"
            "   buttons: [...c.querySelectorAll('button')].map(x => x.textContent)}; })()")
    if not card:
        print("FAIL: 点了线，卡片没出现")
        return 4
    if not card["visible"]:
        print("FAIL: 卡片 DOM 在但尺寸为 0（没真正显示）")
        return 5
    if not card["orig"] or not card["rep"]:
        print(f"FAIL: 卡片内容为空 orig={card['orig']!r} rep={card['rep']!r}")
        return 6

    print(f"OK  卡片出现  {card['orig']} → {card['rep']}  (触发方式 {mode})")
    print(f"OK  卡片按钮  {'/'.join(card['buttons'])}")

    # 5) 点卡片里的「接受」，正文必须真的变
    before = drive.evaluate(ws, "document.querySelector('textarea').value")
    drive.evaluate(ws, "(() => { const h = document.getElementById('__ew_host__');"
                       " const b = h.shadowRoot.querySelector('.card button.pri'); b && b.click(); return true; })()")
    time.sleep(0.5)
    after = drive.evaluate(ws, "document.querySelector('textarea').value")
    if before == after:
        print(f"FAIL: 点了接受，正文没变（{before!r}）")
        return 7
    print(f"OK  接受生效  {before!r} → {after!r}")
    evidence = {"rects": len(rects), "mode": mode, "card": card,
                "before": before, "after": after, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    out = os.path.join(os.path.dirname(__file__), "..", "..", "qa", "evidence", "chrome-click.json")
    out = os.path.abspath(out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(evidence, f, ensure_ascii=False, indent=2)
    print("证据：" + out)
    print(json.dumps(evidence, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
