// SidebarSnapshot.swift — 侧栏离屏快照（`--sidebar-snapshot out/sidebar.png`）
//
// 纪律（同 SettingsSnapshot）：
//   1) 不上屏：窗口放 (-6000,-6000)，不 orderFront、不 activate、不 screencapture。
//   2) 不造假数据：文本是真英文句，DiffItem 的偏移由 range(of:) 现算（算不到直接 FAIL），
//      分数由真 `Scorer.score` 算出，不是手填数字。
//   3) 与上屏共用一份 `Sidebar.payload` + `web/sidebar/*`，所以「截图好看、上屏另一套」不可能发生。
//
// 用法：./build/英文写作助手 --sidebar-snapshot out/sidebar.png

import AppKit
import WebKit

@MainActor
enum SidebarSnapshot {

    static let sampleText = """
    Hi Anna,

    Thanks for your update. There is many reasons why we should sent the revised draft today, \
    and I recieve the booking confirmation yesterday. In order to move forward with the shipment, \
    we need to make a decision about the vessel before the cut-off.

    Please kindly confirm the ETD and the number of containers before Friday.

    Best regards,
    Wanyi
    """

    /// 假夹具一律从这里来：偏移现算，算不到就 FAIL（绝不手写 offset）
    static func sampleItems(_ text: String = sampleText) -> (items: [DiffItem], missing: [String]) {
        let specs: [(String, String, String, String)] = [
            ("There is many", "There are many", "grammar", "主谓一致：reasons 是复数，用 There are"),
            ("should sent", "should send", "grammar", "情态动词后接动词原形"),
            ("recieve", "receive", "spelling", "拼写错误"),
            ("In order to", "To", "clarity", "「In order to」可以直接说 To，更简洁"),
            ("make a decision", "decide", "clarity", "动词化表达，decide 更直接"),
            ("Please kindly", "Please", "style", "Please 与 kindly 叠用显得冗余"),
        ]
        let ns = text as NSString
        var out: [DiffItem] = []
        var missing: [String] = []
        for (original, replacement, type, reason) in specs {
            let r = ns.range(of: original)
            if r.location == NSNotFound { missing.append(original); continue }
            out.append(DiffItem(start: r.location, length: r.length, original: original,
                                replacement: replacement, type: type, reason: reason))
        }
        return (out, missing)
    }

    static func run(_ argv: [String]) -> Int32 {
        let out = argv.firstIndex(of: "--sidebar-snapshot").flatMap {
            $0 + 1 < argv.count ? argv[$0 + 1] : nil
        } ?? (FileManager.default.currentDirectoryPath + "/out/sidebar.png")

        guard let dir = Sidebar.webDir() else {
            print("FAIL 找不到 web/sidebar（包内 Resources 与仓库目录都没有）")
            return 2
        }

        let (items, missing) = sampleItems()
        guard missing.isEmpty else {
            print("FAIL 夹具对不上原文，找不到：\(missing.joined(separator: ", "))")
            return 2
        }
        let score = Scorer.score(text: sampleText, items: items)
        print("样本：\(items.count) 条建议 · overall=\(score.overall) "
              + "正确性=\(score.correctness) 清晰度=\(score.clarity) "
              + "吸引力=\(score.engagement) 表达=\(score.delivery)")
        guard items.count == 6, score.overall > 0, score.overall < 100 else {
            print("FAIL 样本分数不合理：items=\(items.count) overall=\(score.overall)")
            return 1
        }

        let payload = Sidebar.payload(items: items, score: score, tone: "自信 · 次要友好", dismissed: [])
        guard payload.contains("\"overall\":\(score.overall)"), payload.contains("\"groups\"") else {
            print("FAIL payload 与分数对不上：\(payload.prefix(120))")
            return 1
        }

        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)

        let size = NSSize(width: 360, height: 620)
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white

        let cfg = WKWebViewConfiguration()
        let web = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        web.setValue(false, forKey: "drawsBackground")
        window.contentView = web

        let gate = RenderGate()
        web.navigationDelegate = gate
        gate.onFinish = {
            // EW_SIDEBAR_ALL=1：切到「全部建议」，用来验风格类（菱形图标）也正常
            let render = ProcessInfo.processInfo.environment["EW_SIDEBAR_ALL"] == "1"
                ? "EW.render(\(payload)); EW.pick(1)" : "EW.render(\(payload))"
            web.evaluateJavaScript(render) { _, err in
                if let err { print("FAIL 渲染 JS 报错：\(err.localizedDescription)"); gate.fail(); return }
                web.evaluateJavaScript("EW.naturalHeight()") { v, _ in
                    let natural = (v as? NSNumber)?.doubleValue ?? 0
                    print("内容自然高度：\(Int(natural))pt（窗口 620pt，真实上屏按内容自适应、上限 70% 屏高）")
                    // 默认按「屏上真实视口」截（620，多出来的靠滚动）；
                    // EW_SIDEBAR_FULL=1 时按整栏内容高度截，用来一眼看全有没有排版塌
                    var shotSize = size
                    if ProcessInfo.processInfo.environment["EW_SIDEBAR_FULL"] == "1", natural > size.height {
                        shotSize = NSSize(width: size.width, height: natural)
                        window.setContentSize(shotSize)
                        web.frame = NSRect(origin: .zero, size: shotSize)
                    } else if natural > 0, natural < size.height {
                        // 内容比视口矮：按内容截，避免下面一片死白当成「渲染失败」
                        shotSize = NSSize(width: size.width, height: natural)
                        window.setContentSize(shotSize)
                        web.frame = NSRect(origin: .zero, size: shotSize)
                    }
                    let conf = WKSnapshotConfiguration()
                    conf.rect = NSRect(origin: .zero, size: shotSize)
                    conf.snapshotWidth = NSNumber(value: Double(shotSize.width))
                    web.takeSnapshot(with: conf) { image, error in
                        guard let image, error == nil else {
                            print("FAIL 截图失败：\(error?.localizedDescription ?? "nil")")
                            gate.fail(); return
                        }
                        guard let tiff = image.tiffRepresentation,
                              let rep = NSBitmapImageRep(data: tiff),
                              let png = rep.representation(using: .png, properties: [:]) else {
                            print("FAIL 编码 PNG 失败"); gate.fail(); return
                        }
                        let url = URL(fileURLWithPath: out)
                        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                                 withIntermediateDirectories: true)
                        do { try png.write(to: url) } catch {
                            print("FAIL 写盘失败：\(error.localizedDescription)"); gate.fail(); return
                        }
                        print("侧栏快照：\(url.path)（\(png.count) B, \(Int(image.size.width))×\(Int(image.size.height))）")
                        print("RESULT: PASS")
                        gate.done()
                    }
                }
            }
        }
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)

        let deadline = Date().addingTimeInterval(30)
        while !gate.finished, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        if !gate.finished {
            print("FAIL 30s 超时，导航/渲染没完成")
            return 3
        }
        return gate.ok ? 0 : 1
    }

    /// 小门闩：把 WKWebView 的异步回调折成同步 CLI
    final class RenderGate: NSObject, WKNavigationDelegate {
        var onFinish: (() -> Void)?
        var finished = false
        var ok = false
        func done() { ok = true; finished = true }
        func fail() { ok = false; finished = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // 让首帧布局跑完再量高度（否则 naturalHeight 会拿到 0）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.onFinish?() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("FAIL 页面加载失败：\(error.localizedDescription)"); fail()
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("FAIL 页面加载失败：\(error.localizedDescription)"); fail()
        }
    }
}
