// Inline.swift — 常驻 + 输入即检查 + 行内下划线（M1/M2 的主干）
//
// 流程：AXObserver 监听焦点元素的 kAXValueChanged / kAXSelectedTextChanged
//      → 去抖 800ms → 取全文 → 语言门控（中文零请求）→ 抽出光标所在句
//      → 引擎出逐条 diff → 每条算 AXBoundsForRange 多行矩形 → 覆盖窗口画线。
//
// 纪律（取代 v0.1 的「不装 observer」）：允许 AXObserver，但必须节流 ——
// 每个 pid 只挂一个 observer、检查去抖、同文本 hash 不重复请求、无轮询 Timer。

import AppKit
import ApplicationServices

// MARK: - AX 文本 → 屏幕矩形

/// AX 元素的全局矩形（Quartz，左上原点）
func elementRectQuartz(_ el: AXUIElement) -> CGRect {
    var r = CGRect.zero
    var pos: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
       let pv = pos, CFGetTypeID(pv) == AXValueGetTypeID() {
        var p = CGPoint.zero
        if AXValueGetValue(pv as! AXValue, .cgPoint, &p) { r.origin = p }
    }
    var size: CFTypeRef?
    if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
       let sv = size, CFGetTypeID(sv) == AXValueGetTypeID() {
        var sz = CGSize.zero
        if AXValueGetValue(sv as! AXValue, .cgSize, &sz) { r.size = sz }
    }
    return r
}

