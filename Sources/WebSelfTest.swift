// WebSelfTest.swift — WebKit 正文适配的真机级自检（宿主 = WKWebView，与 Mail 同一引擎）
//
// 为什么这样做：Mail 本体需要爹地真人在里面打字才能取证（他不许我们碰他的邮件），
// 但「WebKit 正文 → AXStaticText 文本块 → 块内矩形」这条链可以在**同一套 WebKit 引擎**上验证：
// 我们自己的进程里放一个 WKWebView（不上屏），让它按 Mail 的结构暴露 AX，然后跑 WebText + AXBoundsForRange。
//
// 口径（写死在输出里，不许冒充 Mail）：宿主=WKWebView，不是 Mail 本体。
//
// 用法：./build/英文写作助手 --selftest --web [--web-out <json>]

import AppKit
import ApplicationServices
import WebKit

enum WebSelfTest {

    struct Report: Codable {
        var ok = false
        var host = "WKWebView（与 Mail 同一 WebKit 引擎；不是 Mail 本体）"
        var webAreaFound = false
        var blockCount = 0
        var blocks: [String] = []
        var rectsOK = false
        var rectSample: [Int] = []
        var notes: [String] = []
    }

    static let html = """
    <!doctype html><html><body>
      <p>There is many reasons why we should sent the booking confirmation immediatly.</p>
      <p>He go to school every days.</p>
    </body></html>
    """

    @MainActor
    static func run(_ argv: [String]) -> Bool {
        var st = Report()

        let cfg = WKWebViewConfiguration()
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 400), configuration: cfg)
        let win = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 900, height: 400),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = view
        // WebKit 只有窗口「成为 key」才会建 AX 树；窗口摆在屏幕外坐标，肉眼看不到任何像素
        win.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        win.orderFrontRegardless()
        win.makeKey()

        final class Nav: NSObject, WKNavigationDelegate {
            let sem = DispatchSemaphore(value: 0)
            func webView(_ w: WKWebView, didFinish n: WKNavigation!) { sem.signal() }
            func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { sem.signal() }
        }
        let nav = Nav()
        view.navigationDelegate = nav
        view.loadHTMLString(html, baseURL: nil)
        _ = nav.sem.wait(timeout: .now() + 8)

        // 等 WebKit 把 AX 树建起来（异步，最多 6s）
        var webArea: AXUIElement? = nil
        let appEl = AXUIElementCreateApplication(getpid())
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        for _ in 0..<24 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let wins = (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
            for w in wins {
                if let found = firstWebArea(in: w, depth: 10) { webArea = found; break }
            }
            if webArea != nil { break }
        }

        if let body = webArea {
            st.webAreaFound = true
            let blks = WebText.blocks(of: body)
            st.blockCount = blks.count
            st.blocks = blks.map { String($0.text.prefix(60)) }
            // 块内矩形：Web 下划线的命门
            if let b = blks.first {
                let r = WebText.lineRects(for: NSRange(location: 0, length: min(5, (b.text as NSString).length)), in: b)
                st.rectsOK = !r.isEmpty
                if let first = r.first {
                    st.rectSample = [Int(first.minX.rounded()), Int(first.minY.rounded()),
                                     Int(first.width.rounded()), Int(first.height.rounded())]
                }
            }
            if st.blockCount == 0 { st.notes.append("AXWebArea 下没有 AXStaticText 文本块") }
            if st.rectsOK == false { st.notes.append("文本块上 AXBoundsForRange 没给矩形") }
        } else {
            st.notes.append("6s 内没在自己的 AX 树里看到 AXWebArea（WKWebView 可能未暴露无障碍）")
        }

        st.ok = st.webAreaFound && st.blockCount >= 2 && st.rectsOK
        win.orderOut(nil)

        print("\n--- WebKit 正文适配（宿主 WKWebView，非 Mail 本体）---")
        print("  webArea=\(st.webAreaFound) blocks=\(st.blockCount) rects=\(st.rectsOK) \(st.rectSample)")
        for b in st.blocks { print("  · \(b)") }
        for n in st.notes { print("  ! \(n)") }

        if let i = argv.firstIndex(of: "--web-out"), i + 1 < argv.count {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(st) { try? d.write(to: URL(fileURLWithPath: argv[i + 1])) }
        }
        print("  RESULT: \(st.ok ? "PASS" : "FAIL")")
        return st.ok
    }

    private static func firstWebArea(in el: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth > 0 else { return nil }
        for c in (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] {
            if (attrString(c, kAXRoleAttribute as String) ?? "") == "AXWebArea" { return c }
            if let f = firstWebArea(in: c, depth: depth - 1) { return f }
        }
        return nil
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private static func attrString(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
}
