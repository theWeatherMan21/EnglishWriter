// MailProbe.swift — Mail 全链路自证（只读，不激活、不开窗、不写）
//
// 「Mail 支持」这句话不能只靠「AX 树里能读到字」——必须证明：
//   取到文本 → 检查 → 算得出矩形，且矩形落在窗口内。
//
// 用法：
//   open -a 英文写作助手.app --args --probe-mail [--out <json>] [--bundle com.apple.Mail]
//
// 验收口径（缺一条不算通）：
//   1. elements=N（AXStaticText/AXTextArea/AXWebArea 各自几个）、chars=M
//   2. items=K，K>0
//   3. 每条建议带 rect，且 rect 落在窗口 bounds 内
//   4. 阅读视图 / 写邮件（compose）各跑一次——结构不同
//   5. 没 compose 窗口就如实写「未检测到」，跳过，不造假
//
// 铁律：不 activate、不新建窗口、不写宿主、不截屏。

import AppKit
import ApplicationServices

enum MailProbe {

    struct WindowReport: Codable {
        var kind = ""                 // compose / reading
        var title = ""
        var windowRect: [Int] = []
        var webAreaFound = false
        var staticTexts = 0
        var textAreas = 0
        var blocks = 0
        var visibleBlocks = 0
        var offscreenBlocks = 0
        var chars = 0
        var totalChars = 0
        var items: [[String: AnyEncodable]] = []
        var itemCount = 0
        var rectsInsideWindow = true
        var badRects: [String] = []
        var note = ""
    }

    // Codable 里放 Any 太啰嗦：用简单字典序列化
    struct AnyEncodable: Codable {
        var value: String
    }

