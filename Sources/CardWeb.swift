// CardWeb.swift — 悬停卡片也走同一套 HTML/CSS（与侧栏、与将来浏览器扩展共用）
//
// 为什么卡片不能用 AppKit 手绘：它是用户一天看几十次的东西，圆角/阴影/字距差 0.5pt 就是「毛坯」。
// 这里复用 Tokens.cssVariables，和侧栏同一份设计令牌；结构按 Grammarly 实测：
//   类别行 → 上下文句子（旧词红删除线 / 新词绿底） → 分隔线 → 加入词典 / 忽略 / ···
// 点句子 = 接受；「···」里是 改写 / 语气。

import AppKit
import WebKit

final class CardWeb: NSPanel {

    static let shared = CardWeb()
    static var globallySilent = false

    private var web: WKWebView!
    private var onAccept: (() -> Void)?
    private var onIgnore: (() -> Void)?
    private var onDict: (() -> Void)?
    private var onRewrite: (() -> Void)?
    private var onTone: (() -> Void)?
    private var anchor: CGRect = .zero

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 192, height: 140),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false            // 阴影交给 CSS，两套阴影会打架
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .transient]

        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "bridge")
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 192, height: 140), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        if let dir = Self.cardDir() {
            web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }
        contentView = web
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(category: String, color: String, before: String, original: String,
              replacement: String, after: String, anchor: CGRect,
              allowDict: Bool,
              onAccept: @escaping () -> Void, onIgnore: @escaping () -> Void,
              onDict: (() -> Void)?, onRewrite: (() -> Void)?, onTone: (() -> Void)?) {
        guard !Self.globallySilent else { return }
        self.onAccept = onAccept
        self.onIgnore = onIgnore
        self.onDict = onDict
        self.onRewrite = onRewrite
        self.onTone = onTone
        self.anchor = anchor
        let payload: [String: Any] = [
            "category": category, "color": color,
            "before": before, "original": original, "replacement": replacement, "after": after,
            "allowDict": allowDict,
            "canRewrite": onRewrite != nil,
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload),
           let s = String(data: d, encoding: .utf8) {
            web.evaluateJavaScript("EWCard.card(\(s))", completionHandler: nil)
        }
        // 尺寸由内容决定，先按宽 192 放，HTML 回传实际高度后再定位置
        setContentSize(NSSize(width: 192, height: frame.height))
        place()
        orderFrontRegardless()
    }

    /// HTML 回传内容高度 → 重新定位（贴词下方，允许盖住下一行）
    func resizeTo(height: CGFloat) {
        guard height > 20 else { return }
        setContentSize(NSSize(width: 192, height: height))
        place()
    }

    private func place() {
        let h = NSScreen.screens.first?.frame.height ?? 900
        let x = anchor.minX
        let yTop = anchor.maxY + 6
        setFrame(NSRect(x: x, y: h - yTop - frame.height, width: 192, height: frame.height), display: false)
    }

    func dismiss() { orderOut(nil) }

    static func cardDir() -> URL? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web/card"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) { return r }
        let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web/card")
        if FileManager.default.fileExists(atPath: repo.appendingPathComponent("index.html").path) { return repo }
        return nil
    }
}

extension CardWeb: WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let a = body["action"] as? String else { return }
        switch a {
        case "accept": onAccept?(); dismiss()
        case "ignore": onIgnore?(); dismiss()
        case "dict": onDict?(); dismiss()
        case "rewrite": onRewrite?(); dismiss()
        case "tone": onTone?(); dismiss()
        case "height": if let h = body["h"] as? Double { resizeTo(height: CGFloat(h)) }
        default: break
        }
    }
}

extension CardWeb {
    static var html: String {
        """
        <!doctype html><html lang="zh"><head><meta charset="utf-8"><style>
        \(Tokens.cssVariables)
        * { box-sizing:border-box; -webkit-user-select:none; }
        body { margin:0; background:transparent; font: var(--f-secondary)/1.45 -apple-system,"PingFang SC",sans-serif; color:var(--text); }
        .card { background:var(--bg); border-radius:var(--r-card); box-shadow:var(--shadow-popover);
                padding: var(--s3); display:flex; flex-direction:column; gap: var(--s2); }
        .cat { font-size: var(--f-caption); color: var(--text-muted); display:flex; align-items:center; gap:6px; }
        .cat em { width:6px; height:6px; border-radius:999px; font-style:normal; }
        .sent { font-size: var(--f-body); line-height:1.5; cursor:pointer; }
        .sent:hover .new { filter: brightness(1.05); }
        .old { color:#fff; background:var(--correctness); text-decoration:line-through; border-radius:3px; padding:0 3px; }
        .new { color:#fff; background:var(--engagement); font-weight:600; border-radius:3px; padding:0 3px; }
        .hr { height:1px; background:var(--border); margin: 2px 0; }
        .acts { display:flex; gap: var(--s1); justify-content:flex-end; }
        .btn { font-size: var(--f-caption); border:1px solid var(--border); background:var(--bg);
               border-radius: var(--r-control); padding:3px 8px; cursor:pointer; color:var(--text); }
        </style></head><body>
        <div class="card" id="card">
          <div class="cat"><em id="dot"></em><span id="cat"></span></div>
          <div class="sent" id="sent" onclick="EW.post({action:'accept'})"></div>
          <div class="hr"></div>
          <div class="acts">
            <button class="btn" id="dict" onclick="EW.post({action:'dict'})">加入词典</button>
            <button class="btn" onclick="EW.post({action:'ignore'})">忽略</button>
            <button class="btn" id="more" onclick="EW.more()">···</button>
          </div>
        </div>
        <script>
        const esc = t => String(t==null?'':t).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
        const EW = {
          canRewrite:false,
          card(d) {
            this.canRewrite = d.canRewrite;
            document.getElementById('dot').style.background = d.color;
            document.getElementById('cat').textContent = d.category;
            document.getElementById('sent').innerHTML =
              esc(d.before) + `<span class="old">${esc(d.original)}</span> ` +
              `<span class="new">${esc(d.replacement)}</span>` + esc(d.after);
            document.getElementById('dict').style.display = d.allowDict ? '' : 'none';
            this.report();
          },
          more() {
            // 「···」= 改写 / 语气（模型可用时才有）
            if (!this.canRewrite) { EW.post({action:'ignore'}); return; }
            EW.post({action:'rewrite'});
          },
          report() { requestAnimationFrame(() => {
              const h = document.getElementById('card').getBoundingClientRect().height + 8;
              window.webkit.messageHandlers.bridge.postMessage({action:'height', h:h});
          }); },
          post(m) { window.webkit.messageHandlers.bridge.postMessage(m); }
        };
        window.EW = EW;
        </script></body></html>
        """
    }
}
