// SidebarWeb.swift — 侧栏改由 WKWebView 渲染（HTML/CSS，不再手算 AppKit 坐标）
//
// 原因（知澜 11-19 的架构决断，爹地原话「UI 也是毛坯」）：
//   AppKit 手绘做不出克制感 —— 圆角/阴影/字距全靠手算坐标，每个控件各写各的尺寸。
//   换成 HTML/CSS 后：设计令牌一处定义、布局交给浏览器、动画几行 CSS，
//   而且和浏览器扩展共用同一套 UI 代码。
//
// 数据通路：Swift 侧把 {score, tabs, groups, tone} 编成 JSON →
//   evaluateJavaScript("EW.render(payload)")；HTML 侧的按钮回调 →
//   WKScriptMessageHandler → Swift 执行 accept / dismiss / jump / acceptAll。

import AppKit
import WebKit

final class Sidebar: NSPanel {

    static let shared = Sidebar()

    var onAccept: ((DiffItem) -> Void)?
    var onDismiss: ((DiffItem) -> Void)?
    var onJump: ((DiffItem) -> Void)?
    var onAcceptAll: (() -> Void)?

    private var web: WKWebView!
    private var items: [DiffItem] = []
    private var score = WritingScore()
    private var dismissed = Set<String>()
    private var tone = ""

    private let width: CGFloat = 360

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 620),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "bridge")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: 620), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        web.loadHTMLString(Self.html, baseURL: nil)
        contentView = web
    }

    override var canBecomeKey: Bool { true }

    // MARK: 对外（与旧 AppKit 侧栏同签名，调用方不用改）

    func present(items: [DiffItem], score: WritingScore, at point: NSPoint? = nil) {
        self.items = items
        self.score = score
        dismissed.removeAll()
        if !isVisible || point != nil {
            var origin = NSPoint(x: 0, y: 0)
            if let p = point {
                origin = NSPoint(x: p.x - width / 2, y: p.y - 40)
            } else if let screen = NSScreen.screens.first?.visibleFrame {
                origin = NSPoint(x: screen.maxX - width - 24, y: screen.midY - frame.height / 2)
            }
            setFrameOrigin(origin)
        }
        orderFrontRegardless()
        push()
    }

    func setTone(_ s: String) { tone = s; push() }

    @MainActor
    func select(start: Int) {
        let idx = items.firstIndex { $0.start == start } ?? -1
        web.evaluateJavaScript("EW.focus(\(idx))", completionHandler: nil)
    }

    @MainActor
    func showSaved() { web.evaluateJavaScript("EW.saved()", completionHandler: nil) }

    func orderOutAndClear() { orderOut(nil) }

    static func bandText(overall: Int) -> String {
        let band = overall >= 80 ? "良好" : (overall >= 50 ? "需注意" : "需改进")
        return "\(band) · \(overall)"
    }

    // MARK: 数据 → JSON

    private func payload() -> String {
        let live = items.filter { !dismissed.contains(key($0)) }
        func count(_ t: String?) -> Int {
            guard let t else { return live.count }
            if t == "grammar" { return live.filter { $0.type == "spelling" || $0.type == "grammar" }.count }
            return live.filter { $0.type == t }.count
        }
        let groups: [[String: Any]] = ["grammar", "clarity", "style"].compactMap { t in
            let g = live.filter { t == "grammar" ? ($0.type == "spelling" || $0.type == "grammar") : ($0.type == t) }
            guard !g.isEmpty else { return nil }
            let title = t == "grammar" ? "正确性 · 拼写与语法" : (t == "clarity" ? "清晰度 · 精简表达" : "表达 · 风格")
            return ["title": title, "type": t, "items": g.enumerated().map { i, it in
                ["id": items.firstIndex { $0.start == it.start && $0.length == it.length } ?? i,
                 "original": it.original, "replacement": it.replacement,
                 "reason": it.reason.isEmpty ? defaultReason(it.type) : it.reason]
            }]
        }
        let obj: [String: Any] = [
            "overall": score.overall,
            "band": Self.bandText(overall: score.overall),
            "tone": tone,
            "dims": [
                ["name": "正确性", "value": score.correctness, "note": score.correctnessNote],
                ["name": "清晰度", "value": score.clarity, "note": score.clarityNote],
                ["name": "吸引力", "value": score.engagement, "note": score.engagementNote],
                ["name": "表达", "value": score.delivery, "note": score.deliveryNote],
            ],
            "tabs": [["name": "全部", "n": count(nil)], ["name": "语法", "n": count("grammar")],
                     ["name": "清晰度", "n": count("clarity")], ["name": "表达", "n": count("style")]],
            "groups": groups,
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    private func push() {
        web.evaluateJavaScript("EW.render(\(payload()))", completionHandler: nil)
    }

    private func key(_ it: DiffItem) -> String { "\(it.start)-\(it.length)-\(it.replacement)" }

    private func defaultReason(_ type: String) -> String {
        switch type {
        case "spelling": return "拼写错误"
        case "grammar": return "语法问题"
        case "clarity": return "表达可以更简洁"
        default: return "风格建议"
        }
    }
}

extension Sidebar: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        let id = (body["id"] as? Int) ?? -1
        switch action {
        case "accept":
            if items.indices.contains(id) { onAccept?(items[id]); dismissed.insert(key(items[id])); push(); showSaved() }
        case "dismiss":
            if items.indices.contains(id) { onDismiss?(items[id]); dismissed.insert(key(items[id])); push() }
        case "jump":
            if items.indices.contains(id) { onJump?(items[id]) }
        case "acceptAll":
            onAcceptAll?(); showSaved()
        case "close":
            orderOut(nil)
        default:
            break
        }
    }
}

