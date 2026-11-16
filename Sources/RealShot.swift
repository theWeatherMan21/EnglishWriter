// RealShot.swift — 真机验收器：在 Mail 里摆一段带错的英文，让 App 自己画下划线，
// 把落点写成 JSON，然后在屏幕上停住 N 秒给外部 screencapture 抓图。
//
// 为什么必须跑在 App 进程里：TCC 辅助功能授权是给「英文写作助手.app」这个二进制的，
// 从终端直接 exec 二进制不会获得授权（知澜 2026-11-16 实测反例），
// 所以真机动作只能由 App 自己发起 —— 用 `open -a App --args --realshot <dir>` 起。
//
// 用法：
//   open -a "/Applications/Selfmade/英文写作助手.app" --args --realshot <outDir> \
//        [--hold 40] [--bundle com.apple.mail] [--text-file <path>] [--window 80,80,900,620]
// 产物：<outDir>/realshot-status.json

import AppKit
import ApplicationServices

enum RealShot {

    struct Status: Codable {
        var ok: Bool = false
        var timestamp: String = ""
        var app: String = ""
        var pid: Int32 = 0
        var windowTitle: String = ""
        var windowRectQuartz: [Int] = []        // x,y,w,h —— 直接给 screencapture -R
        var bodyRole: String = ""
        var bodyRectQuartz: [Int] = []
        var textSet: Bool = false
        var textLength: Int = 0
        var underlineCount: Int = 0
        var rects: [[Int]] = []
        var items: [[String]] = []
        var diag: String = ""
        var notes: [String] = []
    }

    static let defaultText = """
    There is many reasons why we should sent the booking confirmation to the customer immediatly. \
    Our sales team have received three new enquiry last week, and they was not able to reply on time. \
    The vessel is expected to depart on 20th Nov, please confirm the FCL booking with the shipper.
    """

    // MARK: - 参数

    struct Options {
        var outDir = NSHomeDirectory() + "/dev/EnglishWriter/out"
        var hold: Double = 40
        var bundle = "com.apple.mail"
        var text = RealShot.defaultText
        var window = (x: 80, y: 80, w: 920, h: 640)
        var keep = false
        var titleHint: String? = nil
    }

    static func options(from argv: [String]) -> Options {
        var o = Options()
        func val(_ flag: String) -> String? {
            guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
            return argv[i + 1]
        }
        if let d = val("--realshot"), !d.isEmpty { o.outDir = d }
        if let h = val("--hold"), let d = Double(h) { o.hold = d }
        if let b = val("--bundle"), !b.isEmpty { o.bundle = b }
        if let f = val("--text-file"), let s = try? String(contentsOfFile: f, encoding: .utf8) {
            o.text = s.trimmingCharacters(in: .newlines)
        }
        if let t = val("--text"), !t.isEmpty { o.text = t }
        if let w = val("--window") {
            let p = w.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if p.count == 4 { o.window = (p[0], p[1], p[2], p[3]) }
        }
        if argv.contains("--keep") { o.keep = true }
        if let t = val("--title"), !t.isEmpty { o.titleHint = t }
        return o
    }

    // MARK: - 主流程

