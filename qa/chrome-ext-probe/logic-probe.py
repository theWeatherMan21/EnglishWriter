#!/usr/bin/env python3
"""logic-probe.py — 在没有「扩展加载」的前提下验证 content.js 的逻辑本身

背景：Chrome 156 已移除 --load-extension（实测 computed id 打不开、页面 ERR_BLOCKED_BY_CLIENT），
自动化无法自己装配扩展。但扩展的核心逻辑（取文本 → 调本地 API → 算矩形 → 画线 → 改 DOM → 撤销）
与「是否以扩展身份运行」无关，所以这里把 content.js 直接注入页面上下文，用 chrome.storage 垫片喂 token，
跑同一套端到端断言。真扩展验收仍需手动 Load unpacked（或 Chrome for Testing）。

产物：qa/chrome-ext-probe/logic-probe-report.json
"""
import json, os, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from drive import WS, evaluate, targets  # noqa: E402

TOKEN_FILE = os.path.expanduser("~/Library/Application Support/EnglishWriter/api-token.txt")
SENTENCE = "There is many reasons why we should sent the booking confirmation immediatly."


def main():
    if "--port" in sys.argv:
        import drive
        drive.DEBUG_PORT = int(sys.argv[sys.argv.index("--port") + 1])
    token = open(TOKEN_FILE).read().strip()
    src = open(os.path.join(HERE, "..", "..", "extension", "content.js")).read()
    page = next((t for t in targets() if t.get("type") == "page" and "127.0.0.1:8765" in t.get("url", "")), None)
    if not page:
        print("FAIL 没有探针页"); return 1

    ws = WS(page["webSocketDebuggerUrl"])
    ws.send("Runtime.enable")
    ws.send("Page.enable")
    # 先把页面刷干净：上一次注入留下的实例还挂着 input 监听（token=null），会把结果污染成 skip
    ws.send("Page.reload", {"ignoreCache": True})
    time.sleep(2.2)
    ws.send("Page.bringToFront")     # 必需：页面不在前台时 Input.insertText 不落地
    time.sleep(0.5)

    # chrome.storage 垫片（只给 content.js 用）
    shim = f"""(() => {{
      window.__EW_LOADED__ = false;
      const TOKEN = {json.dumps(token)};
      const store = {{ token: TOKEN }};
      window.chrome = {{ storage: {{ local: {{
        get: (keys, cb) => {{ const out = {{}}; (Array.isArray(keys)?keys:[keys]).forEach(k => out[k] = store[k]); cb(out); }},
        set: (obj, cb) => {{ Object.assign(store, obj); cb && cb(); }},
        onChanged: {{ addListener: () => {{}} }}
      }} }} }};
      return true;
    }})()"""
    evaluate(ws, shim)
    mid = ws.send("Runtime.evaluate", {"expression": src, "returnByValue": True, "userGesture": True})
    r = ws.recv_until(mid)
    if r.get("result", {}).get("exceptionDetails"):
        print("注入失败:", json.dumps(r["result"]["exceptionDetails"])[:400]); return 1
    time.sleep(0.6)

    report = {}
    for sel, kind, label in [("#ta", "textarea", "textarea"), ("#ce", "contenteditable", "contenteditable")]:
        evaluate(ws, f"""(() => {{
          const el = document.querySelector('{sel}');
          el.focus();
          if ('{kind}' === 'textarea') {{ el.value = ''; }} else {{ el.innerHTML = ''; }}
          const r = document.createRange(); r.selectNodeContents(el);
          const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
          window.__EW_DEBUG.lastEdits = []; window.__EW_DEBUG.lastRects = [];
          return true;
        }})()""")
        ws.send("Page.bringToFront")
        time.sleep(0.3)
        focused = evaluate(ws, "document.activeElement && document.activeElement.id")
        mid = ws.send("Input.insertText", {"text": SENTENCE})
        ws.recv_until(mid)
        time.sleep(2.4)
        dbg = json.loads(evaluate(ws, "JSON.stringify(window.__EW_DEBUG)") or "{}")
        edits, rects = dbg.get("lastEdits", []), dbg.get("lastRects", [])
        entry = {"edits": len(edits), "rects": len(rects), "engine": dbg.get("engine"),
                 "ms": dbg.get("elapsedMs"),
                 "types": [e["type"] for e in edits],
                 "rectSample": rects[:3], "notes": dbg.get("notes", [])[-3:]}

        if edits:
            read = (lambda: evaluate(ws, f"document.querySelector('{sel}').{'value' if kind=='textarea' else 'innerText'}"))
            before = read()
            evaluate(ws, "window.__EW_TEST__.acceptByOriginal('immediatly')")
            time.sleep(1.0)
            after = read()
            evaluate(ws, "window.__EW_TEST__.undo()")
            time.sleep(1.0)
            undone = read()
            entry.update({
                "before": (before or "").strip()[:80],
                "after": (after or "").strip()[:80],
                "undone": (undone or "").strip()[:80],
                "accept_changed": "immediately" in (after or "") and "immediatly" not in (after or ""),
                "undo_restored": "immediatly" in (undone or "") and "immediately" not in (undone or ""),
            })
        report[label] = entry

    print(json.dumps(report, ensure_ascii=False, indent=2))
    open(os.path.join(HERE, "logic-probe-report.json"), "w").write(json.dumps(report, ensure_ascii=False, indent=2))

    ok = all(v.get("edits", 0) > 0 and v.get("rects", 0) > 0 and v.get("accept_changed") and v.get("undo_restored")
             for v in report.values())
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
