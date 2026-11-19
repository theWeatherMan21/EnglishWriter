#!/usr/bin/env python3
"""ce_probe.py — contenteditable 整篇检查验收（DOM Range 路径）

判据：
  1) 在 contenteditable（嵌套 <p>）里输入两句各带错的话
  2) 至少画出 2 条线（说明是整篇检查，不是只看光标句）
  3) 点第一条线 → 卡片出现

前置：Chrome for Testing 已 --load-extension 起好，页面 http://127.0.0.1:8765/
用法：python3 qa/chrome-ext-probe/ce_probe.py [--port 9333]
"""
import os, sys, time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import drive, click_probe


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
    ws.send("Page.reload"); time.sleep(2.5)

    drive.evaluate(ws, "(() => { const ce = document.getElementById('ce-p');"
                       " ce.textContent = ''; document.getElementById('ce').focus(); return 1; })()")
    for ch in "I have send the invoice. We was late yesterday.":
        ws.send("Input.insertText", {"text": ch}); time.sleep(0.006)
    time.sleep(3.0)

    n = drive.evaluate(
        ws,
        "(() => { const h = document.getElementById('__ew_host__');"
        " if (!h || !h.shadowRoot) return -1;"
        " return h.shadowRoot.querySelectorAll('.u').length; })()")
    if not isinstance(n, int) or n < 2:
        print(f"FAIL: contenteditable 只画出 {n} 条线（应 ≥2，说明仍在只看光标句）")
        return 3
    print(f"OK  contenteditable 整篇检查  {n} 条线")

    rects = drive.evaluate(
        ws,
        "(() => { const h = document.getElementById('__ew_host__');"
        " return [...h.shadowRoot.querySelectorAll('.u')].map(u => {"
        "   const b = u.getBoundingClientRect();"
        "   return { x: b.x + b.width / 2, y: b.y + b.height / 2 }; }); })()")
    r = dict(rects[0])  # type: ignore[index]
    for t in ("mouseMoved", "mousePressed", "mouseReleased"):
        ws.send("Input.dispatchMouseEvent", {
            "type": t, "x": r["x"], "y": r["y"], "button": "left",
            "buttons": 1 if t != "mouseReleased" else 0,
            "clickCount": 1, "pointerType": "mouse"})
        time.sleep(0.05)
    time.sleep(0.35)
    card = drive.evaluate(
        ws,
        "(() => { const h = document.getElementById('__ew_host__');"
        " const c = h.shadowRoot.querySelector('.card');"
        " return c ? (c.querySelector('.orig')||{}).textContent + '→' + (c.querySelector('.rep')||{}).textContent : null; })()")
    if not card:
        print("FAIL: contenteditable 里点线没弹卡")
        return 4
    print(f"OK  点线弹卡  {card}")
    print("=== 汇总：PASS 2 / FAIL 0 ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
