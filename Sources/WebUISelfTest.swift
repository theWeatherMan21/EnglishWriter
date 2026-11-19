// WebUISelfTest.swift — 静默验证 WebView 侧栏：不建窗口、不上屏、不截屏
//
// 爹地 11-19：测试请静默，非必要不截图。所以这里用离屏 WKWebView 加载真实的
// web/sidebar/index.html，喂一份固定 payload，再用 JS 回读 DOM 结构 —— 全是数值断言。
//
// 一条命令：./build/英文写作助手 --webui

import AppKit
import WebKit

@MainActor
final class WebUISelfTest: NSObject, WKNavigationDelegate {

    static let shared = WebUISelfTest()
    private var web: WKWebView?
    private var loaded = false
    private var done: ((Bool) -> Void)?

    nonisolated static func run(_ argv: [String]) -> Int32 {
        // 不能用信号量等主线程：check() 在主 actor 上跑，主线程一堵就永远不返回。
        // 改成「泵 runloop」直到完成。
        var done = false
        var ok = false
        Task { @MainActor in
            ok = await shared.check()
            done = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !done { print("FAIL 超时（30s）") }
        return ok ? 0 : 1
    }

    @MainActor
    func check() async -> Bool {
        guard let dir = Sidebar.webDir() else {
            print("FAIL web/sidebar 目录缺失")
            return false
        }
        let cfg = WKWebViewConfiguration()
        let w = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 620), configuration: cfg)
        w.navigationDelegate = self
        web = w
        w.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)

        // 等加载
        for _ in 0..<40 where !loaded {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard loaded else { print("FAIL 页面 4 秒内没加载完"); return false }
        print("  页面已加载（离屏，无窗口）")

        let payload = """
        {"overall":72,"band":"需注意 · 72","tone":"正式（次要 友好，本地）",
         "dims":[{"name":"正确性","value":72,"note":"拼写 1"},{"name":"清晰度","value":58,"note":"冗长 2"},
                 {"name":"吸引力","value":81,"note":"多样性 74%"},{"name":"表达","value":75,"note":"中性"}],
         "tabs":[{"name":"全部","n":3},{"name":"正确性","n":1},{"name":"清晰度","n":1},{"name":"表达","n":1}],
         "groups":[{"title":"正确性 · 拼写与语法","type":"grammar","items":[
                     {"id":0,"original":"immediatly","replacement":"immediately","reason":"拼写错误"}]},
                   {"title":"清晰度 · 精简表达","type":"clarity","items":[
                     {"id":1,"original":"In order to","replacement":"to","reason":"表达可以更简洁"}]},
                   {"title":"表达 · 风格","type":"style","items":[
                     {"id":2,"original":"very unique","replacement":"unique","reason":"风格建议"}]}]}
        """
        _ = await js("EW.render(\(payload))")
        try? await Task.sleep(nanoseconds: 300_000_000)

        var results: [(String, Bool, String)] = []
        func expect(_ name: String, _ cond: Bool, _ detail: String) { results.append((name, cond, detail)) }

        let scoreText = await js("document.getElementById('score').textContent") as? String ?? ""
        expect("分数写入", scoreText == "72", "score=\(scoreText)")

        let band = await js("document.getElementById('band').textContent") as? String ?? ""
        expect("档位文案", band.contains("需注意"), "band=\(band)")

        let dimCount = await js("document.querySelectorAll('#dims .dim').length") as? Int ?? 0
        expect("四维数量", dimCount == 4, "dims=\(dimCount)")

        let tabCount = await js("document.querySelectorAll('#tabs .tab').length") as? Int ?? 0
        expect("四个分类 tab", tabCount == 4, "tabs=\(tabCount)")

        let rows = await js("document.querySelectorAll('.row').length") as? Int ?? 0
        expect("建议行数量", rows == 3, "rows=\(rows)")

        let groups = await js("document.querySelectorAll('.group').length") as? Int ?? 0
        expect("分组数量", groups == 3, "groups=\(groups)")

        let oldBlocks = await js("document.querySelectorAll('.old').length") as? Int ?? 0
        expect("旧词红底块", oldBlocks == 3, "old=\(oldBlocks)")

        let newBlocks = await js("document.querySelectorAll('.new').length") as? Int ?? 0
        expect("新词绿底块", newBlocks == 3, "new=\(newBlocks)")

        // 分层必须肉眼可分：卡片底 #F7F8FA vs 面板 #FFFFFF，且卡片有阴影
        let rowBg = await js("getComputedStyle(document.querySelector('.row')).backgroundColor") as? String ?? ""
        let bodyBg = await js("getComputedStyle(document.body).backgroundColor") as? String ?? ""
        expect("卡片底色 #F7F8FA", rowBg.contains("247, 248, 250"), rowBg)
        expect("面板底 #FFFFFF", bodyBg.contains("255, 255, 255"), bodyBg)
        expect("卡片底色与面板不同", rowBg != bodyBg, "\(rowBg) vs \(bodyBg)")
        let shadow = await js("getComputedStyle(document.querySelector('.row')).boxShadow") as? String ?? ""
        expect("卡片有阴影", shadow.contains("rgba") && shadow != "none", shadow)

        let tone = await js("document.getElementById('tone').textContent") as? String ?? ""
        expect("语气行", tone.contains("正式"), "tone=\(tone)")

        // 过滤：点「语法」只剩 1 组
        _ = await js("EW.pick(1)")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let filtered = await js("document.querySelectorAll('.group').length") as? Int ?? 0
        expect("分类过滤生效", filtered == 1, "groups after pick=\(filtered)")

        // 转义：文档里出现 <img onerror> 不许被当标签执行
        let evil: [String: Any] = ["overall": 1, "band": "x", "tone": "", "dims": [], "tabs": [],
            "groups": [["title": "t", "type": "grammar",
                        "items": [["id": 0, "original": "<img src=x onerror=alert(1)>",
                                   "replacement": "ok", "reason": "r"]]]]]
        if let d = try? JSONSerialization.data(withJSONObject: evil),
           let evilJSON = String(data: d, encoding: .utf8) {
            _ = await js("EW.render(\(evilJSON))")
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let injected = await js("document.querySelectorAll('.row img').length") as? Int ?? -1
        expect("HTML 被转义（无注入节点）", injected == 0, "img nodes=\(injected)")

        // 离屏快照：不弹窗、不抓屏，只把 WKWebView 自己的位图写盘（知澜要看 tokens 有没有治好毛坯感）
        if let w = web {
            // 快照要拍「真实数据」，不能拍刚才那组 XSS 转义测试数据（踩过：拍出来是 t/x/r 噪声）
            _ = await js("EW.filter = null")
            _ = await js("EW.render(\(payload))")
            try? await Task.sleep(nanoseconds: 300_000_000)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let cfg = WKSnapshotConfiguration()
            cfg.rect = CGRect(x: 0, y: 0, width: 360, height: 720)
            let img: NSImage? = await withCheckedContinuation { cont in
                w.takeSnapshot(with: cfg) { image, _ in cont.resume(returning: image) }
            }
            if let img, let tiff = img.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("qa/evidence/web-sidebar.png")
                try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                                         withIntermediateDirectories: true)
                try? png.write(to: out)
                print("  离屏快照：\(out.path)（\(png.count) 字节，未弹窗未抓屏）")
            }
        }

        var pass = 0
        for (n, ok, d) in results {
            print(ok ? "PASS  \(n)  — \(d)" : "FAIL  \(n)  — \(d)")
            if ok { pass += 1 }
        }
        print("=== WebUI 汇总：PASS \(pass) / FAIL \(results.count - pass) ===")

        let evidence: [String: Any] = ["checks": results.map { ["name": $0.0, "pass": $0.1, "detail": $0.2] }]
        if let d = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
            let p = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("qa/evidence/webui-selftest.json")
            try? FileManager.default.createDirectory(at: p.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.write(to: p)
            print("证据：\(p.path)")
        }
        return pass == results.count
    }

    private func js(_ code: String) async -> Any? {
        await withCheckedContinuation { cont in
            web?.evaluateJavaScript(code) { v, _ in cont.resume(returning: v) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }
}