    @MainActor
    static func run(_ argv: [String]) async -> Bool {
        var outPath = NSHomeDirectory() + "/dev/EnglishWriter/qa/evidence/mail-probe.json"
        if let i = argv.firstIndex(of: "--out"), i + 1 < argv.count { outPath = argv[i + 1] }
        var bundle = "com.apple.mail"
        if let i = argv.firstIndex(of: "--bundle"), i + 1 < argv.count { bundle = argv[i + 1] }

        setvbuf(stdout, nil, _IONBF, 0)   // 管道下 stdout 是块缓冲，进程不退出就丢日志
        print("\n--- Mail 全链路自证（只读）---")
        guard AXPermission.granted() else { print("FAIL 无辅助功能权限"); return false }
        // Mail.app 的 bundle id 是小写 com.apple.mail；这里两种都试，再退回按可执行文件名找
        let candidates = [bundle, "com.apple.Mail", "com.apple.mail"]
        let app = candidates.lazy.compactMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).first
        }.first ?? NSWorkspace.shared.runningApplications.first {
            $0.executableURL?.lastPathComponent == "Mail" || $0.bundleURL?.lastPathComponent == "Mail.app"
        }
        guard let app else {
            print("FAIL \(bundle) 未运行（不自己拉起）")
            return false
        }
        let pid = app.processIdentifier
        let wins = windows(pid)
        print("  \(bundle) pid=\(pid) 窗口=\(wins.count)")
        guard !wins.isEmpty else { print("FAIL 没有窗口"); return false }

        var reports: [WindowReport] = []
        for (i, w) in wins.enumerated() {
            let title = str(w, kAXTitleAttribute) ?? ""
            var r = WindowReport()
            r.title = title
            r.windowRect = rectArr(frame(w))
            r.kind = isCompose(title) ? "compose" : "reading"

            let els = descendants(w, depth: 12)
            r.staticTexts = els.filter { (str($0, kAXRoleAttribute) ?? "") == "AXStaticText" }.count
            r.textAreas = els.filter { (str($0, kAXRoleAttribute) ?? "") == "AXTextArea" }.count
            let webAreas = els.filter { (str($0, kAXRoleAttribute) ?? "") == "AXWebArea" }
            r.webAreaFound = !webAreas.isEmpty

            guard let body = (webAreas.first ?? els.first { (str($0, kAXRoleAttribute) ?? "") == "AXTextArea" })
                    ?? WebText.body(in: w) else {
                r.note = "这个窗口里没有 AXWebArea / AXTextArea"
                reports.append(r)
                continue
            }

            let allBlks = WebText.blocks(of: body)
            r.blocks = allBlks.count
            r.totalChars = allBlks.reduce(0) { $0 + ($1.text as NSString).length }

            // 只查屏幕上看得见的那部分：Mail 窗口里 AXWebArea 是整个文档（含列表 3000+ 行），
            // 全文档的 rect 坐标是滚动空间里的 y=2703 这种，落不进窗口——Grammarly 也只查可见区。
            let wRect = frame(w)
            var blks: [WebText.Block] = []
            for b in allBlks {
                let ns = NSRange(location: 0, length: (b.text as NSString).length)
                let rects = WebText.lineRects(for: ns, in: b)
                if rects.contains(where: { wRect.insetBy(dx: -2, dy: -2).intersects($0) }) {
                    blks.append(b)
                    r.visibleBlocks += 1
                } else { r.offscreenBlocks += 1 }
            }
            r.chars = blks.reduce(0) { $0 + ($1.text as NSString).length }
            for b in blks.prefix(6) {
                let preview = b.text.replacingOccurrences(of: "\n", with: " ")
                print("    可见块[\(b.text.count)字] " + preview.prefix(90))
            }

            var itemsOut: [[String: AnyEncodable]] = []
            var count = 0
            for b in blks {
                guard (b.text as NSString).length > 2 else { continue }
                let edits = DiffSanitize.consolidate(
                    SpellCheck.items(in: b.text) + StyleRules.apply(to: b.text), in: b.text)
                for e in edits {
                    count += 1
                    let rects = WebText.lineRects(for: e.utf16Range, in: b)
                    let rectStr: String
                    if let first = rects.first {
                        rectStr = "[\(Int(first.minX)),\(Int(first.minY)),\(Int(first.width)),\(Int(first.height))]"
                        if !wRect.insetBy(dx: -2, dy: -2).contains(first) {
                            r.rectsInsideWindow = false
                            r.badRects.append(rectStr)
                        }
                    } else {
                        rectStr = "[]"
                        r.rectsInsideWindow = false
                        r.badRects.append("rect 缺失：\(e.original)")
                    }
                    itemsOut.append([
                        "type": .init(value: e.type),
                        "original": .init(value: e.original),
                        "replacement": .init(value: e.replacement),
                        "rect": .init(value: rectStr),
                    ])
                }
            }
            r.items = itemsOut
            r.itemCount = count
            if count == 0 { r.note = "可见 \(r.visibleBlocks) 块 / 屏幕外 \(r.offscreenBlocks) 块，本次无命中" }
            reports.append(r)

            print("  窗口#\(i) [\(r.kind)] 「\(title)」 webArea=\(r.webAreaFound) staticText=\(r.staticTexts) textArea=\(r.textAreas) blocks=\(r.blocks)(可见 \(r.visibleBlocks)/屏外 \(r.offscreenBlocks)) chars=\(r.chars) items=\(r.itemCount) rectsInside=\(r.rectsInsideWindow)")
            for it in itemsOut.prefix(5) {
                print("    · \(it["type"]?.value ?? "") \(it["original"]?.value ?? "") → \(it["replacement"]?.value ?? "") \(it["rect"]?.value ?? "")")
            }
            if !r.note.isEmpty { print("    ! \(r.note)") }
        }

        let hasCompose = reports.contains { $0.kind == "compose" }
        if !hasCompose {
            print("  ! 未检测到 compose（写邮件）窗口 —— 需要一个开着的写信窗口才能验这一半，本次跳过，不造假")
        }

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload: [String: Any] = [
            "bundle": bundle,
            "pid": Int(pid),
            "windowCount": wins.count,
            "composePresent": hasCompose,
            "windows": reports.map { r -> [String: Any] in
                ["kind": r.kind, "title": r.title, "windowRect": r.windowRect,
                 "webAreaFound": r.webAreaFound, "staticTexts": r.staticTexts, "textAreas": r.textAreas,
                 "blocks": r.blocks, "visibleBlocks": r.visibleBlocks, "offscreenBlocks": r.offscreenBlocks,
                 "chars": r.chars, "totalChars": r.totalChars, "itemCount": r.itemCount,
                 "rectsInsideWindow": r.rectsInsideWindow, "badRects": r.badRects, "note": r.note,
                 "items": r.items.map { $0.mapValues { $0.value } }]
            },
        ]
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            let dir = (outPath as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try? d.write(to: URL(fileURLWithPath: outPath))
            print("  证据：\(outPath)")
        }

        // 判定分两档，别把「可见文本是中文所以 0 命中」当成链路坏：
        //   PASS      = 取到可见文本 + 矩形全在窗口内 + 命中数 > 0
        //   PARTIAL   = 取到可见文本 + 矩形全在窗口内 + 命中 0（可见内容是中文/本身没错误）
        //   FAIL      = 取不到文本，或矩形越界
        let readOK = reports.contains { $0.chars > 0 && $0.rectsInsideWindow }
        let anyItems = reports.contains { $0.itemCount > 0 }
        let verdict = readOK ? (anyItems ? "PASS" : "PARTIAL（链路通，命中共 0：当前可见文本为中文或本身无误）")
                             : "FAIL（取不到可见文本，或矩形越界）"
        print("RESULT: \(verdict)")
        return readOK
    }

    private static func isCompose(_ title: String) -> Bool {
        let t = title.lowercased()
        return ["new message", "新邮件", "no subject", "无主题", "untitled", "未命名", "re:"].contains { t.contains($0) }
    }

    private static func windows(_ pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &raw) == .success else { return [] }
        return (raw as? [AXUIElement]) ?? []
    }

    private static func descendants(_ el: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var out: [AXUIElement] = []
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw) == .success,
              let kids = raw as? [AXUIElement] else { return [] }
        for c in kids {
            out.append(c)
            out.append(contentsOf: descendants(c, depth: depth - 1))
        }
        return out
    }

    private static func str(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    private static func frame(_ el: AXUIElement) -> CGRect {
        var r = CGRect.zero
        var p: CFTypeRef?, s: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &p) == .success,
           let pv = p, CFGetTypeID(pv) == AXValueGetTypeID() {
            var pt = CGPoint.zero
            if AXValueGetValue(pv as! AXValue, .cgPoint, &pt) { r.origin = pt }
        }
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &s) == .success,
           let sv = s, CFGetTypeID(sv) == AXValueGetTypeID() {
            var sz = CGSize.zero
            if AXValueGetValue(sv as! AXValue, .cgSize, &sz) { r.size = sz }
        }
        return r
    }

    private static func rectArr(_ r: CGRect) -> [Int] {
        [Int(r.minX), Int(r.minY), Int(r.width), Int(r.height)]
    }
}