/// pid → 应用名（只用于观察日志，取不到就是 "?"）
func appName(_ pid: pid_t) -> String {
    pid > 0 ? (NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?") : "?"
}

enum AXInline {
    /// 焦点文本框里的全文
    /// 可编辑元素判定（爹地 11-19 P0：只检查可编辑区域，只读正文一个字都不许碰）
    /// 命中任一即算可编辑：
    ///   · role ∈ AXTextArea / AXTextField / AXComboBox
    ///   · kAXEditableAttribute == true
    /// 其余（AXStaticText / 只读 AXWebArea / 列表行 / 说明文字）一律不是
    static func isEditable(_ el: AXUIElement) -> Bool {
        var roleRaw: CFTypeRef?
        var role = ""
        if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRaw) == .success,
           let r = roleRaw as? String { role = r }

        var editRaw: CFTypeRef?
        var editable = false
        if AXUIElementCopyAttributeValue(el, "AXEditable" as CFString, &editRaw) == .success,
           let b = editRaw as? Bool { editable = b }
        if editable { return true }
        return role == kAXTextAreaRole as String
            || role == kAXTextFieldRole as String
            || role == kAXComboBoxRole as String
    }

    static func fullText(of el: AXUIElement) -> String? {
        if let v = attrString(el, kAXValueAttribute as String), !v.isEmpty { return v }
        // Web 输入框常见：value 在子节点上
        for child in descendants(el, depth: 3) {
            if let v = attrString(child, kAXValueAttribute as String), !v.isEmpty { return v }
        }
        return nil
    }

    /// 兜底：焦点元素不是文本框时（焦点落在窗口/工具栏上），取前台窗口里最大的可读 AXTextArea。
    /// 2026-11-16 真机实测：observer 有时在焦点落到窗口本身时触发，读不到内容 → 白丢一次检查（err=读不到文本框内容）
    static func biggestTextArea(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        let wins = (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        var best: (area: CGFloat, el: AXUIElement)?
        for w in wins {
            for el in descendants(w, depth: 8) {
                guard (attrString(el, kAXRoleAttribute as String) ?? "") == "AXTextArea" else { continue }
                guard let v = attrString(el, kAXValueAttribute as String), !v.isEmpty else { continue }
                var r = CGRect.zero
                if let p = attr(el, kAXPositionAttribute as String), CFGetTypeID(p) == AXValueGetTypeID() {
                    var pt = CGPoint.zero
                    if AXValueGetValue(p as! AXValue, .cgPoint, &pt) { r.origin = pt }
                }
                if let s = attr(el, kAXSizeAttribute as String), CFGetTypeID(s) == AXValueGetTypeID() {
                    var sz = CGSize.zero
                    if AXValueGetValue(s as! AXValue, .cgSize, &sz) { r.size = sz }
                }
                let area = r.width * r.height
                if best == nil || area > best!.area { best = (area, el) }
            }
        }
        return best?.el
    }

    static func focusedElement(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        guard let f = attr(appEl, kAXFocusedUIElementAttribute as String) else { return nil }
        let el = f as! AXUIElement
        AXUIElementSetMessagingTimeout(el, 0.25)
        return findEditableAncestor(el) ?? el
    }

    /// key window 里第一个**可编辑**元素（不是「最大的文本框」，不跨窗口、不比较大小、不猜）。
    /// 场景：窗口在、可编辑框在，但 kAXFocusedUIElementAttribute 这一轮返回空
    /// （窗口非 key 前的一瞬 / AX 短暂沉默 / overlay 抢过 key）。
    /// 仍然过 editable 门槛：只读正文照样不碰。
    static func keyWindowEditable(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        var win: AXUIElement?
        for key in [kAXFocusedWindowAttribute as String, kAXMainWindowAttribute as String] {
            if let v = attr(appEl, key) {
                win = (v as! AXUIElement)
                break
            }
        }
        // App 没被激活时 focused/main window 都可能取不到（真机 TextEdit 实测），
        // 退到 AXWindows[0]：仍是「当前这台 App 的窗口」，不跨 App、不猜。
        if win == nil, let ws = attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement],
           let first = ws.first {
            win = first
        }
        guard let w = win else { return nil }
        var queue: [AXUIElement] = [w]
        var steps = 0
        while !queue.isEmpty, steps < 600 {
            let cur = queue.removeFirst()
            steps += 1
            if cur !== w, isEditable(cur) { return cur }
            let kids = (attr(cur, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
            queue.append(contentsOf: kids)
        }
        return nil
    }

    // MARK: Web 正文与 Chromium 无障碍（真机 2026-11-19 实测的两处断点）

    /// Chromium 系（Chrome / Edge / Brave / Electron）：不显式置这两个属性，AX 树里永远没有 AXWebArea，
    /// 现场表现就是 attach-el-fail「没有焦点元素」（本机 Chrome 逐条实测）。
    static let chromiumBundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "org.chromium.Chromium",
        "com.microsoft.edgemac", "com.brave.Browser", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera", "com.github.Electron",
    ]

    static func isChromium(_ pid: pid_t) -> Bool {
        guard pid > 0, let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return chromiumBundles.contains(b) || b.hasSuffix(".Electron")
    }

    @discardableResult
    static func enableWebAX(_ pid: pid_t) -> Bool {
        guard isChromium(pid) else { return false }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        let m = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let e = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return m == .success || e == .success
    }

    /// 前台窗口里的正文容器：优先 AXWebArea（Mail 写信 / 网页），没有才落 AXTextArea。
    /// 真机 2026-11-19：Mail 写信窗口的焦点元素落在 WebArea 外层、AXValue 恒空 →
    /// checkNow 停在 no-text「读不到文本框内容」，一个字都不检查；探针能读到正文，差的就是这一层兜底。
    static func frontWindowBody(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        var ordered: [AXUIElement] = []
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let v = attr(appEl, key as String), CFGetTypeID(v) == AXUIElementGetTypeID() {
                ordered.append(v as! AXUIElement)
            }
        }
        ordered.append(contentsOf: (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [])
        for w in ordered {
            if let b = WebText.body(in: w) { return b }
        }
        return nil
    }

    /// WebArea 里的真输入控件：网页里的 textarea/input 在 AX 树里是 AXTextArea/AXTextField，
    /// AXValue 直接有内容（Chromium 真机实测）。有它就优先用它 —— 整页静态文本当正文会查错地方。
    static func textField(in body: AXUIElement) -> AXUIElement? {
        var best: (el: AXUIElement, len: Int)?
        for el in descendants(body, depth: 10) {
            let role = attrString(el, kAXRoleAttribute as String) ?? ""
            guard role == "AXTextArea" || role == "AXTextField" else { continue }
            let v = attrString(el, kAXValueAttribute as String) ?? ""
            guard !v.isEmpty else { continue }
            let f = WebText.frame(el)
            guard f.width * f.height > 2000 else { continue }        // 搜索框之类的小控件不要
            if best == nil || v.utf16.count > best!.len { best = (el, v.utf16.count) }
        }
        return best?.el
    }

    static func selectedRange(_ el: AXUIElement) -> NSRange? {
        guard let r = attr(el, kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(r) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(r as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    /// 单段 range → 屏幕矩形（Quartz 口径，左上原点）。AXBoundsForRange 拿不到就找叶节点。
    static func bounds(of ns: NSRange, in el: AXUIElement) -> CGRect? {
        if let r = rawBounds(ns, in: el) { return r }
        // Chromium wrapper 返回零尺寸 → 下钻到有真值的叶节点
        let needle = (attrString(el, kAXValueAttribute as String) as NSString?)?
            .substring(with: ns) ?? ""
        guard !needle.isEmpty else { return nil }
        for leaf in descendants(el, depth: 6) {
            guard let v = attrString(leaf, kAXValueAttribute as String) as NSString?,
                  v.length > 0 else { continue }
            let hit = v.range(of: needle)
            guard hit.location != NSNotFound,
                  let r = rawBounds(hit, in: leaf), r.width > 0, r.height > 0 else { continue }
            return r
        }
        return nil
    }

    private static func rawBounds(_ ns: NSRange, in el: AXUIElement) -> CGRect? {
        guard let v = axRangeValue(ns.location, ns.length) else { return nil }
        var out: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(
            el, "AXBoundsForRange" as CFString, v, &out)
        guard err == .success, let o = out, CFGetTypeID(o) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(o as! AXValue, .cgRect, &rect) else { return nil }
        guard rect.width > 0 || rect.height > 0 else { return nil }
        return rect
    }

    /// 一条错误 → 按视觉行拆开的多个矩形（Grammarly 的 HighlightRects 结构）
    static func lineRects(for ns: NSRange, in el: AXUIElement) -> [CGRect] {
        guard ns.length > 0 else { return [] }
        let nsStr = (attrString(el, kAXValueAttribute as String) as NSString?)
        // 整段先量一次：只有一行就省掉切片
        if let whole = bounds(of: ns, in: el), whole.height > 0 {
            let singleLineMax = whole.height * 1.6
            if whole.height <= singleLineMax && nsStr != nil {
                // 高度像一行 → 仍需切片确认（多行时 union 盒高度会明显更大）
                let slice = max(2, min(6, ns.length))
                var ys = Set<Int>()
                var i = ns.location
                while i < ns.location + ns.length {
                    let len = min(slice, ns.location + ns.length - i)
                    if let r = bounds(of: NSRange(location: i, length: len), in: el) {
                        ys.insert(Int(r.midY / 4))
                    }
                    i += len
                }
                if ys.count <= 1 { return [whole] }
            }
        }
        // 切片 → 按行分组 → 每行取并集
        let slice = max(2, min(6, max(1, ns.length / 3)))
        var rects: [CGRect] = []
        var i = ns.location
        let end = ns.location + ns.length
        while i < end {
            let len = min(slice, end - i)
            if let r = bounds(of: NSRange(location: i, length: len), in: el) {
                rects.append(r)
            }
            i += len
        }
        guard !rects.isEmpty else { return [] }
        var groups: [[CGRect]] = []
        for r in rects.sorted(by: { $0.midY < $1.midY }) {
            if var last = groups.last, let ref = last.first,
               abs(ref.midY - r.midY) < max(4, ref.height * 0.6) {
                last.append(r)
                groups[groups.count - 1] = last
            } else {
                groups.append([r])
            }
        }
        return groups.map { ScreenGeom.union($0) }
    }

    /// 整段文本（如文本框）所有行的矩形，用于对齐校验 / 调试
    static func allLineRects(in el: AXUIElement, text: String) -> [CGRect] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        return lineRects(for: NSRange(location: 0, length: ns.length), in: el)
    }

    static func descendants(_ el: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var out: [AXUIElement] = []
        for c in attrChildren(el) {
            out.append(c)
            out.append(contentsOf: descendants(c, depth: depth - 1))
        }
        return out
    }
}

// MARK: - 句子抽取（只检查光标所在句，和 Grammarly 一样按句判断）

enum Sentence {
    static func around(caret: Int, in text: String) -> NSRange {
        let ns = text as NSString
        let len = ns.length
        guard len > 0 else { return NSRange(location: 0, length: 0) }
        let pos = min(max(caret, 0), len - 1)
        let terminators = CharacterSet(charactersIn: ".!?\n。！？")
        var start = 0
        var i = pos
        while i > 0 {
            let r = ns.rangeOfCharacter(from: terminators, options: [], range: NSRange(location: i - 1, length: 1))
            if r.location != NSNotFound { start = i; break }
            i -= 1
        }
        var end = len
        var j = pos
        while j < len {
            let r = ns.rangeOfCharacter(from: terminators, options: [], range: NSRange(location: j, length: 1))
            if r.location != NSNotFound { end = j + 1; break }
            j += 1
        }
        if end <= start { end = min(len, start + 1) }
        return NSRange(location: start, length: end - start)
    }

    static func text(_ r: NSRange, in text: String) -> String {
        (text as NSString).substring(with: r)
    }
}

// MARK: - 控制器

@MainActor
final class InlineController {
    static let shared = InlineController()

    let overlay = UnderlineOverlay()
    private(set) var enabled = true
    private(set) var items: [DiffItem] = []
    private(set) var lastText: String = ""
    private(set) var lastFocusPid: pid_t = 0
    /// 最近一次检查的落点：卡片接受/忽略要往这里写回
    private(set) var currentElement: AXUIElement?
    private(set) var currentPid: pid_t = 0
    private(set) var currentSentenceRange: NSRange = NSRange(location: 0, length: 0)
    /// Web 正文的文本块 + items[i] 属于哪个块（-1 = 原生输入框，偏移是全文的）
    private(set) var blocks: [WebText.Block] = []
    private(set) var itemBlock: [Int] = []
    private var overlayPid: pid_t = 0

    var debounce: TimeInterval = 0.8
    var diag = InlineDiag()

    private var observer: AXObserver?
    private var observedPid: pid_t = 0
    private var observedElement: AXUIElement?
    /// Chromium AX 树异步出现 → 挂载失败后的重试计数（每个 pid 独立，成功即清零）
    private var attachRetries: [pid_t: Int] = [:]
    private var pending: DispatchWorkItem?
    /// 网页块检查重入闸门：1s 轮询 × 单次几十秒 = 请求无限堆叠（11-23 事故）
    private var webCheckRunning = false
    private var webCheckDirty = false
    /// 单次检查的块数上限：可见区再大也不许超过这个数（一屏正常 < 40 块）
    private let webMaxBlocks = 40
    private var lastHash: [pid_t: String] = [:]
    private var focusObserver: Any?
    private var suppressing = false

    /// 被动观察事件（--passive 模式落 JSONL；只存元信息，不存正文）
    struct CheckEvent {
        var kind: String            // check / skip-cjk / no-text / render
        var pid: pid_t
        var app: String
        var role: String
        var textLen: Int
        var sentenceLen: Int
        var itemCount: Int
        var rectCount: Int
        var elapsed: String
        var err: String
        var at: Date
        /// 走的那条读取通道：value / statictext(块N) / none（区分「压根没走文本块」和「走了但块为 0」）
        var path: String = "-"
    }
    /// 外部注册的观察者（--passive 用）。默认 nil = 零开销。
    var onCheck: ((CheckEvent) -> Void)?

    private func emit(_ e: CheckEvent) {
        var ev = e
        if ev.path == "-" { ev.path = diag.lastPath }
        onCheck?(ev)
        CheckLog.append(ev)     // 常驻落盘：爹地「打了没反应」时，我能拿事实说话
    }

    struct InlineDiag: CustomStringConvertible {
        var checks = 0
        var requests = 0
        var skippedChinese = 0
        var dedupedHits = 0
        var fallbackTextArea = 0        // 焦点落空、改取窗口里最大 AXTextArea 的次数
        var lastError = "-"
        var lastElapsed = "-"
        var lastRectCount = 0
        var lastTextLen = 0            // 上一次真正取到的字数（0 = 没读到，球该是灰的）
        var lastPath = "-"             // 走的那条通道：value / statictext(块N) / none
        var engineChoice = "语法：未定"
        var description: String {
            "checks=\(checks) requests=\(requests) cjkSkip=\(skippedChinese) dedupe=\(dedupedHits) fallback=\(fallbackTextArea) rects=\(lastRectCount) chars=\(lastTextLen) path=\(lastPath) elapsed=\(lastElapsed) err=\(lastError) | \(engineChoice)"
        }
    }

    // MARK: 生命周期

    func start() {
        guard focusObserver == nil else { return }
        HoverCoordinator.shared.start()      // 悬停卡片（全局 mouseMoved + 200ms 停留）
        overlay.startTTLWatchdog()           // 线超过 2s 没被确认就自灭，屏幕上不留残影
        // 滚动一起手就清线，80ms 后按新位置重画 —— 不用等 1s 复验（知澜给的全局滚动事件方案）
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            Task { @MainActor in
                self?.overlay.clear()
                self?.scheduleQuickCheck(after: 0.08)
            }
        }
        scrollMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            Task { @MainActor in
                self?.overlay.clear()
                self?.scheduleQuickCheck(after: 0.08)
            }
            return e
        }
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            // 不要用 MainActor.assumeIsolated：这个通知由 AppKit 的
            // applicationStatusSubsystemCallback 投递，闭包不在 Swift Concurrency 的
            // main executor 上下文里，assumeIsolated 会直接崩（本机 11-16 / 11-18 / 11-19
            // 共 8 份崩溃报告都是这一处，切 App 时随机崩）。手动判定线程 + 派发即可。
            let apply = { [weak self] in
                // 切 App：立刻清线（否则旧 App 的线留在屏幕上飘）
                self?.overlay.clear()
                self?.lastFocusPid = app.processIdentifier
                self?.attachObserver(pid: app.processIdentifier)
                self?.scheduleQuickCheck(after: 0.08)   // 清完马上重画，不是留空白
            }
            if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
        }
        startPolling()
        // 定期复验：有线挂着就每秒重跑一次检查，把 stamp 刷新到当下。
        // 没有这一步，2s 自灭会把「一直没改动的正确线」也灭掉。
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.overlay.hasUnderlines else { return }
                self.checkNow()
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastFocusPid = front.processIdentifier
            attachObserver(pid: front.processIdentifier)
        }
    }

    /// 给菜单/卡片看的一句话状态（改写用；走同一条 diag 通道，面板上能看到）
    func noteForRewrite(_ msg: String) { diag.lastError = msg }

    /// 改写建议用：读当前焦点元素 / 选区 / 全文
    @MainActor
    func rewriteContext() -> (element: AXUIElement, pid: pid_t, full: String, sel: NSRange)? {
        let pid = lastFocusPid
        guard pid > 0, let el = AXInline.focusedElement(pid: pid),
              let full = AXInline.fullText(of: el) else { return nil }
        let sel = AXInline.selectedRange(el) ?? currentSentenceRange
        let ns = full as NSString
        let clamped = NSRange(location: min(sel.location, ns.length),
                              length: min(sel.length, max(0, ns.length - min(sel.location, ns.length))))
        guard clamped.length > 0 else { return nil }
        // ① 逐 App 适配：没有配置或配置为关 → 不工作（不再靠「通用探测」猜）
        let app = appName(pid)
        if let cfg = Integrations.integration(bundleId: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "", appName: app) {
            _ = cfg
        } else if Integrations.all.contains(where: { $0.id == app && !$0.isEnabled }) {
            emit(CheckEvent(kind: "skip-app-disabled", pid: pid, app: app,
                            role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "该 App 适配未探明，已关闭", at: Date()))
            return nil
        }

        // ② 隐私硬规矩：敏感字段（密码/账号/地址/卡号/id…）一律不激活
        var idParts: [String] = []
        for attrName in [kAXIdentifierAttribute, kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let v = attrString(el, attrName as String) { idParts.append(v) }
        }
        if Integrations.isSensitive(text: idParts.joined(separator: " ")) {
            emit(CheckEvent(kind: "skip-sensitive", pid: pid, app: app,
                            role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "敏感字段（命中关键词黑名单）", at: Date()))
            return nil
        }

        currentElement = el
        currentPid = pid
        return (el, pid, full, clamped)
    }

    /// 改写建议：把候选的逐条 diff 当作本次条目（不刷新 UI、不重查）
    func adoptForRewrite(_ newItems: [DiffItem]) {
        items = newItems
        itemBlock = newItems.map { _ in -1 }
    }

    /// 改写建议：整段撤销快照（回滚仍走 undoLastAccept，不另造一套）
    func setUndoSnapshot(_ item: DiffItem, snapshot: String, element: AXUIElement?) {
        let pid = currentPid
        let doc: M3Doc
        if let el = element {
            let readable = !(AXInline.fullText(of: el) ?? "").isEmpty
            doc = ClosureDoc(pid: pid, canReadBack: readable,
                             read: { AXInline.fullText(of: el) ?? snapshot },
                             writeRange: { [weak self] r, t in
                                 self?.layeredWrite(range: r, text: t, to: el, pid: pid) ?? false
                             },
                             writeFull: { [weak self] t in
                                 self?.writeWhole(t, to: el, pid: pid) ?? false
                             })
        } else {
            doc = BufferDoc(snapshot, pid: pid)
        }
        M3UndoStack.shared.push(M3UndoEntry(itemID: -1, pid: pid,
                                            range: NSRange(location: item.start,
                                                           length: (item.replacement as NSString).length),
                                            original: item.original, replacement: item.replacement,
                                            snapshot: snapshot, newText: doc.fullText,
                                            doc: doc, at: Date()))
        AppLog.info("m3", "undo-snapshot pid=\(pid) range=\(item.start)+\((item.replacement as NSString).length) snapshotLen=\((snapshot as NSString).length)")
    }

    /// 轮询兜底：布局/焦点通知会丢（知洲 11-18 指出的 Grammarly 行为：每秒轮一次）。
    /// 只读文本比对，不直接调引擎；文本变了才走正常去抖检查。
    private var pollTimer: Timer?
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // 锁屏 / 登录窗 / 未启用：都不轮询（纯函数 ScreenLock.shouldPoll 负责判定）
                guard ScreenLock.shouldPoll(locked: ScreenLock.isLocked, enabled: self.enabled,
                                            pid: self.lastFocusPid,
                                            appName: appName(self.lastFocusPid)) else { return }
                guard let el = AXInline.focusedElement(pid: self.lastFocusPid) else { return }
                // Web 正文的 AXValue 是空的，直接读它等于永远「没变化」——这就是 Mail 里一直没反应的根因之一
                let t: String?
                if WebText.isWebBody(el) {
                    // 只比「看得见的部分」：全量遍历整个文档（实测 1477 块）每秒一次，
                    // 光 AX 读取就能吃满一个核，而且文本一滚就整篇算「变了」→ 无限重查。
                    let blks = WebText.visibleBlocks(of: el)
                    let joined = blks.map(\.text).joined(separator: "\n")
                    // 轮询自己也要留证据：Web 正文到底读出几块、几个字（没声音时靠这行判断）
                    self.emit(CheckEvent(kind: "web-poll", pid: self.lastFocusPid,
                                         app: appName(self.lastFocusPid),
                                         role: attrString(el, kAXRoleAttribute as String) ?? "",
                                         textLen: (joined as NSString).length, sentenceLen: 0,
                                         itemCount: 0, rectCount: 0,
                                         elapsed: "-", err: "blocks=\(blks.count)", at: Date()))
                    t = joined.isEmpty ? nil : joined
                } else {
                    t = AXInline.fullText(of: el)
                }
                guard let t else { return }
                if t != self.lastText { self.scheduleCheck(delay: 0.2) }
            }
        }
    }

    /// 打开建议侧栏（当前输入框的这批建议；外部 App 的侧栏入口）
    var isSidebarVisible: Bool { Sidebar.shared.isVisible }

    func hideSidebar() { Sidebar.shared.orderOutAndClear() }

    func showSidebar() {
        // Grammarly 口径：0 条也开（面板里显示「没有更多建议」+ 评分），
        // 否则「点球没反应」会被当成缺陷——旧代码这里 guard !items.isEmpty 直接 return。
        let score = Scorer.score(text: lastText, items: items, formality: GoalsStore.load().formality)
        let sb = Sidebar.shared
        sb.onAccept = { [weak self] it in
            guard let self, let id = self.items.firstIndex(where: { $0.start == it.start && $0.length == it.length })
            else { return }
            _ = self.accept(itemID: id)
        }
        sb.onDismiss = { [weak self] it in
            Task { @MainActor in
                guard let self else { return }
                self.dropItem(start: it.start, length: it.length)
            }
        }
        sb.onJump = { [weak self] it in
            Task { @MainActor in
                guard let self,
                      let id = self.items.firstIndex(where: { $0.start == it.start && $0.length == it.length })
                else { return }
                self.focusItem(id: id)
            }
        }
        sb.onAcceptAll = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let ids = self.items.indices.sorted { self.items[$0].start > self.items[$1].start }
                var applied = 0
                for id in ids where self.accept(itemID: id) { applied += 1 }
                if applied > 0 { Toast.show("已改 \(applied) 处 · ⌘Z 撤销") }
            }
        }
        let ballRect = FloatBall.shared.isVisible ? FloatBall.shared.frame : nil
        sb.present(items: items, score: score, at: ballRect)
    }

    /// 侧栏开着时，每次新检查结果都要推进去（Grammarly 的栏是实时跟着字变的，
    /// 打开那一刻定格的栏会立刻露馅）。没开就什么都不做，避免白白重排。
    private func syncSidebarIfOpen() {
        guard Sidebar.shared.isVisible else { return }
        let score = Scorer.score(text: lastText, items: items, formality: GoalsStore.load().formality)
        // at: nil = 保持用户当前拖动到的位置，不重新贴球
        Sidebar.shared.present(items: items, score: score, at: nil)
    }

    /// 忽略一条：只去掉这条线与卡片，不改宿主文本
    func dropItem(start: Int, length: Int) {
        // 先按 itemID 摘掉对应的线，再从列表移除（避免移除后 index 全体位移）
        let removedIDs = Set(items.indices.filter { (i: Int) -> Bool in
            items[i].start == start && items[i].length == length
        })
        let keep = overlay.specs.filter { (sp: UnderlineSpec) -> Bool in !removedIDs.contains(sp.itemID) }
        items.removeAll(where: { (it: DiffItem) -> Bool in it.start == start && it.length == length })
        overlay.render(keep)
    }

    /// 侧栏「定位」：把宿主光标挪到该条并闪示（不改文本、不抢输入焦点）
    func focusItem(id: Int) {
        guard items.indices.contains(id) else { return }
        let it = items[id]
        if let el = currentElement {
            // 原生文本框：直接设选区块
            func setRange(_ e: AXUIElement, _ loc: Int, _ len: Int) {
                var r = CFRange(location: loc, length: len)
                if let v = AXValueCreate(.cfRange, &r) {
                    AXUIElementSetAttributeValue(e, kAXSelectedTextRangeAttribute as CFString, v)
                }
            }
            if AXInline.selectedRange(el) != nil {
                setRange(el, it.start, it.length)
            } else if itemBlock.indices.contains(id), blocks.indices.contains(itemBlock[id]) {
                // Web 正文：把块内偏移折算到该块的 AX range
                var local = it.start
                for b in blocks where b.element !== blocks[itemBlock[id]].element {
                    local -= (b.text as NSString).length
                }
                let block = blocks[itemBlock[id]]
                setRange(block.element, max(0, local), it.length)
            }
        }
        if let spec = overlay.specs.first(where: { $0.itemID == id }) {
            overlay.highlight(spec.rect)
        }
    }

    /// 被动/验收模式用：onCheck 装好之后再补挂一次前台 App
    /// （start() 早于 onCheck 赋值，否则「启动时前台已是你正在打字的 App」这类情况会一条事件都不发）
    func reattachFrontmost() {
        guard enabled, AXPermission.granted() else { return }
        startPolling()
        // 定期复验：有线挂着就每秒重跑一次检查，把 stamp 刷新到当下。
        // 没有这一步，2s 自灭会把「一直没改动的正确线」也灭掉。
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.overlay.hasUnderlines else { return }
                self.checkNow()
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastFocusPid = front.processIdentifier
            attachObserver(pid: front.processIdentifier)
        }
    }

    func stop() {
        detachObserver()
        HoverCoordinator.shared.stop()
        if let f = focusObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(f)
            focusObserver = nil
        }
        overlay.clear()
    }

    func setEnabled(_ on: Bool) {
        enabled = on
        if !on { overlay.clear(); items = [] }
    }

    // MARK: observer

    /// App 排除闸门（唯一判定点）：命中的 App 一个 AXObserver 都不挂、不检查、不画线。
    /// 三个入口（attachObserver / attachElementObserver / checkNow）全部先过这里，别在别处复制判定。
    static func excludedGate(pid: pid_t) -> Bool {
        EnginePrefs.isExcluded(bundleId: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                               appName: appName(pid))
    }

    private func attachObserver(pid: pid_t) {
        guard pid > 0, AXPermission.granted() else { return }
        if Self.excludedGate(pid: pid) {
            detachObserver()
            emit(CheckEvent(kind: "skip-excluded-attach", pid: pid, app: appName(pid), role: "-", textLen: 0,
                            sentenceLen: 0, itemCount: 0, rectCount: 0, elapsed: "-",
                            err: "App 在排除列表里：不挂 observer", at: Date()))
            return
        }
        detachObserver()
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, element, notif, refcon in
            guard let refcon else { return }
            let name = notif as String
            let ctrl = Unmanaged<InlineController>.fromOpaque(refcon).takeUnretainedValue()
            Task { @MainActor in
                ctrl.onAXNotification(name: name, element: element)
            }
        }
        guard AXObserverCreate(pid, cb, &obs) == .success, let observer = obs else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let appNotifs = [kAXFocusedUIElementChangedNotification]
        for n in appNotifs {
            AXObserverAddNotification(observer, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = observer
        observedPid = pid
        // 门控放在 emit 之前：锁屏 / 登录窗连事件都不发（否则夜里照样写 attach-app loginwindow）
        guard ScreenLock.shouldAttach(locked: ScreenLock.isLocked, appName: appName(pid)) else { return }
        emit(CheckEvent(kind: "attach-app", pid: pid, app: appName(pid), role: "-", textLen: 0, sentenceLen: 0,
                        itemCount: 0, rectCount: 0, elapsed: "-", err: "-", at: Date()))
        attachElementObserver(pid: pid)
    }

    private func attachElementObserver(pid: pid_t) {
        guard let observer else { return }
        // 锁屏 / 登录窗：不挂观察者，免得夜里全是 loginwindow 的假 attach
        if ScreenLock.isLocked { return }
        if appName(pid) == "loginwindow" { return }
        if Self.excludedGate(pid: pid) { return }        // 排除的 App 不挂元素观察者
        // Chromium 懒开无障碍（真机 2026-11-19 Chrome 实测）：不置这两个属性，AX 树里永远没有 AXWebArea
        _ = AXInline.enableWebAX(pid)

        // 焦点可能落在窗口/工具栏（AXWindow）上而不是文本区：那样 valueChanged 永远不会来。
        // 真机实测（TextEdit）：刚激活时 focusedElement 就是 AXWindow → 必须改挂窗口里最大的可读 AXTextArea。
        var cand = AXInline.focusedElement(pid: pid)
        var role = cand.map { attrString($0, kAXRoleAttribute as String) ?? "" } ?? ""
        let textRole = (role == "AXTextArea" || role == "AXTextField" || role == "AXWebArea")
        let readable = cand.map { AXInline.fullText(of: $0) != nil || WebText.isWebBody($0) } ?? false
        if cand == nil || !textRole || !readable {
            // 顺序很关键（知澜 11-19 抓到的反例）：
            //   ① 先找 key window 里的**可编辑**元素（原生 App 的正路，确定性，不猜）
            //   ② 再考虑前台窗口正文（只对 Web 宿主有意义：Mail 写信 / WebArea 外层 AXValue 恒空）
            // 反过来的话，TextEdit 的窗口正文是 AXImage，cand 被只读正文占住，
            // keyWindowEditable 的 `cand == nil` 永远不成立 → 又落到 skip-readonly。
            if let kw = AXInline.keyWindowEditable(pid: pid),
               let v = AXInline.fullText(of: kw), !v.isEmpty {
                cand = kw
                role = attrString(kw, kAXRoleAttribute as String) ?? ""
                emit(CheckEvent(kind: "attach-keywindow", pid: pid, app: appName(pid), role: role,
                                textLen: (v as NSString).length, sentenceLen: 0, itemCount: 0,
                                rectCount: 0, elapsed: "-", err: "焦点不可读 → key window 可编辑元素", at: Date()))
            } else if let wb = AXInline.frontWindowBody(pid: pid), WebText.isWebBody(wb) {
                // 网页输入控件优先（textarea 在 AX 树里是 AXTextArea，AXValue 有字）
                cand = AXInline.textField(in: wb) ?? wb
                role = attrString(cand!, kAXRoleAttribute as String) ?? ""
                emit(CheckEvent(kind: "attach-web", pid: pid, app: appName(pid), role: role,
                                textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                                elapsed: "-", err: "焦点不可读 → 改挂前台窗口正文", at: Date()))
            }
        }
        guard let el = cand else {
            emit(CheckEvent(kind: "attach-el-fail", pid: pid, app: appName(pid), role: "-", textLen: 0,
                            sentenceLen: 0, itemCount: 0, rectCount: 0, elapsed: "-", err: "没有焦点元素", at: Date()))
            // 注意：这里**绝不 clear()**。读不到焦点只说明「这一轮没读到」（窗口非 key、overlay 抢了 key、
            // AX 暂时沉默都会这样），不代表宿主换了。线该由「前台 App 变没变」和 TTL 决定，不由能不能读到焦点决定。
            // Chromium 的 AX 树是异步长出来的：1.5s 后再试（最多 3 次），别一次取样就判死
            if AXInline.isChromium(pid) {
                let n = (attachRetries[pid] ?? 0) + 1
                attachRetries[pid] = n
                if n <= 3 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        Task { @MainActor in self?.attachElementObserver(pid: pid) }
                    }
                }
            }
            return
        }
        attachRetries[pid] = 0
        if let old = observedElement, CFEqual(old, el) { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, el, n as CFString, refcon)
        }
        observedElement = el
        emit(CheckEvent(kind: "attach-el", pid: pid, app: appName(pid),
                        role: attrString(el, kAXRoleAttribute as String) ?? "?", textLen: 0, sentenceLen: 0,
                        itemCount: 0, rectCount: 0, elapsed: "-", err: "-", at: Date()))
    }

    private func detachObserver() {
        if let observer {
            if let el = observedElement {
                AXObserverRemoveNotification(observer, el, kAXValueChangedNotification as CFString)
                AXObserverRemoveNotification(observer, el, kAXSelectedTextChangedNotification as CFString)
            }
            let app = AXUIElementCreateApplication(observedPid)
            AXObserverRemoveNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedElement = nil
        observedPid = 0
    }

    private func onAXNotification(name: String, element: AXUIElement) {
        guard enabled else { return }
        if name == kAXFocusedUIElementChangedNotification as String {
            // 点击引起的光标/焦点变化不算数：它会把刚画好的线清掉，导致点击必 miss
            if HoverCoordinator.shouldIgnoreFocusChange(now: Date(), lastClickAt: HoverCoordinator.shared.lastClickAt) {
                return
            }
            if let pid = lastFocusPid as pid_t? { attachElementObserver(pid: pid) }
            scheduleCheck(delay: debounce)
            return
        }
        scheduleCheck(delay: debounce)
    }

    // MARK: 去抖检查

    private func scheduleCheck(delay: TimeInterval) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.checkNow() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func checkNow() { checkNow(for: lastFocusPid, element: nil) }

    /// 指定 pid / 元素检查（真机验收器与悬停卡片都走这条：不信焦点判定，直接给元素）
    func checkNow(for pid: pid_t, element explicit: AXUIElement? = nil) {
        guard enabled else { return }
        guard AXPermission.granted() else { diag.lastError = "无辅助功能权限"; return }
        guard pid > 0 else { return }
        // App 排除：命中的 App 一个请求都不发（只记一条 skip，便于事后核「确实没查」）
        if Self.excludedGate(pid: pid) {
            emit(CheckEvent(kind: "skip-excluded", pid: pid, app: appName(pid), role: "",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "-", at: Date()))
            return
        }
        _ = AXInline.enableWebAX(pid)
        // 选元素顺序（与 attachObserver 保持一致，知澜 11-19 抓到的反例）：
        //   ① 显式传入 / 焦点元素且**可读**
        //   ② key window 里的可编辑元素（原生 App 的正路，确定性，不猜）
        //   ③ 前台窗口正文（只对 Web 宿主有意义：Mail 邮件正文 / 网页，AXValue 恒空）
        // 顺序反了的话，窗口正文会先把 cand 占住（TextEdit 的窗口正文是 AXImage），
        // keyWindowEditable 永远轮不到 → 只能记 skip-readonly，Mail/TextEdit 就再也没线。
        let focusedEl = explicit ?? AXInline.focusedElement(pid: pid)
        let focusedReadable = focusedEl.map { AXInline.fullText(of: $0) != nil || WebText.isWebBody($0) } ?? false
        let keyEl = AXInline.keyWindowEditable(pid: pid)
        let keyReadable = keyEl.map { AXInline.fullText(of: $0) != nil || WebText.isWebBody($0) } ?? false
        let wbEl = AXInline.frontWindowBody(pid: pid)
        // 顺序由 ElementPick 决定（纯函数，--ui 里有 4 条断言钉住）
        let pick = ElementPick.choose(focusedReadable: focusedReadable,
                                      keyEditableReadable: keyReadable,
                                      windowBodyExists: wbEl != nil)
        var el: AXUIElement
        var picked = ""
        switch pick {
        case .focused:
            el = focusedEl!; picked = "focused"
        case .keywindowEditable:
            el = keyEl!; picked = "keywindow-editable"; diag.lastPath = "keywindow-editable"
        case .windowBody:
            el = wbEl!; picked = WebText.isWebBody(el) ? "web-body" : "window-body"
            diag.fallbackTextArea += 1
        case .none:
            diag.lastError = "没有焦点文本框"
            emit(CheckEvent(kind: "no-element", pid: pid, app: appName(pid), role: "-",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "焦点不可读 / 无 key 可编辑元素 / 无窗口正文", at: Date()))
            return
        }
        // 选路证据：哪一级接上的，一眼可见（爹地问「Mail 为什么不画线」时直接看这行）
        emit(CheckEvent(kind: picked == "focused" ? "attach-el" : "fallback-el",
                        pid: pid, app: appName(pid),
                        role: attrString(el, kAXRoleAttribute as String) ?? "?",
                        textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                        elapsed: "-", err: picked, at: Date()))
        // P0 硬门槛：只读文本一个字都不读、一条线都不画。
        // 唯一例外：Mail 的邮件正文（宿主是 Mail 且元素是 AXWebArea）。
        // 浏览器宿主已在上游 skip-browser；这里管的是其它 App 的只读正文（PDF / 预览 / 面板说明）。
        let isMailBody = WebText.isWebBody(el) && appName(pid) == "Mail"
        let hasEditableWebField = WebText.isWebBody(el) && AXInline.textField(in: el) != nil
        if !InlineGate.shouldCheck(editable: AXInline.isEditable(el),
                                   isWebBody: WebText.isWebBody(el),
                                   isMailBody: isMailBody,
                                   hasEditableWebField: hasEditableWebField,
                                   checkReading: EnginePrefs.checkReading) {
            // 证据必须能自证：是不是真的有可编辑控件被误判成只读？
            let elRole = attrString(el, kAXRoleAttribute as String) ?? "?"
            let kind = AXInline.isEditable(el) ? "editable-but-unreadable" : "readonly"
            emit(CheckEvent(kind: "skip-readonly", pid: pid, app: appName(pid), role: elRole,
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: kind, at: Date()))
            overlay.clear(); items = []; blocks = []; itemBlock = []
            diag.lastError = "只读文本，跳过"
            return
        }
        var full = AXInline.fullText(of: el)
        // WebKit 正文（Mail 写信 / 网页）：焦点元素是 WebArea 外层、AXValue 恒空 →
        // 必须在 no-text 判定之前接前台窗口正文，否则「读不到文本框内容」，一个字都不查。
        if !WebText.isWebBody(el), full == nil || (full?.isEmpty ?? true),
           let wb = AXInline.frontWindowBody(pid: pid),
           WebText.isWebBody(wb), !WebText.blocks(of: wb).isEmpty {
            el = wb
            full = ""
            diag.fallbackTextArea += 1
            emit(CheckEvent(kind: "fallback-web", pid: pid, app: appName(pid), role: "AXWebArea",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "焦点不可读 → 接前台窗口正文", at: Date()))
        }
        // 网页里的输入控件（textarea/input）：WebArea 下挂着 AXTextArea 就先换成它，
        // 走原生 AXValue 通道。整页静态文本（标题/提示语）当正文 = 查错地方（Chrome 真机实测）。
        if WebText.isWebBody(el), let tf = AXInline.textField(in: el),
           let v = AXInline.fullText(of: tf), !v.isEmpty {
            el = tf
            full = v
            diag.fallbackTextArea += 1
        }
        // WebKit 正文（Mail / Slack / 网页）：AXValue 通常读不到（实测 Mail 写信窗口 len=0），
        // 必须在「full 为空」判定之前先走文本块通道，否则永远停在 no-text、一个字都不检查。
        if WebText.isWebBody(el) {
            currentElement = el
            currentPid = pid
            checkWeb(pid: pid, body: el)
            return
        }

        if full == nil {
            emit(CheckEvent(kind: "no-text", pid: pid, app: appName(pid), role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0, elapsed: "-",
                            err: "读不到文本框内容", at: Date()))
            // 读不到字 = 不知道，不许打成绿点（三态球）
            diag.lastTextLen = 0
            diag.lastPath = "none"
            floatUnknown(pid: pid, element: el)
        }
        guard let full else { diag.lastError = "读不到文本框内容"; return }
        // ① 逐 App 适配：没有配置或配置为关 → 不工作（不再靠「通用探测」猜）
        let app = appName(pid)
        if let cfg = Integrations.integration(bundleId: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "", appName: app) {
            _ = cfg
        } else if Integrations.all.contains(where: { $0.id == app && !$0.isEnabled }) {
            emit(CheckEvent(kind: "skip-app-disabled", pid: pid, app: app,
                            role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "该 App 适配未探明，已关闭", at: Date()))
            return
        }

        // ② 隐私硬规矩：敏感字段（密码/账号/地址/卡号/id…）一律不激活
        var idParts: [String] = []
        for attrName in [kAXIdentifierAttribute, kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let v = attrString(el, attrName as String) { idParts.append(v) }
        }
        if Integrations.isSensitive(text: idParts.joined(separator: " ")) {
            emit(CheckEvent(kind: "skip-sensitive", pid: pid, app: app,
                            role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "敏感字段（命中关键词黑名单）", at: Date()))
            return
        }

        currentElement = el
        currentPid = pid

        // WebKit 正文（Mail / Slack / 网页）：按文本块检查，偏移在块内
        if WebText.isWebBody(el) {
            checkWeb(pid: pid, body: el)
            return
        }

        let caret = AXInline.selectedRange(el)?.location ?? (full as NSString).length
        let sentenceRange = Sentence.around(caret: caret, in: full)
        currentSentenceRange = sentenceRange
        let sentence = Sentence.text(sentenceRange, in: full)
        guard sentence.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 else {
            overlay.clear(); items = []; return
        }
        // 先把这次看到的文本记下：否则轮询每秒都认为「文本变了」，日志 1 秒刷一条（踩过）
        lastText = full
        diag.lastTextLen = (full as NSString).length
        diag.lastPath = "value"
        // 语言门控：中文占比超阈值 → 一个请求都不发
        if !LanguageGate.isEnglish(sentence) {
            diag.skippedChinese += 1
            emit(CheckEvent(kind: "skip-lang", pid: pid, app: appName(pid), role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: (full as NSString).length, sentenceLen: (sentence as NSString).length,
                            itemCount: 0, rectCount: 0, elapsed: "-", err: "-", at: Date()))
            floatUnknown(pid: pid, element: el)
            overlay.clear(); items = []
            return
        }
        // 同文本不重复请求
        let hash = "\(pid):\(sentence.hashValue)"
        if lastHash[pid] == hash { diag.dedupedHits += 1; return }
        lastHash[pid] = hash

        diag.checks += 1
        lastText = full
        // 立即出「零进程」结果：系统词典拼写 + 本地 clarity/style 规则（毫秒级、不依赖 LT 是否在跑）
        // 即时层要和浏览器同口径：拼写 + 本地语法规则 + 清晰度/风格（之前漏了 LocalGrammar）
        let instant = DiffSanitize.consolidate(SpellCheck.items(in: sentence) + LocalGrammar.apply(to: sentence)
                                               + StyleRules.apply(to: sentence), in: sentence)
        if !instant.isEmpty {
            apply(items: shift(instant, by: sentenceRange.location), sentenceRange: sentenceRange, element: el, pid: pid)
        }
        emit(CheckEvent(kind: "check", pid: pid, app: appName(pid), role: attrString(el, kAXRoleAttribute as String) ?? "",
                        textLen: (full as NSString).length, sentenceLen: (sentence as NSString).length,
                        itemCount: 0, rectCount: 0, elapsed: "-", err: "-", at: Date()))

        let cfg = SettingsStore.load()

        // 引擎选择：本地 LanguageTool 在线就优先用它（毫秒级、零成本、不出网）；
        // 不可用且用户填了模型三件套 → 走 OpenAI 兼容逐条 diff；两者都没有 → Mock（自测路径）
        Task { [weak self] in
            // 路由：LT 开关（默认关，省 368MB）优先，其次模型接口，都没有就只出拼写/清晰度/风格
            let ltOn = EnginePrefs.ltEnabled()
            var ltOK = ltOn ? await LocalEngine.available() : false
            if ltOn && !ltOK {
                // 探活缓存 60s：可能刚拉起未就绪就被判死 → 节流拉一次 + 强制复探
                LocalEngineBootstrap.ensureRunningThrottled()
                ltOK = await LocalEngine.available(force: true)
            }
            let choice = EngineRouter.choose(ltEnabled: ltOn, ltAvailable: ltOK, modelConfigured: cfg.isComplete)
            await MainActor.run { self?.diag.engineChoice = EngineRouter.describe(choice) }
            if choice == .localLanguageTool {
                do {
                    let out = try await LocalEngine.review(text: sentence, language: EnginePrefs.language())
                    await MainActor.run {
                        guard let self else { return }
                        self.diag.lastElapsed = String(format: "%.0fms", out.elapsed * 1000)
                        self.diag.lastError = "-"
                        self.apply(items: self.shift(out.items, by: sentenceRange.location),
                                   sentenceRange: sentenceRange, element: el, pid: pid)
                    }
                    return
                } catch {
                    await MainActor.run { self?.diag.lastError = "LT: \(error)" }
                }
            }
            guard cfg.isComplete else {
                await MainActor.run { self?.diag.lastError = "只启用本地：拼写/清晰度/风格（语法需打开 LT 或填模型接口）" }
                if ProcessInfo.processInfo.environment["EW_MOCK_ENGINE"] == "1" {
                    await MainActor.run {
                        self?.apply(items: MockDiff.items(for: full), sentenceRange: sentenceRange, element: el, pid: pid)
                    }
                } else {
                    await MainActor.run { self?.diag.lastError = "本地引擎未启动，且还没配置模型接口" }
                }
                return
            }
            await MainActor.run { self?.diag.requests += 1 }
            do {
                // 短碎片不发模型：单词（无空格）或 <15 字符的片段，模型没有上下文只能猜
                // 实测：「maked」单独发出去，模型硬凑了一条 my→my 的占位修改
                let noSpace = !sentence.contains(" ")
                if noSpace || (sentence as NSString).length < 15 { return }
                let out = try await InlineEngine.review(text: sentence, config: cfg)
                let mergedModel = DiffSanitize.consolidate(SpanGuard.filterModelItems(out.items, in: sentence) + instant, in: sentence)
                await MainActor.run {
                    guard let self else { return }
                    self.diag.lastElapsed = String(format: "%.2fs", out.elapsed)
                    self.diag.lastError = "-"
                    self.apply(items: self.shift(mergedModel, by: sentenceRange.location),
                               sentenceRange: sentenceRange, element: el, pid: pid)
                }
            } catch let f as ReviewFailure {
                await MainActor.run { self?.diag.lastError = f.userMessage }
            } catch {
                await MainActor.run { self?.diag.lastError = "\(error)" }
            }
        }
    }

    /// 句子内偏移 → 全文偏移
    private func shift(_ items: [DiffItem], by offset: Int) -> [DiffItem] {
        items.map { it in
            var c = it
            c.start += offset
            return c
        }
    }

    // MARK: WebKit 正文（按文本块）

    /// 浏览器宿主：线由浏览器扩展自己画（DOM Range 精度比 AX 高一个数量级），
    /// App 主动退让，绝不两套同时在一个宿主上画线（11-19 定的架构）。
    private static let browserBundleIDs: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.google.Chrome.beta",
        "org.chromium.Chromium",
        // Safari 不在名单里：我们还没有 Safari 扩展（Safari 只认 .appex，Chrome 的 MV3 装不进去）。
        // 爹地日常用 Safari 最多，所以这条路由 App 自己画；有 Safari 扩展之后再移交。
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "org.mozilla.firefox",
    ]

    private func isBrowserHost(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid),
              let bid = app.bundleIdentifier else { return false }
        return Self.browserBundleIDs.contains(bid)
    }

    private func checkWeb(pid: pid_t, body: AXUIElement) {
        if isBrowserHost(pid: pid) {
            emit(CheckEvent(kind: "skip-browser", pid: pid, app: appName(pid), role: "AXWebArea",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "浏览器宿主：线归扩展，App 不画", at: Date()))
            overlay.clear(); items = []; blocks = []; itemBlock = []
            return
        }
        // 闸门：上一次块检查还没跑完 → 只记一笔并把「跑完再补一次」标记上。
        // 没有这道闸，1s 轮询会让几十秒的检查无限叠加（11-23 实测：370% CPU、单请求 15.8s）。
        if webCheckRunning {
            webCheckDirty = true
            emit(CheckEvent(kind: "skip-busy", pid: pid, app: appName(pid), role: "AXWebArea",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "上一轮块检查未结束，本轮合并", at: Date()))
            return
        }
        // 只查看得见的块：AXWebArea 代表整个文档，全量读出来能到 1477 块，
        // 一块一个 /v2/check 等于自己 DDoS 自己的引擎。
        let visible = WebText.visibleBlocks(of: body, inWindow: WebText.windowFrame(of: body))
        let blks = Array(visible.prefix(webMaxBlocks))
        guard !blks.isEmpty else {
            diag.lastError = "Web 正文里没有可读文本块"
            overlay.clear(); items = []; blocks = []; itemBlock = []
            return
        }
        if visible.count > blks.count {
            emit(CheckEvent(kind: "truncated-blocks", pid: pid, app: appName(pid), role: "AXWebArea",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "可见块 \(visible.count) > 上限 \(webMaxBlocks)，本轮只查 \(blks.count) 块", at: Date()))
        }
        blocks = blks
        webCheckRunning = true
        lastText = blks.map(\.text).joined(separator: "\n")
        diag.lastTextLen = (lastText as NSString).length
        diag.lastPath = "statictext(块\(blks.count))"
        diag.checks += 1

        let sigMarkers = SpanGuard.signatureMarkers
        Task { [weak self] in
            guard let self else { return }
            // 无论走哪条出口都必须放闸，否则一次异常就永久不再检查
            defer { Task { @MainActor in self.finishWebCheck() } }
            let ltOK = await LocalEngine.available()
            if !ltOK { LocalEngineBootstrap.ensureRunningThrottled() }   // 闲置退出后按需拉回（节流 120s）
            var all: [DiffItem] = []
            var map: [Int] = []
            var cjkSkipped = 0
            var firstError: String?
            var seenWords = Set<String>()
        let maxItems = 20
        var ltMs: Double = 0
        // 整篇一次请求：块之间用 "\n\n" 拼接，记下每块起始偏移，回来再按偏移映射。
        // 一块一个请求是 11-23 java 爆炸的直接原因（1477 块 → JVM 饱和、单请求 32s）。
        var texts: [String] = []
        var idxs: [Int] = []
        let joinLimit = 8000
        for (bi, b) in blks.enumerated() {
            let t = b.text
            let blen = (t as NSString).length
            if blen < 12 || !t.contains(" ") { continue }
            guard t.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { continue }
            if !LanguageGate.isEnglish(t) { cjkSkipped += 1; continue }
            let lowered = t.lowercased()
            if sigMarkers.contains(where: { lowered.hasPrefix($0.lowercased()) }) { continue }
            texts.append(t); idxs.append(bi)
        }
        let batch = BlockBatch.join(texts, blockIndexes: idxs, charLimit: joinLimit)
        if batch.isEmpty {
            // 全是中文 / 噪声块：一个请求都不发
        } else if !ltOK {
            firstError = "本地引擎未启动"
        } else {
            do {
                let t0 = Date()
                let out = try await LocalEngine.review(text: batch.text, language: EnginePrefs.language())
                ltMs += Date().timeIntervalSince(t0) * 1000
                await MainActor.run { self.diag.lastElapsed = String(format: "%.0fms", ltMs) }
                for (it, bi) in BlockBatch.map(out.items, in: batch) {
                    all.append(it)
                    map.append(bi)
                }
            } catch {
                firstError = "LT: \(error)"
            }
        }
            await MainActor.run {
                if let e = firstError { self.diag.lastError = e } else { self.diag.lastError = "-" }
                // 语言门控留痕：块全是中文 → 一个引擎请求都没发
                if all.isEmpty, cjkSkipped > 0, firstError == nil {
                    self.diag.skippedChinese += 1
                    self.emit(CheckEvent(kind: "skip-lang", pid: pid, app: appName(pid), role: "web",
                                         textLen: (self.lastText as NSString).length, sentenceLen: 0,
                                         itemCount: 0, rectCount: 0, elapsed: "-",
                                         err: "中文块 \(cjkSkipped) · 0 请求", at: Date()))
                }
                self.applyWeb(items: all, blockMap: map, blocks: blks, pid: pid)
            }
        }
    }

    /// 放开 web 检查闸。用 defer 调到它：任何出口（含抛异常/提前 return）都必须放闸，
    /// 否则一次异常就永久不再检查（另一个会话留下的半成品，这里补齐定义）。
    @MainActor
    private func finishWebCheck() {
        webCheckRunning = false
        // 检查期间被闸掉的轮询合并成一次补跑：既不让 1s 轮询叠加，也不丢最后一次改动
        if webCheckDirty {
            webCheckDirty = false
            scheduleQuickCheck(after: 0.4)
        }
    }

    private func applyWeb(items newItems: [DiffItem], blockMap: [Int], blocks blks: [WebText.Block], pid: pid_t) {
        var kept: [DiffItem] = []
        var keptMap: [Int] = []
        var specs: [UnderlineSpec] = []
        let maxItems = 20
        // 先按「偏移必须对得上原文」筛，再做同词去重 + 上限（规则与离屏验收共用）
        var cands: [(DiffItem, Int)] = []
        for (i, it) in newItems.enumerated() where i < blockMap.count {
            let bi = blockMap[i]
            guard bi < blks.count else { continue }
            let ns = blks[bi].text as NSString
            guard it.length > 0, it.start >= 0, it.start + it.length <= ns.length else { continue }
            guard ns.substring(with: it.utf16Range) == it.original else { continue }   // 偏移对不上一律不画
            cands.append((it, bi))
        }
        for (it, bi) in WebText.ItemFilter.dedupeAndCap(cands, item: { $0.0 }, max: maxItems) {
            let b = blks[bi]
            if IgnoreStore.shared.isIgnored(original: it.original, replacement: it.replacement) { continue }
            let rects = WebText.lineRects(for: it.utf16Range, in: b)
            guard !rects.isEmpty else { continue }
            let id = kept.count
            kept.append(it)
            keptMap.append(bi)
            for r in rects { specs.append(UnderlineSpec(rect: r, kind: it.kind, itemID: id, ownerPid: pid)) }
        }
        items = kept
        itemBlock = keptMap
        if newItems.count > kept.count {
            emit(CheckEvent(kind: "truncated", pid: pid, app: appName(pid),
                            role: "web", textLen: 0, sentenceLen: 0,
                            itemCount: kept.count, rectCount: specs.count,
                            elapsed: "-", err: "原始 \(newItems.count) 条 → 保留 \(kept.count)", at: Date()))
        }
        diag.lastRectCount = specs.count
        // 绘制留痕：items/rects/耗时都要能事后核（卡片验收靠这一行）
        emit(CheckEvent(kind: specs.isEmpty ? "render-none" : "render", pid: pid, app: appName(pid), role: "web",
                        textLen: (lastText as NSString).length, sentenceLen: 0,
                        itemCount: kept.count, rectCount: specs.count,
                        elapsed: diag.lastElapsed, err: diag.lastError, at: Date()))
        guard !specs.isEmpty else {
            overlay.clear()
            return
        }
        overlay.render(specs)
        overlayPid = pid
        printRects(specs, items: kept)
    }

    // MARK: 卡片的动作（接受 / 忽略 / 加词典 / 撤销）

    struct SentenceSlice { var text: String; var errorRange: NSRange }

    /// 某条错误所在的那句话 + 错处在句内的位置（卡片高亮用）
    func sentenceText(forItem id: Int) -> SentenceSlice {
        guard id >= 0, id < items.count else {
            return SentenceSlice(text: "", errorRange: NSRange(location: 0, length: 0))
        }
        let it = items[id]
        let bi = itemBlock.indices.contains(id) ? itemBlock[id] : -1
        let source = (bi >= 0 && bi < blocks.count) ? blocks[bi].text : lastText
        guard !source.isEmpty else { return SentenceSlice(text: it.original, errorRange: NSRange(location: 0, length: it.length)) }
        let r = Sentence.around(caret: it.start, in: source)
        let local = NSRange(location: max(0, it.start - r.location), length: it.length)
        return SentenceSlice(text: (source as NSString).substring(with: r), errorRange: local)
    }

    private var lastAccept: (item: DiffItem, blockIndex: Int, element: AXUIElement?)?   // 已由 M3UndoStack 取代，保留字段供老断言编译

    /// 卡片「接受」：按条走 applyEdits(only:)，只替换这一条的 range，不动同段其它建议；
    /// 接受前把「原文快照 + pid + range」压进内存撤销栈（菜单「撤销上次替换」出栈回写）。
    @discardableResult
    func accept(itemID id: Int) -> Bool {
        guard id >= 0, id < items.count else { return false }
        let it = items[id]
        let doc = docFor(itemID: id)
        let out = M3Flow.accept(items: items, only: id, in: doc, stack: M3UndoStack.shared)
        diag.lastError = out.ok ? "已接受：\(it.original) → \(it.replacement)" : "写回失败：\(out.detail)"
        AppLog.info("m3", "accept id=\(id) pid=\(currentPid) range=\(it.start)+\(it.length) ok=\(out.ok) stack=\(M3UndoStack.shared.count) detail=\"\(out.detail)\"")
        refresh()
        return out.ok
    }

    /// 卡片动作的文档视图：Web 正文按块、原生输入框按 AX 元素；两边的写回都在这里收口。
    /// 撤销栈里存的就是这个句柄——撤销时写回同一处，不猜当前焦点在哪。
    private func docFor(itemID id: Int) -> M3Doc {
        let bi = itemBlock.indices.contains(id) ? itemBlock[id] : -1
        if bi >= 0, bi < blocks.count {
            let block = blocks[bi]
            return ClosureDoc(pid: currentPid,
                              read: { block.text },
                              writeRange: { r, t in WebText.replace(range: r, with: t, in: block) },
                              writeFull: { t in
                                  WebText.replace(range: NSRange(location: 0, length: (block.text as NSString).length),
                                                   with: t, in: block)
                              })
        }
        if let el = currentElement {
            let pid = currentPid
            let readable = !(AXInline.fullText(of: el) ?? "").isEmpty
            return ClosureDoc(pid: pid, canReadBack: readable,
                              read: { AXInline.fullText(of: el) ?? self.lastText },
                              writeRange: { [weak self] r, t in
                                  self?.layeredWrite(range: r, text: t, to: el, pid: pid) ?? false
                              },
                              writeFull: { [weak self] t in
                                  self?.writeWhole(t, to: el, pid: pid) ?? false
                              })
        }
        return BufferDoc(lastText, pid: currentPid)
    }

    /// 写回四层降级（原位替换）：AX text operation → 选区 + AXSelectedText → 剪贴板 ⌘V（用完恢复剪贴板）
    private func layeredWrite(range: NSRange, text: String, to el: AXUIElement, pid: pid_t) -> Bool {
        guard let v = axRangeValue(range.location, range.length) else { return false }
        _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        Audit.write("Inline.accept")
        if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            Diag.shared.applyMethod = "AX 写回"
            return true
        }
        // Chromium 网页字段：AXValue / AXSelectedText 实测都写不进（2026-11-16 探测）→ 剪贴板兜底
        _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        if pasteViaClipboard(text, to: pid) {
            usleep(450_000)
            if (attrString(el, kAXValueAttribute as String) ?? "").contains(text) {
                Diag.shared.applyMethod = "剪贴板 ⌘V 兜底"
                return true
            }
        }
        return false
    }

    /// 整段回写（撤销兜底）：kAXValue 直写 → 剪贴板 ⌘V
    private func writeWhole(_ text: String, to el: AXUIElement, pid: pid_t) -> Bool {
        Audit.write("Inline.writeWhole")
        if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFTypeRef) == .success {
            let now = AXInline.fullText(of: el) ?? ""
            return now.isEmpty || now == text
        }
        if pasteViaClipboard(text, to: pid) {
            usleep(450_000)
            let now = AXInline.fullText(of: el) ?? ""
            return now.isEmpty || now == text
        }
        return false
    }

    /// 撤销上一条接受：出栈，用接受前的原文快照回写（pid / range / 快照都取自那一帧）
    @discardableResult
    func undoLastAccept() -> Bool {
        guard let top = M3UndoStack.shared.top else {
            diag.lastError = "没有可撤销的替换（本次运行还没接受过建议）"
            return false
        }
        let r = M3Flow.undo(stack: M3UndoStack.shared)
        if r.ok {
            Diag.shared.undoCount += 1
            diag.lastError = r.detail
        } else {
            diag.lastError = r.detail
        }
        AppLog.info("m3", "undo pid=\(top.pid) range=\(top.range.location)+\(top.range.length) ok=\(r.ok) detail=\"\(r.detail)\"")
        refresh()
        return r.ok
    }

    /// 忽略（本次）：本次运行内不再提示，不落盘 —— 用户「这一版稿子不想看」用它
    func ignoreSession(itemID id: Int) {
        guard id >= 0, id < items.count else { return }
        let it = items[id]
        IgnoreStore.shared.ignoreSession(original: it.original, replacement: it.replacement)
        diag.lastError = "本次忽略：\(it.original) → \(it.replacement)（重启后恢复）"
        dropItem(start: it.start, length: it.length)
    }

    /// 忽略（永久）：同一对「原词→建议」以后都不再提示，落盘跨重启有效
    func ignorePermanent(itemID id: Int) {
        guard id >= 0, id < items.count else { return }
        let it = items[id]
        IgnoreStore.shared.ignore(original: it.original, replacement: it.replacement)
        diag.lastError = "已永久忽略：\(it.original) → \(it.replacement)"
        dropItem(start: it.start, length: it.length)
    }

    /// 加入个人词典：这个词以后一律不报
    func addToDictionary(itemID id: Int) {
        guard id >= 0, id < items.count else { return }
        let it = items[id]
        DictStore.add(it.original)
        diag.lastError = "已加入词典：\(it.original)"
        refresh()
    }

    /// 写回兜底：剪贴板 ⌘V。Chromium 网页字段实测 AXValue / AXSelectedText 都写不进，
    /// 只有合成键击能进去。用完 0.6s 把爹地的剪贴板原样还原，长期占用为零。
    private func pasteViaClipboard(_ text: String, to pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        Audit.pasteboard()
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else {
            if let s = saved { pb.clearContents(); pb.setString(s, forType: .string) }
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            if let s = saved { pb.clearContents(); pb.setString(s, forType: .string) }
        }
        return true
    }

    /// 重新检查刷新（LT 热态 20ms，比本地改状态更可靠）
    private func refresh() {
        guard let el = currentElement, currentPid > 0 else { return }
        checkNow(for: currentPid, element: el)
    }

    // MARK: 渲染

    private func apply(items newItems: [DiffItem], sentenceRange: NSRange, element el: AXUIElement, pid: pid_t) {
        defer {
            emit(CheckEvent(kind: "render", pid: pid, app: appName(pid), role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: (lastText as NSString).length, sentenceLen: sentenceRange.length,
                            itemCount: items.count, rectCount: overlay.specs.count,
                            elapsed: diag.lastElapsed, err: diag.lastError, at: Date()))
        }
        let cleaned = DiffSanitize.clean(newItems, in: lastText)
            .filter { !IgnoreStore.shared.isIgnored(original: $0.original, replacement: $0.replacement) }
        guard !cleaned.isEmpty else {
            overlay.clear(); items = []
            diag.lastRectCount = 0
            // 检查过、0 命中 → 绿点。原来这里直接 return，球会留着上一轮的旧数字（假的）
            updateFloatBall(items: [], specs: [], element: el, pid: pid)
            syncSidebarIfOpen()
            return
        }
        var specs: [UnderlineSpec] = []
        // AXBoundsForRange 给不出矩形时（自家窗口 / 非 key 窗口实测会这样），
        // 退回元素自身 frame —— 有矩形可画，好过「有建议、零条线」
        let elFrame = elementRectQuartz(el)
        for (idx, it) in cleaned.enumerated() {
            var rects = AXInline.lineRects(for: it.utf16Range, in: el)
            if rects.isEmpty, elFrame.width > 0, elFrame.height > 0 { rects = [elFrame] }
            for r in rects {
                specs.append(UnderlineSpec(rect: r, kind: it.kind, itemID: idx, ownerPid: pid))
            }
        }
        items = cleaned
        itemBlock = Array(repeating: -1, count: cleaned.count)
        diag.lastRectCount = specs.count
        guard !specs.isEmpty else { diag.lastError = "算不出屏幕矩形"; return }
        overlay.render(specs)
        overlayPid = pid
        printRects(specs, items: cleaned)
        syncSidebarIfOpen()
    }

    func clearUnderlines() {
        HoverCoordinator.shared.dismissCard()
        overlay.clear()
        items = []
        FloatBall.shared.hide()
    }

    /// 浮动球：三态（unknown 读不到文本 / clear 检查过没问题 / issues N 条）
    private func updateFloatBall(items: [DiffItem], specs: [UnderlineSpec], element el: AXUIElement, pid: pid_t) {
        guard !UnderlineOverlay.globallySilent else { return }   // 被动模式一个像素都不上
        // anchor 必须是「当前聚焦的那个文本框」，不是 513 块拼出来的并集
        // （并集每次检查都在变，球就满屏乱跳 —— 爹地原话）
        guard let anchor = ballAnchor(pid: pid, fallback: el) else {
            // 真的一个锚点都没有（换 App / 窗口关了）：只有这时才允许消失
            let front = ScreenGeom.frontmostWindowPID(excluding: ProcessInfo.processInfo.processIdentifier)
            if front != pid { lastBallAnchor[pid] = nil }
            logBall("hide", reason: "noanchor", pid: pid, rect: nil)
            FloatBall.shared.hide()
            return
        }
        let box = anchor.rect
        logBall("show", reason: anchor.source, pid: pid, rect: box)
        let worst = items.map { CategoryPrefsSeverity($0.kind) }.max() ?? 0
        let sev: UnderlineKind = items.first(where: { CategoryPrefsSeverity($0.kind) == worst })?.kind ?? .grammar
        let phase = FloatBall.phase(textLen: (lastText as NSString).length, itemCount: items.count)
        FloatBall.shared.update(.init(phase: phase, count: items.count, severity: sev, pid: pid, anchor: box))
    }

    /// 读不到文本 / 中文跳过 / 该 App 关掉时：灰球（「我不知道」），绝不装成绿点
    private func floatUnknown(pid: pid_t, element el: AXUIElement?) {
        guard !UnderlineOverlay.globallySilent else { return }
        guard let el else { return }
        guard let anchor = ballAnchor(pid: pid, fallback: el) else {
            logBall("hide", reason: "noanchor", pid: pid, rect: nil)
            FloatBall.shared.hide()
            return
        }
        logBall("show", reason: "unknown/\(anchor.source)", pid: pid, rect: anchor.rect)
        FloatBall.shared.update(.init(phase: .unknown, count: 0, severity: .grammar, pid: pid, anchor: anchor.rect))
    }

    /// 选元素顺序（纯函数，可离屏断言）：焦点可读 → key 可编辑 → 窗口正文
    enum ElementPick: String {
        case focused, keywindowEditable, windowBody, none
        static func choose(focusedReadable: Bool, keyEditableReadable: Bool, windowBodyExists: Bool) -> ElementPick {
            if focusedReadable { return .focused }
            if keyEditableReadable { return .keywindowEditable }
            if windowBodyExists { return .windowBody }
            return .none
        }
    }

    /// 每个 pid 上一次算出来的有效锚点：焦点一丢就 hide 是错的
    /// （和 attach-el-fail 清线同一个病：这一轮没读到 ≠ 用户不需要）
    private var lastBallAnchor: [pid_t: CGRect] = [:]

    /// 球的锚点：聚焦元素 → key window 可编辑框 → 传入容器 → 上次有效锚点
    /// 全都拿不到才返回 nil（调用方据此 hide 并记原因）
    private func ballAnchor(pid: pid_t, fallback el: AXUIElement) -> (rect: CGRect, source: String)? {
        if let focused = AXInline.focusedElement(pid: pid) {
            let f = elementRectQuartz(focused)
            if f.width > 0, f.height > 0 { lastBallAnchor[pid] = f; return (f, "focused") }
        }
        if let kw = AXInline.keyWindowEditable(pid: pid) {
            let f = elementRectQuartz(kw)
            if f.width > 0, f.height > 0 { lastBallAnchor[pid] = f; return (f, "keywindow") }
        }
        let f = elementRectQuartz(el)
        if f.width > 0, f.height > 0 { lastBallAnchor[pid] = f; return (f, "element") }
        if let cached = lastBallAnchor[pid] { return (cached, "lastAnchor") }
        return nil
    }

    /// 球的每一次显隐都落一行日志：爹地说「有时候不显示」时，不用靠猜
    private func logBall(_ action: String, reason: String, pid: pid_t, rect: CGRect?) {
        let r = rect.map { "[\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))]" } ?? "[-]"
        emit(CheckEvent(kind: "ball", pid: pid, app: appName(pid), role: action,
                        textLen: 0, sentenceLen: 0,
                        itemCount: 0, rectCount: rect == nil ? 0 : 1,
                        elapsed: "-", err: reason, at: Date(), path: r))
    }

    /// 清线之后的补偿检查：宁可闪一下重画，也不许留残影
    private var quickCheckTask: Task<Void, Never>?
    private var recheckTimer: Timer?
    private var scrollMonitor: Any?
    private var scrollMonitorLocal: Any?

    private func scheduleQuickCheck(after delay: TimeInterval) {
        quickCheckTask?.cancel()
        quickCheckTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.checkNow()
        }
    }

    private func CategoryPrefsSeverity(_ k: UnderlineKind) -> Int {
        switch k {
        case .spelling: return 4
        case .grammar: return 3
        case .clarity: return 2
        case .style: return 1
        }
    }

    private func printRects(_ specs: [UnderlineSpec], items: [DiffItem]) {
        print("── underline rects (\(specs.count)) ──")
        for s in specs {
            print(String(format: "  [%@] x=%.1f y=%.1f w=%.1f h=%.1f id=%d",
                         s.kind.rawValue, s.rect.minX, s.rect.minY, s.rect.width, s.rect.height, s.itemID))
        }
        for (i, it) in items.enumerated() {
            print("  edit#\(i) \(it.kind.rawValue) 「\(it.original)」→「\(it.replacement)」 @\(it.start)+\(it.length)")
        }
    }
}

// MARK: - 只检查可编辑区域（爹地 11-19 P0）

/// 进检查前的硬门槛。纯函数，便于断言。
/// 规则：可编辑元素才检查；只读正文唯一例外是 Mail 的邮件正文；
/// 网页里存在可编辑输入控件时也放行（随后会切到那个控件）。
enum InlineGate {
    /// 只查「你正在写的东西」（Grammarly 主场），阅读别人的内容默认不查。
    /// 11-23 爹地质问「我们检查的不是自己写的内容吗，和看邮件有什么关系」——
    /// 他说得对：Mail 阅读视图是别人的邮件，不是主场，还带来大量 skip-readonly。
    /// checkReading 保留开关（默认关），确要读信时再打开。
    static func shouldCheck(editable: Bool, isWebBody: Bool, isMailBody: Bool,
                            hasEditableWebField: Bool, checkReading: Bool = false) -> Bool {
        if editable { return true }
        if isWebBody && hasEditableWebField { return true }
        if checkReading && isWebBody && isMailBody { return true }
        return false
    }
}
