// AXProbe.swift — 目标 App 的 AX 能力探针（调引擎前先摸清它到底暴露了什么）
//
// 用途：Mail 的写信正文是 WebKit（AXWebArea）而不是 AXTextArea，
// 能不能读全文、能不能写回、AXBoundsForRange 给不给矩形，全靠这份输出定路线。
//
// 用法：open -a <App> --args --axprobe <outPath> [--bundle com.apple.mail] [--title 新邮件]

import AppKit
import ApplicationServices

enum AXProbe {

    @MainActor
    static func run(_ argv: [String]) {
        var out = "/tmp/axprobe.txt"
        if let i = argv.firstIndex(of: "--axprobe"), i + 1 < argv.count { out = argv[i + 1] }
        var bundle = "com.apple.mail"
        if let i = argv.firstIndex(of: "--bundle"), i + 1 < argv.count { bundle = argv[i + 1] }
        var titleHint: String? = nil
        if let i = argv.firstIndex(of: "--title"), i + 1 < argv.count { titleHint = argv[i + 1] }

        var lines: [String] = []
        lines.append("trusted=\(AXPermission.granted())")
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
            lines.append("没有运行中的 \(bundle)")
            try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
            exit(9)
        }
        app.activate(options: [.activateAllWindows])
        usleep(800_000)

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        let wins = (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        lines.append("frontmost=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") windows=\(wins.count)")

        for (wi, win) in wins.enumerated() {
            let title = attrString(win, kAXTitleAttribute as String) ?? ""
            let f = frameOf(win)
            lines.append("W\(wi) 「\(title)」 frame=\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))")
            guard titleHint == nil || title.localizedCaseInsensitiveContains(titleHint!) else { continue }

            // 焦点元素
            if let fr = attr(appEl, kAXFocusedUIElementAttribute as String) {
                let el = fr as! AXUIElement
                lines.append("  focused=\(attrString(el, kAXRoleAttribute as String) ?? "?")")
            }
            // 这个窗口里所有可编辑候选
            let cands = candidates(in: win, depth: 8)
            for cand in cands { lines.append("  → \(describe(cand))") }

            // 写测试：--write 时把正文写进去，看能不能写、写完能不能读回来
            if let i = argv.firstIndex(of: "--write"), i + 1 < argv.count, lines.last != nil {
                let text = argv[i + 1]
                guard let body = cands.first(where: { attrString($0, kAXRoleAttribute as String) == "AXWebArea" })
                        ?? cands.first else { continue }
                lines.append("  == write test ==")
                let e1 = AXUIElementSetAttributeValue(body, kAXValueAttribute as CFString, text as CFTypeRef)
                lines.append("  AXValue write err=\(e1.rawValue)")
                usleep(600_000)
                lines.append("  after: \(describe(body))")
                lines.append("  value readback=「\(String((attrString(body, kAXValueAttribute as String) ?? "").prefix(60)))」")
                let leaves = staticTexts(in: body, depth: 6)
                lines.append("  staticTexts=\(leaves.count)")
                for (k, l) in leaves.prefix(12).enumerated() {
                    lines.append("    [\(k)] 「\(attrString(l, kAXValueAttribute as String) ?? "")」 frame=\(frameOf(l))")
                }
                // 选中区写回测试（第二条路）
                if let v = axRangeValue(0, 0) {
                    let e2 = AXUIElementSetAttributeValue(body, kAXSelectedTextRangeAttribute as CFString, v)
                    lines.append("  set selectedRange(0,0) err=\(e2.rawValue)")
                }
                let e3 = AXUIElementSetAttributeValue(body, kAXSelectedTextAttribute as CFString, "ZZ" as CFTypeRef)
                lines.append("  AXSelectedText write err=\(e3.rawValue)")
                usleep(400_000)
                lines.append("  after selectedText write: value=「\(String((attrString(body, kAXValueAttribute as String) ?? "").prefix(60)))」")
            }
        }
        try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8)
        print(lines.joined(separator: "\n"))
        exit(0)
    }

    /// AXStaticText 叶子（WebKit 里正文按行拆成它）
    private static func staticTexts(in el: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var out: [AXUIElement] = []
        for c in attrChildren(el) {
            if attrString(c, kAXRoleAttribute as String) == "AXStaticText" { out.append(c) }
            out.append(contentsOf: staticTexts(in: c, depth: depth - 1))
        }
        return out
    }

    /// AXTextArea / AXTextField / AXWebArea 都算候选
    private static func candidates(in el: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var out: [AXUIElement] = []
        for c in attrChildren(el) {
            let role = attrString(c, kAXRoleAttribute as String) ?? ""
            if ["AXTextArea", "AXTextField", "AXWebArea", "AXComboBox"].contains(role) {
                let f = frameOf(c)
                if f.width * f.height > 800 { out.append(c) }
            }
            out.append(contentsOf: candidates(in: c, depth: depth - 1))
        }
        return out
    }

    private static func describe(_ el: AXUIElement) -> String {
        let role = attrString(el, kAXRoleAttribute as String) ?? "?"
        let f = frameOf(el)
        var settable = DarwinBoolean(false)
        let valueSettable = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
        let valueLen = (attrString(el, kAXValueAttribute as String) ?? "").utf16.count
        let charCount = attr(el, "AXNumberOfCharacters") as? Int ?? -1
        var selRange = "-"
        if let r = attr(el, kAXSelectedTextRangeAttribute as String), CFGetTypeID(r) == AXValueGetTypeID() {
            var cf = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &cf) { selRange = "\(cf.location)+\(cf.length)" }
        }
        let selTextLen = (attrString(el, kAXSelectedTextAttribute as String) ?? "").utf16.count

        // AXBoundsForRange 支持度（取 0..5）
        var boundsOK = "err"
        if let v = axRangeValue(0, 5) {
            var outRef: CFTypeRef?
            let e = AXUIElementCopyParameterizedAttributeValue(el, "AXBoundsForRange" as CFString, v, &outRef)
            if e == .success, let o = outRef, CFGetTypeID(o) == AXValueGetTypeID() {
                var r = CGRect.zero
                if AXValueGetValue(o as! AXValue, .cgRect, &r) {
                    boundsOK = String(format: "%.0fx%.0f@%.0f,%.0f", r.width, r.height, r.minX, r.minY)
                }
            } else {
                boundsOK = "err=\(e.rawValue)"
            }
        }
        return "\(role) frame=\(Int(f.width))x\(Int(f.height))@\(Int(f.minX)),\(Int(f.minY)) "
             + "valueLen=\(valueLen) valueSettable=\(valueSettable) AXNumberOfCharacters=\(charCount) "
             + "sel=\(selRange) selTextLen=\(selTextLen) bounds(0,5)=\(boundsOK)"
    }

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
}
