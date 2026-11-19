// AXCheck.swift — A 层真机验收：不建窗口 / 不激活 / 不敲键 / 不截屏
//
// 为什么要这一层：realshot（B 层）靠 CGEvent 点击 + ⌘A + 逐字敲，只要靶子不是真正前台，
// 击键就落到别处，正文空格 → underlineCount=0，看上去像「M2 挂了」，其实是「文本没进去」。
// 2026-11-16 out/realshot-status.json 就是这种假阴性：textSet=false textLength=0。
//
// A 层把键盘这一环彻底摘掉：AXValue 直写正文（TextEdit 的 AXTextArea 实测 valueSettable=true）
// → 读回核对 → checkNow(pid, element) → 读 overlay 的 specs/rects。
// 下划线只算不上屏（UnderlineOverlay.silent），像素零上屏；合成图走离屏位图。
//
// 用法（必须由 App 自己发起，TCC 授权只认这个二进制）：
//   open -a "/Applications/Selfmade/英文写作助手.app" --args --axcheck <outDir> \
//        [--bundle com.apple.TextEdit] [--text "…"] [--text-file <path>]
// 产物：<outDir>/axcheck-status.json + <outDir>/axcheck-underlines.png
//
// 铁律：目标 App 没在跑就报错退出，绝不 launch（launch 会弹窗）。

import AppKit
import ApplicationServices

enum AXCheck {

    struct Status: Codable {
        var layer = "A"
        var method = "AXValue 直写正文 → checkNow(pid, element) → 读 overlay.specs（键盘/截屏均未使用）"
        var ok = false
        var reason = ""
        var timestamp = ""
        var app = ""
        var pid: Int32 = 0
        var windowTitle = ""
        var bodyRole = ""
        var bodyRectQuartz: [Int] = []
        var textSet = false
        var textLength = 0
        var caret = -1
        var underlineCount = 0
        var rects: [[Int]] = []
        var items: [[String]] = []
        var diag = ""
        var notes: [String] = []
        var snapshot = ""
    }

    static let marker = "immediatly"

    static let defaultText = """
    There is many reasons why we should sent the booking confirmation to the customer immediatly.
    """

    // MARK: 入口

    @MainActor
    static func run(_ argv: [String]) async {
        var st = Status()
        st.timestamp = ISO8601DateFormatter().string(from: Date())

        // 输出目录：--axcheck <dir> / --out <dir> / --json <dir> 都认（--json 以前会被当成目录名，
        // 于是仓库里出现一个叫 "--json/" 的垃圾目录 —— 这里统一收口）
        let outDir = value(argv, "--axcheck") ?? value(argv, "--out") ?? value(argv, "--json")
            ?? (NSHomeDirectory() + "/dev/EnglishWriter/out")
        let bundle = value(argv, "--bundle") ?? "com.apple.TextEdit"
        var text = defaultText
        if let f = value(argv, "--text-file"), let s = try? String(contentsOfFile: f, encoding: .utf8) {
            text = s.trimmingCharacters(in: .newlines)
        }
        if let t = value(argv, "--text"), !t.isEmpty { text = t }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        // --spawn：只有爹地明确批准「允许她自己开一个空白 TextEdit」时才加。
        // 它确实会开窗口（唯一例外），所以收尾必须彻底：进程级杀掉、删临时文档、不留保存对话框。
        let spawn = argv.contains("--spawn")
        var spawnedTemp: String? = nil

        func finish(_ code: Int32) -> Never {
            st.diag = InlineController.shared.diag.description
            write(st, to: outDir)
            print("[axcheck] \(st.ok ? "OK" : "FAIL") rects=\(st.underlineCount) reason=\(st.reason)")
            InlineController.shared.clearUnderlines()
            if let t = spawnedTemp {
                if let p = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                    let pid = p.processIdentifier
                    // 先请它体面退出；0.5s 还在就直接 SIGKILL —— 不然写了文本的临时文档会弹保存对话框，留在屏幕上
                    kill(pid, SIGTERM)
                    usleep(500_000)
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                    usleep(200_000)
                }
                try? FileManager.default.removeItem(atPath: t)
            }
            exit(code)
        }

        guard AXPermission.granted() else {
            st.reason = "无辅助功能权限（必须 open -a 起 App，终端直接 exec 二进制恒 false）"
            finish(3)
        }