    @MainActor
    static func run(_ argv: [String]) async {
        var o = options(from: argv)

        // AX 能力探针：--axprobe <path> [--title 新邮件]
        if argv.contains("--axprobe") {
            AXProbe.run(argv)
        }

        // 调试模式：--axdump <path> —— 把目标 App 的 AX 树（角色/标题/位置尺寸）写出来
        if let i = argv.firstIndex(of: "--axdump"), i + 1 < argv.count {
            let path = argv[i + 1]
            guard let app = runningApp(bundleID: o.bundle) else {
                try? "没有运行中的 \(o.bundle)".write(toFile: path, atomically: true, encoding: .utf8)
                exit(7)
            }
            dumpAX(pid: app.processIdentifier, to: path)
            exit(0)
        }

        var st = Status()
        st.timestamp = ISO8601DateFormatter().string(from: Date())
        try? FileManager.default.createDirectory(atPath: o.outDir, withIntermediateDirectories: true)

        func finish(_ code: Int32) -> Never {
            st.diag = InlineController.shared.diag.description
            write(st, to: o.outDir)
            print("[realshot] \(st.ok ? "OK" : "FAIL") rects=\(st.underlineCount) -> \(o.outDir)/realshot-status.json")
            if code != 0 { exit(code) }
            exit(0)
        }

        // 1) 找到目标 App（没在跑就拉起来）
        guard let app = runningApp(bundleID: o.bundle) ?? launch(bundleID: o.bundle) else {
            st.notes.append("找不到 \(o.bundle)")
            finish(4)
        }
        st.app = app.localizedName ?? o.bundle
        st.pid = app.processIdentifier
        app.activate(options: [.activateAllWindows])
        try? await Task.sleep(nanoseconds: 700_000_000)

        // 2) 找到写信窗口里的正文输入框（AX 树刚起时可能空一拍 → 重试几次）
        var found: Body? = nil
        for attempt in 0..<8 {
            if let b = composeBody(pid: st.pid, titleHint: o.titleHint) { found = b; break }
            if attempt == 3 { Drive.activate(st.pid) }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        guard let body = found else {
            st.notes.append("没找到正文框：AX 窗口数=\(windowCount(pid: st.pid))，先手动建一个空白文档/草稿窗口再跑")
            finish(5)
        }
        st.bodyRole = attrString(body.element, kAXRoleAttribute as String) ?? "?"

        // 3) 把窗口摆到主屏固定位置（截图裁剪才有确定坐标）
        if let win = body.window {
            st.windowTitle = attrString(win, kAXTitleAttribute as String) ?? ""
            _ = AXUIElementPerformAction(win, kAXRaiseAction as CFString)
            setFrame(win, o.window)
            try? await Task.sleep(nanoseconds: 300_000_000)
            st.windowRectQuartz = rectArray(frameOf(win))
        }

        // 4) 光标点进正文 → ⌘A 清空 → 逐字敲进去（走真实键入路径，验的是「键入即检查」）
        let bodyEl = body.element
        let bf = WebText.frame(bodyEl)
        if bf.width > 40 {
            Drive.click(at: CGPoint(x: bf.minX + 24, y: bf.minY + 14), to: st.pid)
        }
        Drive.selectAll(to: st.pid)
        Drive.type(o.text, to: st.pid)
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        // 打字后元素句柄可能失效：重新取正文容器
        let freshBody = body.window.flatMap { WebText.body(in: $0) } ?? bodyEl
        var typed: String
        if WebText.isWebBody(freshBody) {
            typed = WebText.blocks(of: freshBody).map(\.text).joined(separator: "\n")
            st.notes.append("Web 正文：\(WebText.blocks(of: freshBody).count) 个文本块")
        } else {
            typed = attrString(freshBody, kAXValueAttribute as String) ?? ""   // 原生输入框直接读 AXValue
            st.notes.append("原生输入框：\(typed.count) 字")
        }
        st.textSet = typed.contains("immediatly") || typed.contains("many reasons")
        if !st.textSet {
            // 防线：文本没进输入框时，underlineCount=0 是必然结果，不能当「M2 挂了」的证据。
            // 2026-11-16 就是拿这条假阴性当成 M2 结论，白走一轮；这里钉死并在退出码上区分（9）。
            st.notes.insert("【无效验收】正文没敲进输入框 → 本结果不构成 M2 结论（改用 --axcheck A 层：AXValue 直写）", at: 0)
        }
        st.textLength = (typed as NSString).length
        st.notes.append("正文=「\(typed.prefix(90))」")
        st.bodyRectQuartz = rectArray(WebText.frame(freshBody))

        // 5) 让 App 自己检查这一句（不走通知，直接指定 pid + 元素，避免焦点判定落空）
        InlineController.shared.checkNow(for: st.pid, element: freshBody)

        // 6) 等结果落地（LT 热态 20ms，冷启可能 2s）
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !InlineController.shared.overlay.specs.isEmpty { break }
            if InlineController.shared.diag.lastError != "-" && InlineController.shared.diag.checks > 0 { break }
        }

        let specs = InlineController.shared.overlay.specs
        let items = InlineController.shared.items
        st.underlineCount = specs.count
        st.rects = specs.map { rectArray($0.rect) }
        st.items = items.map { ["\($0.kind.rawValue)", $0.original, $0.replacement, "\($0.start)", "\($0.length)", $0.reason] }
        st.ok = !specs.isEmpty
        write(st, to: o.outDir)     // 先落盘：外面据此裁剪截图（此时下划线已在屏幕上）

        // 7) 停住给外面抓图（面板留在屏幕上）
        try? await Task.sleep(nanoseconds: UInt64(max(0.5, o.hold) * 1_000_000_000))
        finish(st.textSet ? (st.ok ? 0 : 6) : 9)     // 9 = 无效验收（文本没进去），别拿去下 M2 结论
    }

    // MARK: - AX 树导出（调试用）

