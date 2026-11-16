#!/usr/bin/env python3
"""drive.py — 用 CDP 驱动「装了扩展的 Chrome」跑端到端验收（纯标准库，自带极简 WebSocket）

验收口径（爹地 11-16 定：不许截图）：
  1) 在页面 textarea / contenteditable 里插入英文句子（走真实 Input.insertText）
  2) 读 window.__EW_DEBUG：edits 条数、rects 条数、engine、elapsedMs
  3) 触发接受 → 读 DOM 里正文真的变了（textarea.value / innerText）
  4) 触发撤销 → 读 DOM 真的还原

用法：python3 qa/chrome-ext-probe/drive.py [--port 9223] [--token-file <path>]
前提：Chrome 已用 --load-extension 起好，页面已开 http://127.0.0.1:8765/
"""
import base64, hashlib, json, os, socket, struct, sys, time, urllib.request

DEBUG_PORT = 9223
TOKEN_FILE = os.path.expanduser("~/Library/Application Support/EnglishWriter/api-token.txt")


# ---------- 极简 WebSocket 客户端（RFC6455，仅文本帧，够 CDP 用）----------
class WS:
    def __init__(self, url):
        assert url.startswith("ws://")
        host_port, path = url[5:].split("/", 1)
        host, port = host_port.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=20)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (f"GET /{path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
               f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(req.encode())
        buf = b""
        while b"\r\n\r\n" not in buf:
            buf += self.sock.recv(4096)
        assert b"101" in buf.split(b"\r\n")[0], buf[:120]
        self.buf = b""
        self.mid = 0

    def send(self, method, params=None):
        self.mid += 1
        payload = json.dumps({"id": self.mid, "method": method, "params": params or {}}).encode()
        header = bytearray([0x81])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126); header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127); header += struct.pack(">Q", n)
        mask = os.urandom(4)
        header += mask
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + masked)
        return self.mid

    def recv_until(self, mid, timeout=25):
        end = time.time() + timeout
        while time.time() < end:
            msg = self._frame()
            if msg is None:
                continue
            try:
                obj = json.loads(msg)
            except Exception:
                continue
            if obj.get("id") == mid:
                return obj
        raise TimeoutError(f"no reply for id={mid}")

    def drain(self, seconds=0.8):
        """读一段事件流（不等 id），返回事件列表 —— 用来抓 Runtime.executionContextCreated"""
        end = time.time() + seconds
        out = []
        while time.time() < end:
            msg = self._frame()
            if not msg:
                continue
            try:
                obj = json.loads(msg)
            except Exception:
                continue
            if "method" in obj:
                out.append(obj)
        return out

    def _frame(self):
        self.sock.settimeout(2)
        try:
            b0, b1 = self._read(2)
        except socket.timeout:
            return None
        op = b0 & 0x0F
        n = b1 & 0x7F
        if n == 126:
            n = struct.unpack(">H", self._read(2))[0]
        elif n == 127:
            n = struct.unpack(">Q", self._read(8))[0]
        data = self._read(n) if n else b""
        if op == 0x8:
            return None
        if op == 0x9:            # ping → pong
            self.sock.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
            return None
        return data.decode("utf-8", "replace")

    def _read(self, n):
        out = b""
        while len(out) < n:
            if self.buf:
                take = self.buf[:n - len(out)]
                out += take
                self.buf = self.buf[len(take):]
                continue
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("ws closed")
            self.buf = chunk
        return out


def http(path):
    with urllib.request.urlopen(f"http://127.0.0.1:{DEBUG_PORT}{path}", timeout=10) as r:
        return json.loads(r.read().decode())


def targets():
    return http("/json/list")


def evaluate(ws, expr, await_promise=True, context_id=None):
    params = {"expression": expr, "returnByValue": True,
               "awaitPromise": await_promise, "userGesture": True}
    if context_id:
        params["contextId"] = context_id
    mid = ws.send("Runtime.evaluate", params)
    r = ws.recv_until(mid)
    res = r.get("result", {}).get("result", {})
    if res.get("subtype") == "error":
        return {"__error": res.get("description")}
    return res.get("value")


def diff_window(a, b, pad=20):
    """首个不同字符前后各 pad 字，用来一眼看出 immediatly → immediately"""
    i = 0
    n = min(len(a), len(b))
    while i < n and a[i] == b[i]:
        i += 1
    lo = max(0, i - pad)
    return {"first_diff_at": i,
            "a": a[lo:i + pad], "b": b[lo:i + pad],
            "a_len": len(a), "b_len": len(b)}


def ext_id_for_path(path):
    h = hashlib.sha256(os.path.abspath(path).encode()).hexdigest()[:32]
    return "".join(chr(ord("a") + int(c, 16)) for c in h)


