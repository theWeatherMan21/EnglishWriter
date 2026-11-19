#!/usr/bin/env python3
"""keyboard_probe.py — 扩展卡片的键盘操作验收（Esc 关闭、←/→ 切建议）

判据（与 Grammarly 同款交互）：
  1) 点线下划线 → 卡片出现
  2) 按 →  → 卡片切到下一条建议（orig 变了）
  3) 按 ←  → 切回上一条
  4) 按 Esc → 卡片消失

前置：Chrome for Testing 已 --load-extension 起好，页面 http://127.0.0.1:8765/
用法：python3 qa/chrome-ext-probe/keyboard_probe.py [--port 9333]
"""
import json, os, sys, time

sys.path.insert(0, __file__.rsplit('/', 1)[0])
import drive
import click_probe


def card_state(ws):
    return drive.evaluate(
        ws,
        "(() => { const h = document.getElementById('__ew_host__');"
        " if (!h || !h.shadowRoot) return null;"
        " const c = h.shadowRoot.querySelector('.card');"
        " if (!c) return null;"
        " return { orig: (c.querySelector('.orig')||{}).textContent || '',"
        "          rep: (c.querySelector('.rep')||{}).textContent || '' }; })()")


def click_line(ws, index=0):
    rects = drive.evaluate(
        ws,
        "(() => { const h = document.getElementById('__ew_host__');"
        " if (!h || !h.shadowRoot) return null;"
        " return [...h.shadowRoot.querySelectorAll('.u')].map(u => {"
        "   const b = u.getBoundingClientRect();"
        "   return { x: b.x + b.width / 2, y: b.y + b.height / 2 }; }); })()")
    if not rects:
        return False
    r = dict(dict(rects)[index]) if False else dict(rects[index])  # type: ignore[index]
    for t in ("mouseMoved", "mousePressed", "mouseReleased"):
        ws.send("Input.dispatchMouseEvent", {
            "type": t, "x": r["x"], "y": r["y"], "button": "left",
            "buttons": 1 if t != "mouseReleased" else 0,
            "clickCount": 1, "pointerType": "mouse"})
        time.sleep(0.05)
    time.sleep(0.3)
    return True


def key(ws, k, code, keyCode):
    for t in ("keyDown", "keyUp"):
        ws.send("Input.dispatchKeyEvent", {"type": t, "key": k, "code": code,
                                           "windowsVirtualKeyCode": keyCode,
                                           "nativeVirtualKeyCode": keyCode})
        time.sleep(0.05)


def main():
    if "--port" in sys.argv:
        drive.DEBUG_PORT = int(sys.argv[sys.argv.index("--port") + 1])
    page = next((t for t in drive.targets()
                 if t.get("type") == "page" and "127.0.0.1:8765" in t.get("url", "")), None)
    if not page:
        print("FAIL: 没找到测试页")
        return 2

    click_probe.ensure_token()       # 新 profile 没 token → 内容脚本会静默待命
    ws = drive.WS(page["webSocketDebuggerUrl"])
    ws.send("Runtime.enable"); ws.send("Page.enable")
    ws.send("Page.reload"); time.sleep(2.5)

    # 全新会话：清空输入并打一句有两处错的英文
    drive.evaluate(ws, "(() => { const t=document.querySelector('textarea');"
                       " t.focus(); t.value=''; t.setSelectionRange(0,0); return true; })()")
    for ch in "I have send the report immediatly.":
        ws.send("Input.insertText", {"text": ch}); time.sleep(0.008)
    # 检查现在走真模型（约 3 秒/句）：轮询到画线出现为止，最多 20 秒
    for _ in range(80):
        time.sleep(0.25)
        n = drive.evaluate(ws, "(() => { const h = document.getElementById('__ew_host__');"
                               " if (!h || !h.shadowRoot) return 0;"
                               " return h.shadowRoot.querySelectorAll('.u').length; })()")
        if isinstance(n, int) and n > 0:
            break

    fails = 0
    if not click_line(ws, 0):
        print("FAIL: 没有画出下划线")
        return 3
    first = card_state(ws)
    if not first:
        print("FAIL: 点线后卡片没出现")
        return 4
    print(f"OK  卡片出现  {first['orig']} → {first['rep']}")

    key(ws, "ArrowRight", "ArrowRight", 39)
    time.sleep(0.35)
    second = card_state(ws)
    if second and second["orig"] != first["orig"]:
        print(f"OK  → 切到下一条  {second['orig']} → {second['rep']}")
    else:
        print(f"FAIL: → 没有切换（仍是 {second})"); fails += 1

    key(ws, "ArrowLeft", "ArrowLeft", 37)
    time.sleep(0.35)
    back = card_state(ws)
    if back and back["orig"] == first["orig"]:
        print(f"OK  ← 切回上一条  {back['orig']}")
    else:
        print(f"FAIL: ← 没有切回（{back})"); fails += 1

    key(ws, "Escape", "Escape", 27)
    time.sleep(0.3)
    if card_state(ws) is None:
        print("OK  Esc 关闭卡片")
    else:
        print("FAIL: Esc 没关掉卡片"); fails += 1

    evidence = {"first": first, "second": second, "back": back,
                "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    out = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..",
                                       "qa", "evidence", "chrome-keyboard.json"))
    with open(out, "w") as f:
        json.dump(evidence, f, ensure_ascii=False, indent=2)
    print("证据：" + out)
    print("=== 汇总：PASS %d / FAIL %d ===" % (3 - fails, fails))
    return 0 if fails == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
