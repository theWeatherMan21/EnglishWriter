#!/usr/bin/env python3
"""card-btn-probe.py — 卡片按钮尺寸的硬验收（不看图，量数）

爹地 11-23 报「接受按钮过小」。这条探针把判据量成数字：
  · 每个按钮高度 ≥ 36pt（次按钮） / 接受按钮 ≥ 40pt
  · 接受按钮宽度 ≥ 卡片宽度的 30%
  · 按钮之间不重叠

做法：headless Chrome 打开 web/card/index.html，喂一份样例数据，
读每个按钮的 getBoundingClientRect()。全程无窗口。
用法：python3 qa/card-btn-probe.py
"""
import json, os, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "qa", "chrome-ext-probe"))
import drive

CHROME_CANDIDATES = [
    os.path.join(ROOT, ".tools", "chrome-for-testing", "chrome-mac-arm64",
                 "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing"),
    "/Applications/Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
]
PORT = 9241


def chrome_path():
    for p in CHROME_CANDIDATES:
        if os.path.exists(p):
            return p
    return None


def main():
    exe = chrome_path()
    if not exe:
        print("SKIP: 本机没有 Chrome for Testing（不影响 CSS 本身，装好后可跑）")
        return 0
    profile = os.path.expanduser("~/.hermes/cache/scratch/card-probe-profile")
    shutil.rmtree(profile, ignore_errors=True)
    page = "file://" + os.path.join(ROOT, "web", "card", "index.html")
    proc = subprocess.Popen(
        [exe, "--headless=new", f"--remote-debugging-port={PORT}",
         f"--user-data-dir={profile}", "--no-first-run", "--no-default-browser-check",
         "--disable-gpu", page],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    drive.DEBUG_PORT = PORT
    try:
        ws = None
        for _ in range(40):
            try:
                ts = [t for t in drive.targets() if t.get("type") == "page"]
                if ts:
                    ws = drive.WS(ts[0]["webSocketDebuggerUrl"])
                    break
            except Exception:
                pass
            time.sleep(0.25)
        if not ws:
            print("FAIL: 连不上 headless Chrome")
            return 1
        # 等卡片脚本就绪，喂一份样例
        for _ in range(40):
            if drive.evaluate(ws, "typeof EWCard !== 'undefined'"):
                break
            time.sleep(0.1)
        drive.evaluate(ws, """EWCard.card({color:'#D93025',category:'语法',before:'I ',original:'have send',
            after:' the report.',replacement:'have sent',reason:'完成时用过去分词',allowDict:true,canRewrite:true})""")
        time.sleep(0.4)
        data = drive.evaluate(ws, """JSON.stringify((() => {
            const card = document.getElementById('card').getBoundingClientRect();
            const btns = [...document.querySelectorAll('.btn')].map(b => {
              const r = b.getBoundingClientRect();
              const prim = b.classList.contains('primary');
              return {text: (b.getAttribute('data-act') || b.textContent || '').trim().slice(0,12),
                      h: Math.round(r.height), w: Math.round(r.width), primary: prim};
            });
            return {cardW: Math.round(card.width), cardH: Math.round(card.height), btns};
        })())""")
        d = json.loads(data)
        fails = []
        print(f"卡片 {d['cardW']}x{d['cardH']}，按钮 {len(d['btns'])} 个")
        for b in d["btns"]:
            need = 40 if b["primary"] else 36
            mark = "OK " if b["h"] >= need else "FAIL"
            print(f"  {mark} {b['text'] or '(按钮)':<12} 高 {b['h']:>3}pt 宽 {b['w']:>3}pt"
                  f"{' [接受]' if b['primary'] else ''}  要求 ≥{need}pt")
            if b["h"] < need:
                fails.append(f"{b['text']} 高度 {b['h']} < {need}")
        prim = [b for b in d["btns"] if b["primary"]]
        if not prim:
            fails.append("没有找到接受按钮（.btn.primary）")
        else:
            ratio = prim[0]["w"] / d["cardW"]
            print(f"  接受按钮占卡片宽度 {ratio*100:.1f}%（要求 ≥30%）")
            if ratio < 0.30:
                fails.append(f"接受按钮只占 {ratio*100:.1f}% < 30%")
        try:
            ws.sock.close()
        except Exception:
            pass
        if fails:
            print("RESULT: FAIL " + "; ".join(fails))
            return 1
        print("RESULT: PASS")
        return 0
    finally:
        proc.terminate()
        shutil.rmtree(profile, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