        // 1) 目标必须在跑 —— 默认不 launch（launch 会弹窗）
        var target = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        if target == nil {
            guard spawn else {
                st.reason = "目标 \(bundle) 未运行（A 层不自己拉起，避免产生窗口；爹地点头后加 --spawn）"
                st.app = bundle
                finish(8)
            }
            let tmp = NSTemporaryDirectory() + "ew-axcheck-\(getpid()).rtf"
            // 必须是**合法 RTF**：空文件会让 TextEdit 弹「打开文稿」选择器（0 documents、1 dialog window），
            // body() 就找不到任何 AXTextArea —— macOS 27 实测，这就是「窗口数=1 却没有正文」的根因。
            let rtf = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 }"
            try? rtf.write(toFile: tmp, atomically: true, encoding: .utf8)
            spawnedTemp = tmp
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
                st.reason = "找不到 \(bundle) 的安装位置"
                finish(8)
            }
            let sem = DispatchSemaphore(value: 0)
            NSWorkspace.shared.open([URL(fileURLWithPath: tmp)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 10)
            for _ in 0..<20 {
                if let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
                   windowCount(a.processIdentifier) > 0 {
                    target = a
                    break
                }
                usleep(500_000)
            }
            guard let a = target, windowCount(a.processIdentifier) > 0 else {
                st.reason = "起了 \(bundle) 但没等到窗口（临时文档 \(tmp)）"
                finish(8)
            }
            st.notes.append("【--spawn】爹地已批准：临时空白文档（\(a.processIdentifier)），跑完杀进程、删临时文件")
            // 注意：这里**不能**先最小化再找正文 —— 最小化后窗口 AXFrame 会退化成 0，
            // body(minArea: 4000) 找不到任何 AXTextArea（macOS 27 TextEdit 实测：
            // 一最小化就 FAIL「没有可写的 AXTextArea（窗口数=1）」）。最小化放到找到正文之后。
        }
        guard let app = target else {
            st.reason = "目标 \(bundle) 未运行"
            finish(8)
        }
        st.app = app.localizedName ?? bundle
        st.pid = app.processIdentifier
        if spawnedTemp == nil { st.notes.append("未激活、未新建窗口、未发键击、未截屏") }

        // 2) 找一个可写的正文容器（最大的 AXTextArea）—— 先找，再最小化
        guard let found = body(pid: st.pid, minArea: 4000) else {
            st.reason = "目标没有可写的 AXTextArea（窗口数=\(windowCount(st.pid))）"
            finish(5)
        }
        if spawnedTemp != nil, let w = found.window ?? windows(st.pid).first { setMinimized(w, true) }
        let el = found.element
        // 顺带验「无焦点时的确定性回退」：key window 里第一个可编辑元素必须找得到
        if let kw = AXInline.keyWindowEditable(pid: st.pid) {
            let r = attrString(kw, kAXRoleAttribute as String) ?? "?"
            print("[keywin] 找到可编辑元素 role=\(r) editable=\(AXInline.isEditable(kw))")
            st.notes.append("key-window 可编辑回退：role=\(r)")
        } else {
            print("[keywin] 未找到 key window 内可编辑元素")
            st.notes.append("key-window 可编辑回退：未找到")
        }
        st.bodyRole = attrString(el, kAXRoleAttribute as String) ?? "?"
        st.bodyRectQuartz = rects(frameOf(el))
        st.windowTitle = found.window.flatMap { attrString($0, kAXTitleAttribute as String) } ?? ""

        // 3) AXValue 直写 → 读回核对
        let okWrite = setText(text, in: el)
        let back = attrString(el, kAXValueAttribute as String) ?? ""
        st.textLength = (back as NSString).length
        st.textSet = okWrite && back.contains(marker)
        if !st.textSet {
            st.reason = "文本没写进去（valueSettable=\(isSettable(el) ? "true" : "false"), 读回 \(st.textLength) 字）"
            st.notes.append("正文=「\(back.prefix(60))」")
            finish(6)
        }
        st.caret = setCaret(at: (back as NSString).length, in: el)
        st.notes.append("正文=「\(back.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))」")

        // 4) 只算不上屏，再 checkNow（--notify：不主动调用，只等 AXObserver 自己触发）
        InlineController.shared.overlay.silent = true
        let notifyOnly = argv.contains("--notify")
        if notifyOnly {
            st.notes.append("--notify：不代调 checkNow，只等 AXObserver + 800ms 去抖自己触发")
        } else {
            InlineController.shared.checkNow(for: st.pid, element: el)
        }

        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if !InlineController.shared.overlay.specs.isEmpty { break }
            let d = InlineController.shared.diag
            if notifyOnly {
                if d.checks > 0 { break }        // 观察者自己跑起来了
            } else if d.checks > 0 && d.lastError != "-" { break }
        }

        // 最小化状态下 AX 常常给不到矩形：如果是 --spawn 起的窗口又拿空，就短暂还原取一次再最小化
        if spawnedTemp != nil, InlineController.shared.overlay.specs.isEmpty, let win = found.window {
            setMinimized(win, false)
            try? await Task.sleep(nanoseconds: 800_000_000)
            InlineController.shared.overlay.silent = true
            InlineController.shared.checkNow(for: st.pid, element: el)
            let d2 = Date().addingTimeInterval(10)
            while Date() < d2 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !InlineController.shared.overlay.specs.isEmpty { break }
            }
            setMinimized(win, true)
            st.notes.append("最小化时拿不到矩形 → 已短暂还原窗口重取一次，随后立刻最小化")
        }

        let specs = InlineController.shared.overlay.specs
        st.underlineCount = specs.count
        st.rects = specs.map { rects($0.rect) }
        st.items = InlineController.shared.items.map {
            ["\($0.kind.rawValue)", $0.original, $0.replacement, "\($0.start)", "\($0.length)", $0.reason]
        }
        st.diag = InlineController.shared.diag.description
        st.ok = !specs.isEmpty

        if st.ok == false {
            let d = InlineController.shared.diag
            if d.checks == 0 { st.reason = "checkNow 一次都没跑（观察者/焦点未触发）" }
            else if d.lastError != "-" { st.reason = "引擎侧报错：\(d.lastError)" }
            else { st.reason = "检查跑了但产出 0 个矩形" }
        }

        // 5) 离屏合成图（不截屏：白底 + 正文区框 + 下划线矩形）
        let png = outDir + "/axcheck-underlines.png"
        st.snapshot = composite(specs: specs, body: CGRectFromArray(st.bodyRectQuartz), to: png) ? png : ""
        if st.snapshot.isEmpty { st.notes.append("离屏合成失败") }

        finish(st.ok ? 0 : 7)
    }

    // MARK: - 真机写回 + 撤销（--axaccept）：点卡片按钮走的是同一条代码路径
    //
    // 验收口径（知澜 15:35 定）：读回宿主 App 的 AXValue 比对，不信自己的日志。
    //   ok = 接受成功 && 读回正文 == 原文该段被替换后的结果 && 撤销成功 && 读回正文 == 原文

    struct AcceptStatus: Codable {
        var layer = "写回"
        var method = "InlineController.accept(itemID:) / undoLastAccept()（卡片按钮同一条路径）→ 读回宿主 AXValue 比对"
        var ok = false
        var reason = ""
        var timestamp = ""
        var app = ""
        var pid: Int32 = 0
        var textSet = false
        var itemCount = 0
        var targetIndex = -1
        var original = ""
        var replacement = ""
        var beforeText = ""
        var afterText = ""
        var undoneText = ""
        var expectedAfter = ""
        var acceptOK = false
        var undoOK = false
        var matchAccepted = false
        var matchUndone = false
        var diag = ""
        var notes: [String] = []
    }

    @MainActor
    static func acceptRun(_ argv: [String]) async {
        var st = AcceptStatus()
        st.timestamp = ISO8601DateFormatter().string(from: Date())
        let outDir = value(argv, "--axaccept") ?? (NSHomeDirectory() + "/dev/EnglishWriter/out")
        let bundle = value(argv, "--bundle") ?? "com.apple.TextEdit"
        let spawn = argv.contains("--spawn")
        let text = value(argv, "--text") ?? defaultText
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var temp: String? = nil

        func finish(_ code: Int32) -> Never {
            st.diag = InlineController.shared.diag.description
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(st) { try? d.write(to: URL(fileURLWithPath: outDir + "/axaccept-status.json")) }
            print("[axaccept] \(st.ok ? "OK" : "FAIL") accept=\(st.acceptOK) undo=\(st.undoOK) matchAccepted=\(st.matchAccepted) matchUndone=\(st.matchUndone) reason=\(st.reason)")
            InlineController.shared.clearUnderlines()
            if let t = temp {
                if let p = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
                    let pid = p.processIdentifier
                    kill(pid, SIGTERM); usleep(500_000)
                    if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
                    usleep(200_000)
                }
                try? FileManager.default.removeItem(atPath: t)
            }
            exit(code)
        }

        guard AXPermission.granted() else { st.reason = "无辅助功能权限"; finish(3) }

        var target = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        if target == nil {
            guard spawn else { st.reason = "目标 \(bundle) 未运行"; finish(8) }
            let tmp = NSTemporaryDirectory() + "ew-axaccept-\(getpid()).rtf"
            // 必须是**合法 RTF**：空文件会让 TextEdit 弹「打开文稿」选择器（0 documents、1 dialog window），
            // body() 就找不到任何 AXTextArea —— macOS 27 实测，这就是「窗口数=1 却没有正文」的根因。
            let rtf = "{\\rtf1\\ansi\\deff0 {\\fonttbl {\\f0 Helvetica;}}\\f0\\fs24 }"
            try? rtf.write(toFile: tmp, atomically: true, encoding: .utf8)
            temp = tmp
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
                st.reason = "找不到 \(bundle)"; finish(8)
            }
            let sem = DispatchSemaphore(value: 0)
            NSWorkspace.shared.open([URL(fileURLWithPath: tmp)], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 10)
            for _ in 0..<20 {
                if let a = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
                   windowCount(a.processIdentifier) > 0 { target = a; break }
                usleep(500_000)
            }
            guard let a = target, windowCount(a.processIdentifier) > 0 else {
                st.reason = "起了 \(bundle) 但没等到窗口"; finish(8)
            }
            if let win = windows(a.processIdentifier).first { setMinimized(win, true) }
            st.notes.append("【--spawn】临时空白文档，跑完杀掉、删临时文件")
        }
        guard let app = target else { st.reason = "目标未运行"; finish(8) }
        st.app = app.localizedName ?? bundle
        st.pid = app.processIdentifier

        guard let found = body(pid: st.pid, minArea: 4000) else {
            st.reason = "没有可写的 AXTextArea"; finish(5)
        }
        let el = found.element
        var win = found.window
        if temp != nil, let w = win { setMinimized(w, false) }        // 最小化拿不到矩形，写回前先还原
        defer { if temp != nil, let w = win { setMinimized(w, true) } }

        guard setText(text, in: el) else { st.reason = "文本没写进去"; finish(6) }
        st.textSet = true
        setCaret(at: (text as NSString).length, in: el)

        InlineController.shared.overlay.silent = true
        InlineController.shared.checkNow(for: st.pid, element: el)

        var items: [DiffItem] = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
            items = InlineController.shared.items
            if !items.isEmpty { break }
        }
        st.itemCount = items.count
        guard !items.isEmpty else {
            st.reason = "检查没产出条目（checks=\(InlineController.shared.diag.checks) err=\(InlineController.shared.diag.lastError)）"
            finish(7)
        }

        // 优先挑拼写那条（immediatly），结果最好比对
        var idx = items.firstIndex { $0.original.lowercased().contains("immediatly") } ?? 0
        if idx >= items.count { idx = 0 }
        let it = items[idx]
        st.targetIndex = idx
        st.original = it.original
        st.replacement = it.replacement

        func readBack() -> String { attrString(el, kAXValueAttribute as String) ?? "" }
        st.beforeText = readBack()
        let ns = st.beforeText as NSString
        if it.start + it.length <= ns.length {
            st.expectedAfter = ns.replacingCharacters(in: NSRange(location: it.start, length: it.length), with: it.replacement)
        }

        st.acceptOK = InlineController.shared.accept(itemID: idx)
        try? await Task.sleep(nanoseconds: 500_000_000)
        st.afterText = readBack()
        st.matchAccepted = !st.expectedAfter.isEmpty && st.afterText == st.expectedAfter

        st.undoOK = InlineController.shared.undoLastAccept()
        try? await Task.sleep(nanoseconds: 500_000_000)
        st.undoneText = readBack()
        st.matchUndone = !st.beforeText.isEmpty && st.undoneText == st.beforeText

        st.ok = st.acceptOK && st.matchAccepted && st.undoOK && st.matchUndone
        if !st.ok {
            if !st.acceptOK { st.reason = "接受写回 API 返回 false（\(InlineController.shared.diag.lastError)）" }
            else if !st.matchAccepted { st.reason = "接受后读回正文与期望不一致" }
            else if !st.undoOK { st.reason = "撤销 API 返回 false" }
            else { st.reason = "撤销后读回正文与原文不一致" }
        }
        _ = win
        finish(st.ok ? 0 : 9)
    }

    // MARK: 参数

    private static func value(_ argv: [String], _ flag: String) -> String? {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
        let v = argv[i + 1]
        return v.isEmpty ? nil : v
    }

    // MARK: - B 层观察器（--axwatch）：只监听，不敲键、不上屏
    //
    // 用法：爹地自己在 TextEdit 里敲；本模式每 500ms 把 diag/specs 落盘，
    // 用来回答「AXObserver 挂上没有 / 800ms 去抖触发没有 / 有没有产出矩形」。
    // 铁律：overlay 全程 silent（一个像素都不上屏），不发送任何事件。

    struct WatchEvent: Codable {
        var t: Double
        var diag: String
        var rects: Int
        var pid: Int32
        var sentenceApprox: String
    }

    @MainActor
    static func watch(_ argv: [String]) async {
        let outDir = value(argv, "--axwatch") ?? (NSHomeDirectory() + "/dev/EnglishWriter/out")
        let seconds = Double(value(argv, "--seconds") ?? "") ?? 120
        let bundle = value(argv, "--bundle") ?? "com.apple.TextEdit"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let jsonPath = outDir + "/axwatch-status.json"
        let logPath = outDir + "/axwatch-events.log"

        var started = Status()
        started.layer = "B"
        started.method = "AXObserver + 800ms 去抖（爹地真人敲键，我只监听；无键击、无截屏、下划线不上屏）"
        started.timestamp = ISO8601DateFormatter().string(from: Date())
        started.app = bundle
        started.notes.append("观察窗口 \(Int(seconds))s；看到的就是常驻感知层的真实反应")

        func flush(_ st: Status, events: [WatchEvent]) {
            var s = st
            s.diag = InlineController.shared.diag.description
            let specs = InlineController.shared.overlay.specs
            s.underlineCount = specs.count
            s.rects = specs.map { rects($0.rect) }
            s.items = InlineController.shared.items.map {
                ["\($0.kind.rawValue)", $0.original, $0.replacement, "\($0.start)", "\($0.length)", $0.reason]
            }
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(s) { try? d.write(to: URL(fileURLWithPath: jsonPath)) }
            if let le = try? JSONEncoder().encode(events) {
                try? le.write(to: URL(fileURLWithPath: logPath))
            }
        }

        guard AXPermission.granted() else {
            started.reason = "无辅助功能权限（必须 open -a 起 App）"
            started.ok = false
            flush(started, events: [])
            exit(3)
        }

        var events: [WatchEvent] = []
        var lastDiag = ""
        let t0 = Date()
        print("[axwatch] 开始监听 \(Int(seconds))s —— 去 \(bundle) 里正常打字即可")

        while Date().timeIntervalSince(t0) < seconds {
            try? await Task.sleep(nanoseconds: 500_000_000)
            InlineController.shared.overlay.silent = true      // clear() 会复位，每拍补一次
            let d = InlineController.shared.diag
            let desc = d.description
            if desc != lastDiag {
                lastDiag = desc
                let el = InlineController.shared.currentElement
                let approx = el.flatMap { attrString($0, kAXValueAttribute as String) }
                    .map { String($0.suffix(60)) } ?? ""
                events.append(WatchEvent(t: Date().timeIntervalSince(t0),
                                         diag: desc,
                                         rects: InlineController.shared.overlay.specs.count,
                                         pid: InlineController.shared.currentPid,
                                         sentenceApprox: approx))
                flush(started, events: events)
            }
        }

        let d = InlineController.shared.diag
        started.ok = d.checks > 0
        started.textSet = d.checks > 0
        started.reason = d.checks == 0
            ? "整段观察期 checks 仍为 0 —— AXObserver 没触发（挂载或通知问题，不是引擎问题）"
            : "checks=\(d.checks) requests=\(d.requests) dedupe=\(d.dedupedHits) rects=\(InlineController.shared.overlay.specs.count)"
        started.diag = d.description
        started.underlineCount = InlineController.shared.overlay.specs.count
        started.rects = InlineController.shared.overlay.specs.map { rects($0.rect) }
        flush(started, events: events)
        print("[axwatch] 结束：\(started.reason)")
        exit(started.ok ? 0 : 11)
    }

    // MARK: 找正文容器

    struct Body { var element: AXUIElement; var window: AXUIElement? }

    private static func windowCount(_ pid: pid_t) -> Int { windows(pid).count }

    private static func windows(_ pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        return (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func body(pid: pid_t, minArea: CGFloat) -> Body? {
        var best: (area: CGFloat, body: Body)?
        for win in windows(pid) {
            for el in textAreas(in: win, depth: 8) {
                let f = frameOf(el)
                let area = f.width * f.height
                guard area >= minArea, isSettable(el) else { continue }
                if best == nil || area > best!.area { best = (area, Body(element: el, window: win)) }
            }
        }
        return best?.body
    }

    private static func textAreas(in el: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var out: [AXUIElement] = []
        for c in (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] {
            let role = attrString(c, kAXRoleAttribute as String) ?? ""
            if role == "AXTextArea" || role == "AXTextField" || role == "AXWebArea" {
                out.append(c)
            }
            out.append(contentsOf: textAreas(in: c, depth: depth - 1))
        }
        return out
    }

    // MARK: AX 读写

    /// 最小化/还原窗口（爹地口径：开的窗口立刻最小化，后台操作）
    private static func setMinimized(_ win: AXUIElement, _ on: Bool) {
        let v: CFBoolean = on ? kCFBooleanTrue : kCFBooleanFalse
        _ = AXUIElementSetAttributeValue(win, kAXMinimizedAttribute as CFString, v)
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private static func attrString(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    private static func isSettable(_ el: AXUIElement) -> Bool {
        var b = DarwinBoolean(false)
        let ok = AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &b) == .success
        return ok && b.boolValue
    }

    private static func setText(_ text: String, in el: AXUIElement) -> Bool {
        if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success,
           (attrString(el, kAXValueAttribute as String) ?? "").contains(marker) {
            return true
        }
        // 退化：全选 + 写选区
        let len = (attrString(el, kAXValueAttribute as String) as NSString?)?.length ?? 0
        var r = CFRange(location: 0, length: max(1, len))
        if let v = AXValueCreate(.cfRange, &r) {
            _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        }
        _ = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        return (attrString(el, kAXValueAttribute as String) ?? "").contains(marker)
    }

    @discardableResult
    private static func setCaret(at offset: Int, in el: AXUIElement) -> Int {
        var r = CFRange(location: offset, length: 0)
        if let v = AXValueCreate(.cfRange, &r) {
            _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        }
        var cur = CFRange(location: -1, length: 0)
        if let back = attr(el, kAXSelectedTextRangeAttribute as String),
           CFGetTypeID(back) == AXValueGetTypeID(),
           AXValueGetValue(back as! AXValue, .cfRange, &cur) {
            return cur.location
        }
        return -1
    }

    // MARK: 几何

    private static func frameOf(_ el: AXUIElement) -> CGRect {
        var rect = CGRect.zero
        if let p = attr(el, kAXPositionAttribute as String), CFGetTypeID(p) == AXValueGetTypeID() {
            var pt = CGPoint.zero
            if AXValueGetValue(p as! AXValue, .cgPoint, &pt) { rect.origin = pt }
        }
        if let s = attr(el, kAXSizeAttribute as String), CFGetTypeID(s) == AXValueGetTypeID() {
            var sz = CGSize.zero
            if AXValueGetValue(s as! AXValue, .cgSize, &sz) { rect.size = sz }
        }
        return rect
    }

    private static func rects(_ r: CGRect) -> [Int] {
        [Int(r.origin.x.rounded()), Int(r.origin.y.rounded()),
         Int(r.size.width.rounded()), Int(r.size.height.rounded())]
    }

    private static func CGRectFromArray(_ a: [Int]) -> CGRect {
        guard a.count == 4 else { return .zero }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }

    // MARK: 离屏合成（零截屏）

    private static func composite(specs: [UnderlineSpec], body: CGRect, to path: String) -> Bool {
        guard body.width > 10, body.height > 10 else { return false }
        let size = NSSize(width: body.width, height: body.height)
        let w = Int(size.width), h = Int(size.height)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
        let framePath = NSBezierPath(rect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
        framePath.lineWidth = 1
        framePath.stroke()
        // 下划线 rect 是 Quartz（左上原点）全局坐标 → 转成正文区局部
        let cg = NSGraphicsContext.current!.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        for s in specs {
            UnderlinePainter.stroke(s.rect.offsetBy(dx: -body.minX, dy: -body.minY), s.kind)
        }
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: 落盘

    private static func write(_ st: Status, to dir: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(st) {
            try? d.write(to: URL(fileURLWithPath: dir + "/axcheck-status.json"))
        }
    }
}