    private static func dumpAX(pid: pid_t, to path: String) {
        var lines: [String] = []
        // 先把目标 App 提到前台（有些 App 的 AX 树在非前台时是空的）
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            usleep(900_000)
        }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        lines.append("frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") pid=\(pid) trusted=\(AXPermission.granted())")
        var raw: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &raw)
        lines.append("AXWindows err=\(err.rawValue) type=\(raw.map { "\(CFGetTypeID($0))" } ?? "nil")")
        let wins = (raw as? [AXUIElement]) ?? []
        lines.append("windows=\(wins.count)")
        func walk(_ el: AXUIElement, depth: Int, path: String) {
            guard depth > 0 else { return }
            for (i, c) in attrChildren(el).enumerated() {
                let role = attrString(c, kAXRoleAttribute as String) ?? "?"
                let sub = attrString(c, kAXSubroleAttribute as String) ?? ""
                let title = attrString(c, kAXTitleAttribute as String) ?? ""
                let valueLen = (attrString(c, kAXValueAttribute as String) ?? "").utf16.count
                let f = frameOf(c)
                lines.append("\(path).\(i) \(role)\(sub.isEmpty ? "" : "/" + sub) "
                             + "title=「\(title.prefix(40))」 valueLen=\(valueLen) "
                             + "frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
                if depth > 1 { walk(c, depth: depth - 1, path: "\(path).\(i)") }
            }
        }
        for (i, w) in wins.enumerated() {
            let title = attrString(w, kAXTitleAttribute as String) ?? ""
            let sub = attrString(w, kAXSubroleAttribute as String) ?? ""
            let f = frameOf(w)
            lines.append("W\(i) AXWindow/\(sub) title=「\(title)」 frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
            walk(w, depth: 8, path: "W\(i)")
        }
        try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    // MARK: - App / 窗口 / 输入框定位

    private static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    private static func launch(bundleID: String) -> NSRunningApplication? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let cfg = NSWorkspace.OpenConfiguration()
        var out: NSRunningApplication?
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
            out = app
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 6)
        return out ?? runningApp(bundleID: bundleID)
    }

    private static func windowCount(pid: pid_t) -> Int {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        return ((attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []).count
    }

    struct Body { var element: AXUIElement; var window: AXUIElement? }

    /// 写信窗口的正文容器：优先标题像「新邮件」的窗口，其次唯一窗口里的正文
    private static func composeBody(pid: pid_t, titleHint: String? = nil) -> Body? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        let wins = (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        let composeHints = ["new message", "新邮件", "no subject", "无主题", "unbenannt", "nouveau", "untitled", "未命名"]

        var best: (score: Int, area: CGFloat, body: Body)?
        for win in wins {
            let title = (attrString(win, kAXTitleAttribute as String) ?? "").lowercased()
            var hinted = composeHints.contains { title.contains($0) }
            if let h = titleHint, title.contains(h.lowercased()) { hinted = true }
            guard let b = WebText.body(in: win) else { continue }
            let f = WebText.frame(b)
            let area = f.width * f.height
            guard area > 4000 else { continue }
            var score = 0
            if hinted { score += 100 }
            if wins.count == 1 { score += 20 }
            guard let cur = best else {
                best = (score, area, Body(element: b, window: win)); continue
            }
            if score > cur.score || (score == cur.score && area > cur.area) {
                best = (score, area, Body(element: b, window: win))
            }
        }
        return best?.body
    }

    private static func textAreas(in el: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var out: [AXUIElement] = []
        for c in attrChildren(el) {
            let role = attrString(c, kAXRoleAttribute as String) ?? ""
            if role == "AXTextArea" || role == "AXTextField" {
                var settable = DarwinBoolean(false)
                let ok = AXUIElementIsAttributeSettable(c, kAXValueAttribute as CFString, &settable) == .success
                if attr(c, kAXValueAttribute as String) != nil || (ok && settable.boolValue) {
                    out.append(c)
                }
            }
            out.append(contentsOf: textAreas(in: c, depth: depth - 1))
        }
        return out
    }

    // MARK: - AX 写文本 / 光标 / 几何

    private static func setText(_ text: String, in el: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
            if let back = attrString(el, kAXValueAttribute as String), back == text { return true }
        }
        // 退化路线：全选 + 写选区
        if let all = axRangeValue(0, max(1, (attrString(el, kAXValueAttribute as String) ?? "").utf16.count)) {
            _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, all)
        }
        if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            return (attrString(el, kAXValueAttribute as String) ?? "").contains(String(text.prefix(20)))
        }
        return false
    }

    private static func setCaret(at offset: Int, in el: AXUIElement) {
        guard let v = axRangeValue(offset, 0) else { return }
        _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
    }

    private static func setFrame(_ win: AXUIElement, _ w: (x: Int, y: Int, w: Int, h: Int)) {
        var p = CGPoint(x: w.x, y: w.y)
        if let pv = AXValueCreate(.cgPoint, &p) {
            _ = AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, pv)
        }
        var s = CGSize(width: w.w, height: w.h)
        if let sv = AXValueCreate(.cgSize, &s) {
            _ = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, sv)
        }
    }

    /// AX 的 position/size 就是 Quartz 全局坐标（左上原点），可直接喂 screencapture -R
    private static func frameOf(_ el: AXUIElement) -> CGRect {
        var rect = CGRect.zero
        if let pv = attr(el, kAXPositionAttribute as String), CFGetTypeID(pv) == AXValueGetTypeID() {
            var p = CGPoint.zero
            if AXValueGetValue(pv as! AXValue, .cgPoint, &p) { rect.origin = p }
        }
        if let sv = attr(el, kAXSizeAttribute as String), CFGetTypeID(sv) == AXValueGetTypeID() {
            var s = CGSize.zero
            if AXValueGetValue(sv as! AXValue, .cgSize, &s) { rect.size = s }
        }
        return rect
    }

    private static func rectArray(_ r: CGRect) -> [Int] {
        [Int(r.origin.x.rounded()), Int(r.origin.y.rounded()),
         Int(r.size.width.rounded()), Int(r.size.height.rounded())]
    }

    // MARK: - 落盘

    private static func write(_ st: Status, to dir: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(st) {
            try? d.write(to: URL(fileURLWithPath: dir + "/realshot-status.json"))
        }
    }
}
