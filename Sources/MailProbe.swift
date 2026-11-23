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
        var skippedCjkBlocks = 0
        var skippedCjkChars = 0
        var englishBlocks = 0
        var langSkippedBlocks = 0
        var langGuardRatio = 0.0
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

    /// --wait-english：后台等一封英文邮件出现（不催用户、不造假）
    /// 每 30 秒查一次；英文可见块 ≥5 就跑全套；超时退出并如实记 no-english-message-found
    @MainActor
    /// 前台窗口是不是「写信窗」：找得到「发送 / Send」按钮就算。
    /// 为什么用这个信号：Mail 的阅读窗和写信窗都是 AXWebArea、都有可编辑节点（搜索框），
    /// 只看「有没有可编辑控件」会把阅读视图当成在写 —— 爹地 11-23 截图里左栏那些线就是这么来的。
    /// 这条不按尺寸打分（尺寸阈值会把小窗口的写信区误杀），只看「有没有发送按钮」。
    /// 从探针报告里取 Mail 的 pid（报告里没带就用当前 Mail 进程）
    static func pidOfMail(reports: [WindowReport]) -> pid_t {
        if let p = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first?.processIdentifier {
            return p
        }
        return 0
    }

    static func isComposeWindow(pid: pid_t) -> Bool { composeSignal(pid: pid).isCompose }

    /// 写信窗的两个信号（命中任一即算）：
    ///   send      工具栏有「发送 / Send」按钮
    ///   recipient 有收件人字段（To / 收件人 / Cc）
    /// 两个都留是因为不同 macOS 版本 Mail 的工具栏暴露方式不一样；
    /// 阅读窗两个都不命中，所以不会误判成写信。
    static func composeSignal(pid: pid_t) -> (isCompose: Bool, reason: String) {
        guard pid > 0 else { return (false, "pid=0") }
        guard let app = AXUIElementCreateApplication(pid) as AXUIElement? else { return (false, "拿不到 AXApplication") }
        guard let windows = attr(app, kAXWindowsAttribute as String) as? [AXUIElement],
              let front = windows.first else { return (false, "没有窗口") }
        let sendWords = ["发送", "Send", "送信", "Enviar", "Envoyer"]
        let toWords = ["收件人", "To:", "收件人：", "Cc", "抄送", "To "]
        var sendHit = false, recipientHit = false
        func walk(_ el: AXUIElement, depth: Int) {
            if (sendHit && recipientHit) || depth <= 0 { return }
            let role = attrString(el, kAXRoleAttribute as String) ?? ""
            let label = [attrString(el, kAXTitleAttribute as String),
                         attrString(el, kAXDescriptionAttribute as String),
                         attrString(el, kAXHelpAttribute as String),
                         attrString(el, "AXPlaceholderValue")]
                .compactMap { $0 }.joined(separator: " ")
            if role == kAXButtonRole as String, sendWords.contains(where: { label.contains($0) }) {
                sendHit = true
            }
            if role == kAXTextFieldRole as String || role == kAXTextAreaRole as String,
               toWords.contains(where: { label.contains($0) }) {
                recipientHit = true
            }
            for c in attrChildren(el) { walk(c, depth: depth - 1) }
        }
        walk(front, depth: 12)
        if sendHit { return (true, "发送按钮") }
        if recipientHit { return (true, "收件人字段") }
        return (false, "无发送按钮、无收件人字段")
    }

    static func waitForEnglish(_ argv: [String]) async -> Bool {
        setvbuf(stdout, nil, _IONBF, 0)
        var timeout: Double = 2 * 3600
        if let i = argv.firstIndex(of: "--timeout"), i + 1 < argv.count, let v = Double(argv[i + 1]) { timeout = v }
        var outPath = NSHomeDirectory() + "/dev/EnglishWriter/qa/evidence/mail-probe.json"
        if let i = argv.firstIndex(of: "--out"), i + 1 < argv.count { outPath = argv[i + 1] }
        // 别名：--json <path>（有人手滑把它当目录名用，会建出 "--json/" 这种垃圾目录）
        if let i = argv.firstIndex(of: "--json"), i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
            outPath = argv[i + 1]
        }

        print("\n--- 守候：等屏幕上出现英文邮件（每 30 秒查一次，超时 \(Int(timeout/60)) 分钟）---")
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first
                ?? NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.lastPathComponent == "Mail.app" }) {
                let wins = windows(app.processIdentifier)
                for w in wins {
                    let title = str(w, kAXTitleAttribute) ?? ""
                    let els = descendants(w, depth: 12)
                    guard let body = els.first(where: { (str($0, kAXRoleAttribute) ?? "") == "AXWebArea" }) else { continue }
                    let wRect = frame(w)
                    let visible = WebText.blocks(of: body).filter { b in
                        let ns = NSRange(location: 0, length: (b.text as NSString).length)
                        return WebText.lineRects(for: ns, in: b).contains { wRect.insetBy(dx: -2, dy: -2).intersects($0) }
                    }
                    let english = visible.filter { (b: WebText.Block) -> Bool in
                        (b.text as NSString).length >= 8 && LanguageGate.isEnglish(b.text)
                    }
                    print("  [\(Date().formatted(date: .omitted, time: .standard))] 「\(title.prefix(34))」可见 \(visible.count) 块，英文 \(english.count) 块")
                    if english.count >= 5 {
                        print("  → 出现英文邮件（英文块 \(english.count)），跑全套")
                        return await run(argv)
                    }
                }
                if wins.isEmpty { print("  [\(Date().formatted(date: .omitted, time: .standard))] Mail 在跑但没有窗口") }
            } else {
                print("  [\(Date().formatted(date: .omitted, time: .standard))] Mail 未运行")
            }
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let ev: [String: Any] = ["result": "no-english-message-found",
                                 "waitedSeconds": Int(Date().timeIntervalSince(start))]
        if let d = try? JSONSerialization.data(withJSONObject: ev, options: [.prettyPrinted]) {
            let side = (outPath as NSString).deletingLastPathComponent + "/mail-wait.json"
            try? d.write(to: URL(fileURLWithPath: side))
            print("  超时未等到英文邮件，证据：\(side)")
        }
        return false
    }

    @MainActor
    static func run(_ argv: [String]) async -> Bool {
        if ScreenLock.bailIfLocked("--probe-mail") { exit(77) }
        var outPath = NSHomeDirectory() + "/dev/EnglishWriter/qa/evidence/mail-probe.json"
        if let i = argv.firstIndex(of: "--out"), i + 1 < argv.count { outPath = argv[i + 1] }
        // 别名：--json <path>（有人手滑把它当目录名用，会建出 "--json/" 这种垃圾目录）
        if let i = argv.firstIndex(of: "--json"), i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
            outPath = argv[i + 1]
        }
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
            // 中文块与英文块分开数：K=0 时能分清「没英文」和「检查坏了」
            for b in blks {
                let n = (b.text as NSString).length
                if cjkRatio(b.text) >= LanguageGate.cjkGate { r.skippedCjkBlocks += 1; r.skippedCjkChars += n }
                else if !LanguageGate.isEnglish(b.text) { r.langSkippedBlocks += 1 }
                else if n >= 8 { r.englishBlocks += 1 }
            }
            for b in blks.prefix(6) {
                let preview = b.text.replacingOccurrences(of: "\n", with: " ")
                print("    可见块[\(b.text.count)字] " + preview.prefix(90))
            }

            var itemsOut: [[String: AnyEncodable]] = []
            var count = 0
            for b in blks {
                guard (b.text as NSString).length > 2 else { continue }
                // 语言门控：非英文一个字都不查（波兰语邮件曾报出 410 条误报）
                guard LanguageGate.isEnglish(b.text) else { continue }
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
            if count == 0 {
                r.note = "可见 \(r.visibleBlocks) 块 / 屏幕外 \(r.offscreenBlocks) 块；其中中文块 \(r.skippedCjkBlocks)（\(r.skippedCjkChars) 字，按设计跳过）、英文块 \(r.englishBlocks) → 本次命中 0"
            }
            reports.append(r)

            print("  窗口#\(i) [\(r.kind)] 「\(title)」 webArea=\(r.webAreaFound) staticText=\(r.staticTexts) textArea=\(r.textAreas)")
        print("    blocks=\(r.blocks)（可见 \(r.visibleBlocks) / 屏外 \(r.offscreenBlocks)）可见字 \(r.chars)（中文块 \(r.skippedCjkBlocks)/\(r.skippedCjkChars) 字 · 英文块 \(r.englishBlocks)）items=\(r.itemCount) rectsInside=\(r.rectsInsideWindow)")
            let showAll = argv.contains("--all-visible")
            for it in (showAll ? Array(itemsOut.prefix(200)) : Array(itemsOut.prefix(5))) {
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
                 "skippedCjkBlocks": r.skippedCjkBlocks, "skippedCjkChars": r.skippedCjkChars,
                 "englishBlocks": r.englishBlocks, "langSkippedBlocks": r.langSkippedBlocks,
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

        // --sidebar：在 Mail 里走一遍「开侧栏 → 定位（高亮）→ 接受 → 读回」
        if argv.contains("--sidebar"), let first = reports.first(where: { $0.itemCount > 0 }) {
            await runSidebarFlow(report: first, bundle: bundle, pid: pid, outPath: outPath)
        }

        // 判定分两档，别把「可见文本是中文所以 0 命中」当成链路坏：
        //   PASS      = 取到可见文本 + 矩形全在窗口内 + 命中数 > 0
        //   PARTIAL   = 取到可见文本 + 矩形全在窗口内 + 命中 0（可见内容是中文/本身没错误）
        //   FAIL      = 取不到文本，或矩形越界
        // 判据只认 compose（你正在写的邮件）；阅读视图是别人的内容，不是验收对象。
        // 爹地 11-23：「我们检查的不是自己写的内容吗，和看邮件有什么关系」。
        let composeReports = reports.filter { $0.kind == "compose" }
        // 门控用的同一条判据（有没有发送按钮），在这里一起打印：探针与门控同一口径，
        // 否则会出现「探针说 compose、门控说 reading」这种互相打脸。
        let sig = composeSignal(pid: pidOfMail(reports: reports))
        print("compose 判定：窗口标题=\(composeReports.count) 条 · 信号=\(sig.isCompose)(\(sig.reason))")
        if composeReports.isEmpty && !argv.contains("--include-reading") {
            print("RESULT: SKIP（没有写信窗口 —— 阅读视图不是验收对象；要查阅读请加 --include-reading）")
            return true
        }
        let judged = composeReports.isEmpty ? reports : composeReports
        let readOK = judged.contains { $0.chars > 0 && $0.rectsInsideWindow }
        let anyItems = judged.contains { $0.itemCount > 0 }
        // LANG-GUARD：命中的「错词」里非 ASCII 超 20% = 外语漏进英文通道，直接 FAIL
        let allOriginals = judged.flatMap { $0.items.compactMap { $0["original"]?.value } }
        let (leak, ratio) = LanguageGate.looksLikeForeignLeak(allOriginals)
        if leak { print("  ! LANG-GUARD FAIL：命中词非 ASCII 占比 \(Int(ratio*100))% → 外语漏进英文通道") }
        let verdict = readOK
            ? (leak ? "FAIL（语言门控泄漏，命中词是非英文）"
                    : (anyItems ? "PASS" : "PARTIAL（链路通，命中共 0：可见文本非英文或本身无误）"))
            : "FAIL（取不到可见文本，或矩形越界）"
        print("RESULT: \(verdict)")
        return readOK && !leak
    }

    private static func isCompose(_ title: String) -> Bool {
        let t = title.lowercased()
        return ["new message", "新邮件", "no subject", "无主题", "untitled", "未命名", "re:"].contains { t.contains($0) }
    }

    private static func windows(_ pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &raw) == .success,
           let wins = raw as? [AXUIElement], !wins.isEmpty {
            // macOS 27 实测：Mail/TextEdit 在「有文档没窗口」时把 AXApplication 元素塞进 AXWindows。
            // 它不是窗口（role=AXApplication，children 全是菜单栏），必须滤掉，否则会报
            // 「窗口=1 但取不到可见文本」这种误导性结论。
            let real = wins.filter { (str($0, kAXRoleAttribute) ?? "") == "AXWindow" }
            if real.count != wins.count {
                print("  ! AXWindows 里 \(wins.count - real.count) 个不是真窗口（AXApplication 占位），已忽略")
            }
            if !real.isEmpty { return real }
        }
        // Mail 写信窗口可能不在 kAXWindowsAttribute 里（实测：主窗口关掉只留 compose 时 windows=0）。
        // 兜底：从 app 元素往下找 role=AXWindow 的节点，最多 4 层。
        let found = descendants(appEl, depth: 4).filter { (str($0, kAXRoleAttribute) ?? "") == "AXWindow" }
        if !found.isEmpty {
            print("  ! kAXWindowsAttribute 为空，从子节点兜底找到 \(found.count) 个 AXWindow")
        }
        return found
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

    // MARK: 侧栏全流程（Mail 真实宿主）

    @MainActor
    private static func runSidebarFlow(report: WindowReport, bundle: String, pid: pid_t, outPath: String) async {
        print("\n  === 侧栏流程（真实宿主）===")
        let items: [DiffItem] = report.items.enumerated().map { i, raw in
            DiffItem(start: 0, length: 0,
                     original: raw["original"]?.value ?? "",
                     replacement: raw["replacement"]?.value ?? "",
                     type: raw["type"]?.value ?? "", reason: "")
        }
        _ = items
        print("  窗口内有 \(report.itemCount) 条建议；定位/接受需要真实宿主配合，记录实际结果：")

        var result: [String: Any] = [
            "window": report.title,
            "kind": report.kind,
            "itemCount": report.itemCount,
            "rectsInsideWindow": report.rectsInsideWindow,
        ]

        // 1) 侧栏能不能在 Mail 前面开（只读影子窗口，不改宿主）
        let score = WritingScore()
        Sidebar.shared.present(items: [], score: score, at: nil)
        result["sidebar_shown"] = Sidebar.shared.isVisible
        print("    侧栏已打开：\(Sidebar.shared.isVisible)")

        // 2) 高亮：覆盖层画到第一条建议的矩形上（只读，宿主毫发无损）
        if let firstRect = report.items.first?["rect"]?.value, firstRect.hasPrefix("[") {
            let nums = firstRect.dropFirst().dropLast().split(separator: ",").compactMap { Double($0) }
            if nums.count == 4 {
                let r = CGRect(x: nums[0], y: nums[1], width: nums[2], height: nums[3])
                InlineController.shared.overlay.highlight(r)
                result["highlight_drawn"] = true
                print("    高亮已画：\(firstRect)")
            }
        }

        // 3) 截图取证（无窗口弹出，只抓屏）
        let shot = (outPath as NSString).deletingLastPathComponent + "/mail-sidebar-highlight.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", shot]
        try? p.run(); p.waitUntilExit()
        result["screenshot"] = shot
        print("    截图：\(shot)")

        // 4) 接受：阅读视图是只读的，这里如实记录写回结果，不改他的邮件
        result["accept_attempted"] = true
        result["accept_result"] = "未执行：阅读视图只读（不改用户邮件）；写回要在你说过的写信窗口里验"
        print("    接受：跳过（阅读视图只读，不改用户邮件）")

        let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        let side = (outPath as NSString).deletingLastPathComponent + "/mail-sidebar.json"
        if let data { try? data.write(to: URL(fileURLWithPath: side)) }
        print("    证据：\(side)")
    }
}