def main():
    global DEBUG_PORT
    if "--port" in sys.argv:
        DEBUG_PORT = int(sys.argv[sys.argv.index("--port") + 1])
    ext_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "extension")
    token = open(TOKEN_FILE).read().strip()

    ts = targets()
    page = next((t for t in ts if t.get("type") == "page" and "127.0.0.1:8765" in t.get("url", "")), None)
    if not page:
        print("FAIL 找不到探针页（http://127.0.0.1:8765/）"); print([t.get("url") for t in ts]); return 1

    # 1) 先给扩展塞 token（options 页上下文里有 chrome.storage）
    #    扩展 id 直接从运行中的 target 里认，别靠路径哈希猜（猜错了白跑）
    eid = None
    for t in ts:
        u = t.get("url", "")
        if u.startswith("chrome-extension://") and "service_worker" in u:
            eid = u.split("/")[2]
            break
    if not eid:
        eid = ext_id_for_path(ext_dir)
    print(f"extension id = {eid}")
    # /json/new 需要 PUT，直接在同页上下文里用 chrome.storage 会没有权限 → 用扩展页 target
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{DEBUG_PORT}/json/new?chrome-extension://{eid}/options.html", method="PUT")
        with urllib.request.urlopen(req, timeout=10) as r:
            opt = json.loads(r.read().decode())
        time.sleep(1.2)
        ow = WS(opt["webSocketDebuggerUrl"])
        mid = ow.send("Runtime.evaluate", {"expression": f"chrome.storage.local.set({{token:{json.dumps(token)}}},()=>'ok')",
                                           "awaitPromise": True, "returnByValue": True})
        print("set token ->", ow.recv_until(mid).get("result", {}).get("result", {}).get("value"))
        ow.send("Page.close")
        time.sleep(0.6)
    except Exception as e:
        print("WARN 塞 token 失败：", e)

    # 2) 回到探针页跑端到端
    ws = WS(page["webSocketDebuggerUrl"])
    ws.send("Runtime.enable")
    ws.send("Page.enable")
    # 关键：content script 跑在 isolated world，window.__EW_DEBUG 在默认上下文里看不见，
    # 必须找到那个非 default 的执行上下文再取数/触发
    ws.send("Runtime.enable")
    ctxs = []
    for ev in ws.drain(1.0):
        if ev.get("method") == "Runtime.executionContextCreated":
            ctxs.append(ev["params"]["context"])
    iso = next((c for c in ctxs if not c.get("auxData", {}).get("isDefault", True)), None)
    if iso:
        print("isolated context:", iso.get("name"), iso.get("id"))
    else:
        print("WARN 没找到 isolated world，退回默认上下文")
    iso_id = iso.get("id") if iso else None

    report = {}
    sentence = "There is many reasons why we should sent the booking confirmation immediatly."

    def click_center(sel):
        """真点一下元素中心：contenteditable 光 focus() 不一定落光标，点了才算真焦点"""
        box = evaluate(ws, f"""(() => {{
          const el = document.querySelector('{sel}');
          const r = el.getBoundingClientRect();
          return {{x: Math.round(r.left + Math.min(20, Math.max(4, r.width / 2))),
                   y: Math.round(r.top + Math.min(12, Math.max(4, r.height / 2)))}};
        }})()""")
        if not isinstance(box, dict) or "x" not in box:
            return None
        for t in ("mousePressed", "mouseReleased"):
            mid = ws.send("Input.dispatchMouseEvent", {"type": t, "x": box["x"], "y": box["y"],
                                                       "button": "left", "clickCount": 1})
            ws.recv_until(mid)
        return box

    for sel, kind, label in [("#ta", "textarea", "textarea"), ("#ce", "contenteditable", "contenteditable")]:
        # 每个用例前清干净：元素内容 + 扩展调试态（否则上一轮的 lastEdits 会被当成本轮结果）
        clear = f"""(() => {{
          const el = document.querySelector('{sel}');
          if ('{kind}' === 'textarea') {{ el.value = ''; }} else {{ el.innerHTML = '<p></p>'; }}
          const node = '{kind}' === 'contenteditable' ? (el.querySelector('p') || el) : el;
          const r = document.createRange(); r.selectNodeContents(node);
          const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
          return true;
        }})()"""
        evaluate(ws, clear)
        evaluate(ws, "(() => { const d = window.__EW_DEBUG; d.lastEdits = []; d.lastRects = []; "
                     "d.notes = []; d.lastTarget = null; d.rectSource = 'none'; return true; })()",
                 context_id=iso_id)
        time.sleep(0.2)
        click_center(sel)
        time.sleep(0.2)
        active = evaluate(ws, "(() => { const a = document.activeElement; "
                              "return a ? ((a.id ? '#' + a.id : '') + a.tagName) : 'none'; })()")
        # 真实键入路径（Input.insertText，走浏览器输入管线）
        mid = ws.send("Input.insertText", {"text": sentence})
        ws.recv_until(mid)
        time.sleep(2.6)
        dbg = evaluate(ws, "JSON.stringify(window.__EW_DEBUG)", context_id=iso_id)
        dbg = json.loads(dbg) if isinstance(dbg, str) else (dbg or {})
        edits = dbg.get("lastEdits", [])
        rects = dbg.get("lastRects", [])
        target = dbg.get("lastTarget") or {}
        read_expr = f"document.querySelector('{sel}').{'value' if kind == 'textarea' else 'innerText'}"
        landed = evaluate(ws, read_expr) or ""
        typed_ok = "immediatly" in landed
        report[label] = {
            "edits": len(edits), "rects": len(rects), "engine": dbg.get("engine"),
            "ms": dbg.get("elapsedMs"),
            "rect_source": dbg.get("rectSource"),
            "target": target,
            "active_element": active,
            "typed_text_len": len(landed),
            "typed_into_expected": typed_ok,
            "rect_list": rects[:3],
            "notes_all": dbg.get("notes", []),
            "token_retry": {
                "had_skip_before_success": any("no token" in n for n in dbg.get("notes", [])),
                "explain": "先无 token 跳过一次、写入 token 后重试成功 —— 重试过程照实留档，别看成一次就通"
            },
        }

        if edits:
            read = (lambda: evaluate(ws, f"document.querySelector('{sel}').{'value' if kind=='textarea' else 'innerText'}"))
            before = (read() or "")
            accept_ret = evaluate(ws, "window.__EW_TEST__.acceptByOriginal('immediatly')", context_id=iso_id)
            time.sleep(1.2)
            after = (read() or "")
            undo_ret = evaluate(ws, "window.__EW_TEST__.undo()", context_id=iso_id)
            time.sleep(1.2)
            undone = (read() or "")

            # 硬断言：每条写清判据，不用「看起来对」的布尔
            a_has_new = "immediately" in after
            a_no_old = "immediatly" not in after
            u_eq_before = (undone == before)
            u_len_eq = (len(undone) == len(before))
            changed_vs_before = (after != before)

            report[label].update({
                # 三态原文全给，不截断（上一版截 70 字符正好把改动点切掉，证据看起来三态一样）
                "before": before, "before_len": len(before),
                "after": after, "after_len": len(after),
                "undone": undone, "undone_len": len(undone),
                "diff_window": diff_window(before, after),
                "compared": "after vs before（accept）；undone vs before（undo）",
                "assertions": {
                    "after_has_immediately": a_has_new,
                    "after_no_immediatly": a_no_old,
                    "after_differs_from_before": changed_vs_before,
                    "undone_equals_before": u_eq_before,
                    "undone_len_equals_before": u_len_eq,
                    "accept_api_returned": bool(accept_ret),
                    "undo_api_returned": bool(undo_ret),
                    # 本轮新增：证明 rects 真的来自目标元素，而不是上一轮 textarea 的残留
                    "rects_positive": len(rects) > 0,
                    "rect_source_reported": dbg.get("rectSource") in ("range", "child-union", "element", "mirror"),
                    "target_is_expected": bool(target.get("contenteditable")) == (kind == "contenteditable"),
                    "typed_into_expected": typed_ok,
                },
                "accept_changed": a_has_new and a_no_old and changed_vs_before,
                "undo_restored": u_eq_before and u_len_eq,
            })

    print(json.dumps(report, ensure_ascii=False, indent=2))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ext-probe-report.json")
    open(out, "w").write(json.dumps(report, ensure_ascii=False, indent=2))
    print("报告:", out)
    need = ["rects_positive", "rect_source_reported", "target_is_expected",
            "typed_into_expected", "accept_changed", "undo_restored"]
    failures = {}
    for label, v in report.items():
        bad = [k for k in need if not (v.get(k) if k in ("accept_changed", "undo_restored")
                                       else (v.get("assertions", {}) or {}).get(k))]
        if v.get("edits", 0) <= 0:
            bad.append("edits_positive")
        if bad:
            failures[label] = bad
    ok = not failures
    print("判据:", {label: {k: (v.get(k) if k in ("accept_changed", "undo_restored")
                                else (v.get("assertions", {}) or {}).get(k))
                            for k in need} for label, v in report.items()})
    if failures:
        print("未过项:", failures)
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