// MARK: - HTML（令牌来自 Tokens.cssVariables，一处定义）

extension Sidebar {
    static var html: String {
        """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">
        <style>
        \(Tokens.cssVariables)
        * { box-sizing: border-box; -webkit-user-select: none; }
        body { margin:0; font: var(--f-body)/1.45 -apple-system, "SF Pro Text", "PingFang SC", sans-serif;
               color: var(--text); background: var(--bg); }
        .wrap { padding: var(--s4); display:flex; flex-direction:column; gap: var(--s4); height:100vh; }
        .head { display:flex; gap: var(--s4); align-items:flex-start; }
        .ring { position:relative; width:104px; height:104px; flex:0 0 104px; }
        .ring svg { transform: rotate(-90deg); }
        .ring .num { position:absolute; inset:0; display:flex; flex-direction:column;
                     align-items:center; justify-content:center; }
        .ring .num b { font-size: var(--f-score); font-weight: 600; letter-spacing:-0.5px; }
        .ring .num span { font-size: var(--f-caption); color: var(--text-muted); margin-top:2px; white-space:nowrap; }
        .dims { flex:1; display:flex; flex-direction:column; gap: var(--s2); }
        .dim { display:grid; grid-template-columns: 52px 28px 1fr; gap: var(--s2);
               align-items:center; font-size: var(--f-secondary); }
        .dim .n { color: var(--text-muted); }
        .dim .v { font-weight:600; font-variant-numeric: tabular-nums; text-align:right; }
        .dim .bar { height:4px; border-radius:999px; background: var(--border); overflow:hidden; }
        .dim .bar i { display:block; height:100%; border-radius:999px; }
        .dim .note { grid-column: 1 / -1; font-size: var(--f-caption); color: var(--text-muted); margin-top:-2px; }
        .tabs { display:flex; gap: var(--s2); align-items:center; }
        .tab { flex:1; text-align:center; cursor:pointer; padding-top: var(--s1); }
        .tab i { display:block; height:3px; border-radius:999px; margin-bottom: var(--s1); opacity:.35; }
        .tab.on i { opacity:1; }
        .tab span { font-size: var(--f-secondary); color: var(--text-muted); }
        .tab.on span { color: var(--text); font-weight:600; }
        .tab b { font-variant-numeric: tabular-nums; font-weight:600; margin-left:2px; }
        .allbtn { font-size: var(--f-secondary); border:1px solid var(--border); background:var(--bg);
                  border-radius: var(--r-control); padding: 4px 8px; cursor:pointer; color: var(--text); }
        .list { flex:1; overflow-y:auto; display:flex; flex-direction:column; gap: var(--s2); }
        .group { display:flex; flex-direction:column; gap: var(--s1); }
        .ghead { display:flex; align-items:center; gap:6px; font-size: var(--f-secondary);
                 font-weight:600; margin-top: var(--s2); }
        .ghead em { width:6px; height:6px; border-radius:999px; font-style:normal; }
        .ghead span { color: var(--text-muted); font-weight:500; }
        .row { border:1px solid var(--border); border-radius: var(--r-card); background: var(--bg);
               box-shadow: var(--shadow-card); padding: var(--s2) var(--s3); display:flex;
               flex-direction:column; gap:4px; cursor:pointer; transition: background .12s; }
        .row:hover { background: var(--bg-subtle); }
        .row.flash { background:#FFE3EC; }
        .line { font-size: var(--f-body); }
        .old { color:#fff; background: var(--correctness); text-decoration: line-through; border-radius:3px; padding:0 2px; }
        .new { color:#fff; background: var(--engagement); font-weight:600; border-radius:3px; padding:0 2px; }
        .reason { font-size: var(--f-caption); color: var(--text-muted); }
        .acts { display:flex; gap:var(--s1); justify-content:flex-end; }
        .btn { font-size: var(--f-caption); border-radius: var(--r-control); border:1px solid var(--border);
               background: var(--bg); padding:3px 8px; cursor:pointer; }
        .btn.primary { background: var(--brand); border-color: var(--brand); color:#fff; font-weight:600; }
        .foot { font-size: var(--f-caption); color: var(--text-muted); }
        .saved { position:absolute; top:10px; right:14px; font-size: var(--f-caption); color: var(--engagement);
                 font-weight:600; opacity:0; transition: opacity .2s; }
        .saved.on { opacity:1; }
        </style></head>
        <body>
        <div class="wrap">
          <div class="saved" id="saved">已保存</div>
          <div class="head">
            <div class="ring">
              <svg width="92" height="92">
                <circle cx="46" cy="46" r="41" fill="none" stroke="#E5E7EB" stroke-width="6"/>
                <circle id="arc" cx="46" cy="46" r="41" fill="none" stroke-width="6"
                        stroke-linecap="round" stroke-dasharray="257.6" stroke-dashoffset="257.6"/>
              </svg>
              <div class="num"><b id="score">—</b><span id="band"></span></div>
            </div>
            <div class="dims" id="dims"></div>
          </div>
          <div class="tabs" id="tabs"></div>
          <div class="list" id="list"></div>
          <div class="foot" id="tone"></div>
        </div>
        <script>
        // 所有来自文档的文本先转义再用 innerHTML 拼接（用户文档里可能正好含 < > &）
        const esc = t => String(t == null ? '' : t).replace(/[&<>"']/g, c =>
          ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        const typeColor = t => t==='clarity' ? '#4A6EDE' : (t==='style' ? '#7E57C2' : '#EE1437');

        const EW = {
          data: null, filter: null,
          render(d) {
            this.data = d;
            document.getElementById('score').textContent = d.overall;
            document.getElementById('band').textContent = d.band;
            const pct = Math.max(0, Math.min(1, d.overall/100));
            const arc = document.getElementById('arc');
            arc.style.stroke = pct>=.8 ? '#2E7D32' : (pct>=.5 ? '#F59E0B' : '#EE1437');
            arc.style.strokeDashoffset = (257.6 * (1-pct)).toFixed(1);

            document.getElementById('dims').innerHTML = d.dims.map(x => {
              const sev = x.value>=80 ? '#2E7D32' : (x.value>=50 ? '#F59E0B' : '#EE1437');
              const cat = {'正确性':'#EE1437','清晰度':'#4A6EDE','吸引力':'#2E7D32','表达':'#7E57C2'}[x.name] || '#027E6F';
              return `<div class="dim"><span class="n">${esc(x.name)}</span>
                <span class="v" style="color:${sev}">${x.value}</span>
                <span class="bar"><i style="width:${x.value}%;background:${cat}"></i></span>
                <span class="note">${esc(x.note||'')}</span></div>`;
            }).join('');

            const colors = ['#1F2328','#EE1437','#4A6EDE','#7E57C2'];
            document.getElementById('tabs').innerHTML = d.tabs.map((t,i) =>
              `<div class="tab ${(this.filter===null&&i===0)||this.filter===['grammar','clarity','style'][i-1]?'on':''}"
                    onclick="EW.pick(${i})"><i style="background:${colors[i]}"></i>
               <span>${esc(t.name)}<b>${t.n}</b></span></div>`).join('')
              + `<button class="allbtn" onclick="EW.post({action:'acceptAll'})">全部接受</button>`;

            const list = document.getElementById('list');
            const groups = d.groups.filter(g => !this.filter || g.type===this.filter);
            list.innerHTML = groups.map(g => `<div class="group">
              <div class="ghead"><em style="background:${typeColor(g.type)}"></em>
                ${esc(g.title)} <span>${g.items.length}</span></div>
              ${g.items.map(it => `<div class="row" data-id="${it.id}" onclick="EW.post({action:'jump',id:${it.id}})">
                  <div class="line"><span class="old">${esc(it.original)}</span> → <span class="new">${esc(it.replacement)}</span></div>
                  <div class="reason">${esc(it.reason)}</div>
                  <div class="acts">
                    <button class="btn" onclick="event.stopPropagation();EW.post({action:'dismiss',id:${it.id}})">忽略</button>
                    <button class="btn primary" onclick="event.stopPropagation();EW.post({action:'accept',id:${it.id}})">接受</button>
                  </div></div>`).join('')}
            </div>`).join('') || '<div class="foot">没有更多建议</div>';

            document.getElementById('tone').textContent = d.tone ? ('语气：'+d.tone) : '';
          },
          pick(i) { this.filter = i===0 ? null : ['grammar','clarity','style'][i-1]; this.render(this.data); },
          focus(i) {
            const el = document.querySelector(`.row[data-id="${i}"]`);
            if (!el) return;
            el.scrollIntoView({block:'nearest'});
            el.classList.add('flash');
            setTimeout(()=>el.classList.remove('flash'), 900);
          },
          saved() {
            const s = document.getElementById('saved');
            s.classList.add('on');
            setTimeout(()=>s.classList.remove('on'), 1500);
          },
          post(m) { window.webkit.messageHandlers.bridge.postMessage(m); }
        };
        window.EW = EW;
        </script></body></html>
        """
    }
}
