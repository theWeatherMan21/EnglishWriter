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
                guard (roleOf(el)) == "AXTextArea" else { continue }
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
        // 一轮检查内复用：每问一次 100~1500ms，问三遍就是白等三秒
        return AXRoundStats.shared.focusedElement(pid) { focusedElementUncached(pid: pid) }
    }

    private static func focusedElementUncached(pid: pid_t) -> AXUIElement? {
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

    /// web area 所在的**窗口**里是否存在可编辑控件（收件人/主题/正文任何一处）。
    /// Mail 写信窗口：正文是 AXWebArea，它自己 AXEditable=false，可编辑的是同窗口的兄弟节点；
    /// 阅读窗口则一个可编辑控件都没有 —— 这就是 compose 与 reading 的确定性区分。
    static func webAreaIsInEditableWindow(_ webArea: AXUIElement, pid: pid_t) -> Bool {
        var cur: AXUIElement? = webArea
        var win: AXUIElement?
        var hops = 0
        while let c = cur, hops < 12 {
            if (roleOf(c)) == "AXWindow" { win = c; break }
            guard let raw = attr(c, kAXParentAttribute as String) else { break }
            let cf = raw as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { break }
            cur = (cf as! AXUIElement)
            hops += 1
        }
        guard let w = win else { return false }
        for node in descendants(w, depth: 8) {
            let role = attrString(node, kAXRoleAttribute as String) ?? ""
            guard role == "AXTextArea" || role == "AXTextField" else { continue }
            if AXInline.isEditable(node) { return true }
        }
        return false
    }

    /// 一个 App 里「最值得看的」WebArea：优先含可编辑控件的（= 你正在写的），
    /// 其次文本最长的。Mail 的窗口里往往同时有邮件列表（几百个 3 字块）和正文，
    /// 只取第一个 WebArea 会去查列表那堆垃圾（11-23 实测 blocks=431 全是列表行）。
    static func bestWebBody(pid: pid_t) -> (el: AXUIElement, len: Int, hasField: Bool)? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        var wins: [AXUIElement] = []
        for key in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let v = attr(appEl, key as String), CFGetTypeID(v) == AXUIElementGetTypeID() {
                wins.append(v as! AXUIElement)
            }
        }
        wins.append(contentsOf: (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? [])
        var best: (el: AXUIElement, len: Int, hasField: Bool, score: Int)?
        for w in wins {
            for node in descendants(w, depth: 12) where WebText.isWebBody(node) {
                let len = WebText.blocks(of: node).reduce(0) { $0 + ($1.text as NSString).length }
                if len < 20 { continue }
                let hasField = textField(in: node) != nil
                let score = (hasField ? 1_000_000 : 0) + len
                if best == nil || score > best!.score { best = (node, len, hasField, score) }
            }
        }
        return best.map { ($0.el, $0.len, $0.hasField) }
    }

    /// WebArea 里的真输入控件：网页里的 textarea/input 在 AX 树里是 AXTextArea/AXTextField，
    /// AXValue 直接有内容（Chromium 真机实测）。有它就优先用它 —— 整页静态文本当正文会查错地方。
    static func textField(in body: AXUIElement) -> AXUIElement? {
        var best: (el: AXUIElement, len: Int)?
        for el in descendants(body, depth: 10) {
            let role = roleOf(el)
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
        for c in attrChildrenFast(el) {
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
                            role: roleOf(el),
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
                            role: roleOf(el),
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
        if !newItems.isEmpty { lastNonEmptyItems = newItems }
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
                                         role: roleOf(el),
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
            guard let self, let id = ItemLocator.id(for: it, in: self.items) else { return }
            _ = self.accept(itemID: id)
        }
        sb.onDismiss = { [weak self] it in
            Task { @MainActor in
                guard let self else { return }
                self.dropItem(start: it.start, length: it.length)
            }
        }
        // 侧栏的「改写这一段」：复用既有的 RewriteFlow（同一提示词、同一模型、同一条应用链），
        // 不另造一套，避免两边行为漂移。
        sb.onRewrite = { RewriteFlow.start(tone: false) }
        sb.onTone = { RewriteFlow.start(tone: true) }
        sb.onJump = { [weak self] it in
            Task { @MainActor in
                guard let self, let id = ItemLocator.id(for: it, in: self.items) else { return }
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

    /// Web 正文写回的整树复核（纯函数，可断言）：
    /// 宿主把 AXStaticText 换成新节点时，抓着旧元素复读永远读不回，
    /// 但整棵树重新走一遍能看见替换后的文本。看见了就算写进去。
    nonisolated static func webReadbackRecovered(fresh: String, replacement: String) -> Bool {
        guard !replacement.isEmpty else { return false }
        return fresh.contains(replacement)
    }

    /// 取哪份列表去接受：当前列表为空就用存档（两段式点击期间的 refresh 会清空）
    nonisolated static func itemsForAccept(_ items: [DiffItem], archive: [DiffItem]) -> [DiffItem] {
        items.isEmpty ? archive : items
    }

    /// 最近一次非空的建议列表。卡片/侧栏是「点开后再点按钮」两段式，
    /// 中间那一次 refresh 可能把 items 清空（宿主重排版、焦点跳走），
    /// 此时按 id 取会「越界 id=0 items=0」——爹地 11-23 撞到两次。
    /// 落地：拿最近这份存档做兜底，写回前仍会校验 range/original，不会写错地方。
    private var lastNonEmptyItems: [DiffItem] = []

    /// 侧栏条目 → items 索引（侧栏点接受/忽略/跳转都要靠它对上号）
    enum ItemLocator {
        static func id(for it: DiffItem, in items: [DiffItem]) -> Int? {
            items.firstIndex { $0.start == it.start && $0.length == it.length }
        }
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
        // Mail 优先：用 MailProbe 定位写信窗正文（与 checkNow / --probe-mail 同一口径）。
        // 知澜 11-24 实测：后台走通用 attach 路径 → 取到前台窗口正文（textLen=0、不检查），
        // 而 CLI 走 MailProbe 能读到「可见块[6字] Dear,」——两个口径必须合一。
        var mailPicked = false
        if appName(pid) == "Mail", let best = AXInline.bestWebBody(pid: pid), WebText.isWebBody(best.el) {
            mailPicked = true
            cand = best.el
            role = attrString(best.el, kAXRoleAttribute as String) ?? ""
            emit(CheckEvent(kind: "attach-mail-body", pid: pid, app: appName(pid), role: role,
                            textLen: (AXInline.fullText(of: best.el) ?? "").count, sentenceLen: 0,
                            itemCount: 0, rectCount: 0, elapsed: "-",
                            err: best.hasField ? "mail-compose-with-field" : "mail-compose-longest", at: Date()))
        }
        if !mailPicked, cand == nil || !textRole || !readable {
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
        AXRoundStats.shared.begin()
        defer { AXRoundStats.shared.end("check-round") }
        checkNowCore(for: pid, element: explicit)
    }

    private func checkNowCore(for pid: pid_t, element explicit: AXUIElement? = nil) {
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
            // Mail 这类窗口里同时有邮件列表和正文：取「含输入控件 / 文本最长」的那块，
            // 不取第一个 WebArea（11-23 实测：第一个是列表，431 个 3 字块）
            if let best = AXInline.bestWebBody(pid: pid) {
                el = best.el
                picked = best.hasField ? "web-body-with-field" : "web-body-longest"
            } else {
                el = wbEl!
                picked = WebText.isWebBody(el) ? "web-body" : "window-body"
            }
            diag.fallbackTextArea += 1
        case .none:
            diag.lastError = "没有焦点文本框"
            emit(CheckEvent(kind: "no-element", pid: pid, app: appName(pid), role: "-",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "焦点不可读 / 无 key 可编辑元素 / 无窗口正文", at: Date()))
            return
        }
        // Mail 写信窗：必须优先取正文 WebArea，不能被「焦点元素」骗走。
        // 11-24 实况：点接受/自动检查时焦点常落在某个 AXStaticText 上（可读 ≠ 可写），
        // 于是路径变成 statictext、isWebBody=false、门控判只读 → items=0，
        // 看起来像「没建议可接受」，其实是根本没检查正文。
        // 只在「调用方没指定元素」时才自选正文。
        // 指定了就必须用指定的那个：--accept-now 按 --expect 挑好窗口后，
        // 这里再抢一次就等于把检查跑回爹地的真邮件上（11-24 实况，知澜当场拦住）。
        if explicit == nil, appName(pid) == "Mail", MailProbe.isComposeWindow(pid: pid),
           let best = AXInline.bestWebBody(pid: pid) {
            el = best.el
            picked = "mail-compose-body"
            diag.lastPath = picked
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
        // 门控只管「这个 App 要不要看」，不在门控上按尺寸打分（11-23 退回）：
        // 面积刻度会把真正的写信窗也判成「不够大」；正文收窄交给
        // WebText.filterOutsideNavigation（按几何丢块，不误伤）。
        let hasEditableWebField = WebText.isWebBody(el) && AXInline.textField(in: el) != nil
        // Mail 的阅读窗也有可编辑节点（搜索框），所以要问「前台窗口有没有发送按钮」。
        // 这条不按尺寸打分：小窗口的写信区会被面积阈值误杀（11-23 退回那条阈值）。
        // 两个独立判据只要有一个说是写信窗，就不按「阅读窗」处理：
        // ① 发送按钮/收件人字段（窗口一多会翻成 false）② 窗口标题（New Message 这类）
        let composeBySignal = MailProbe.isComposeWindow(pid: pid)
        let composeByTitle = WebText.isWebBody(el) && MailProbe.windowTitleLooksCompose(el)
        let mailReading = (appName(pid) == "Mail") && !composeBySignal && !composeByTitle
        if composeByTitle && !composeBySignal {
            AppLog.info("check", "compose 判定：信号=false 但标题是写信窗 → 按写信窗处理")
        }
        let inEditableWindow = WebText.isWebBody(el) && AXInline.webAreaIsInEditableWindow(el, pid: pid)
        let gateEditable = AXInline.isEditable(el)
        AppLog.info("gate", "editable=\(gateEditable) web=\(WebText.isWebBody(el)) mailReading=\(mailReading) signal=\(composeBySignal) title=\(composeByTitle) field=\(hasEditableWebField)")
        if !InlineGate.shouldCheck(editable: gateEditable,
                                   isWebBody: WebText.isWebBody(el),
                                   isMailBody: isMailBody,
                                   hasEditableWebField: hasEditableWebField,
                                   checkReading: EnginePrefs.checkReading,
                                   inEditableWindow: inEditableWindow,
                                   mailReading: mailReading,
                                   composeWindow: composeBySignal || composeByTitle) {
            // 证据必须能自证：是不是真的有可编辑控件被误判成只读？
            let elRole = attrString(el, kAXRoleAttribute as String) ?? "?"
            let kind = AXInline.isEditable(el) ? "editable-but-unreadable"
                     : (WebText.isWebBody(el) ? "readonly-web" : "readonly")
            emit(CheckEvent(kind: "skip-readonly", pid: pid, app: appName(pid), role: elRole,
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: kind, at: Date()))
            // 不清线：这一轮读到的元素只读（点回邮件列表、焦点落到 AXTable），
            // 不代表用户不需要看正文上的线。线的存活只由「宿主换了」和 TTL 决定
            // —— 11-23 实测：render 出 10 条线后 5 秒，用户点进正文触发 skip-readonly，
            // 线被清空 → 紧接着的点击 rectCount=0、nearest=nan，看起来就是「点线没反应」。
            diag.lastError = "只读文本，跳过（保留现有线）"
            emit(CheckEvent(kind: "skip-readonly-keep", pid: pid, app: appName(pid), role: elRole,
                            textLen: 0, sentenceLen: 0, itemCount: items.count, rectCount: overlay.currentRects().count,
                            elapsed: "-", err: "不清线，等 TTL/宿主切换", at: Date()))
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
            emit(CheckEvent(kind: "no-text", pid: pid, app: appName(pid), role: roleOf(el),
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
                            role: roleOf(el),
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
                            role: roleOf(el),
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
            emit(CheckEvent(kind: "skip-lang", pid: pid, app: appName(pid), role: roleOf(el),
                            textLen: (full as NSString).length, sentenceLen: (sentence as NSString).length,
                            itemCount: 0, rectCount: 0, elapsed: "-", err: "-", at: Date()))
            floatUnknown(pid: pid, element: el)
            overlay.clear(); items = []
            return
        }
        // 同文本不重复请求
        let hash = "\(pid):\(sentence.hashValue)"
        if lastHash[pid] == hash {
            // 文本没变 = 这一轮复验通过：给现有线续命，否则 3 秒后线会自己消失
            overlay.touch(pid: pid)
            diag.dedupedHits += 1
            return
        }
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
        emit(CheckEvent(kind: "check", pid: pid, app: appName(pid), role: roleOf(el),
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
    nonisolated static func isBrowserBundle(_ bid: String) -> Bool { browserBundleIDs.contains(bid) }

    nonisolated static let browserBundleIDs: Set<String> = [
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
        // 先把「整块窗口」收窄到「真正在写的正文区」：
        // Mail 窗口是一个 AXWebArea，左栏 Inbox/Drafts、邮件列表、正文全是它的子孙。
        // 不收窄的后果（爹地 11-23 真机）：线画满整个窗口（左栏也画），
        // 写回偏移按「整篇（含左栏）」算 → 位置对不上 → 点接受没反应。
        let region = WebText.editableRegion(of: body)
        let target = region ?? body
        if region == nil {
            emit(CheckEvent(kind: "no-editable-region", pid: pid, app: appName(pid), role: "AXWebArea",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "没找到可编辑正文区，退回整页并按左侧 20% 过滤", at: Date()))
        }
        // 只查看得见的块：AXWebArea 代表整个文档，全量读出来能到 1477 块，
        // 一块一个 /v2/check 等于自己 DDoS 自己的引擎。
        let win = WebText.windowFrame(of: body)
        var visible = WebText.visibleBlocks(of: target, inWindow: win)
        // 再按正文区筛一遍：线只允许落在「你在写的地方」
        let frames = visible.map { WebText.frame($0.element) }
        let filtered = WebText.filterOutsideNavigation(frames: frames,
                                                       window: win,
                                                       editableFrame: region.map { WebText.frame($0) })
        if filtered.dropped > 0 {
            visible = filtered.keep.map { visible[$0] }
            emit(CheckEvent(kind: "drop-outside", pid: pid, app: appName(pid), role: "AXWebArea",
                            textLen: 0, sentenceLen: 0, itemCount: filtered.dropped, rectCount: visible.count,
                            elapsed: "-", err: "丢掉正文区外的 \(filtered.dropped) 块（左栏/列表/页脚）", at: Date()))
        }
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
            var ltOK = await LocalEngine.available()
            if !ltOK {
                LocalEngineBootstrap.ensureRunningThrottled()   // 闲置退出后按需拉回（节流 120s）
                // 立刻强探一次：LT 可能刚起来，负结果只缓存 2 秒，这一轮就能翻过来
                ltOK = await LocalEngine.available(force: true)
            }
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
        AppLog.info("m3", "blocks=\(blks.count) 送检块=\(texts.count) 跳过中文=\(cjkSkipped) 批次字符=\((batch.text as NSString).length) 预览=\(String(batch.text.prefix(90)).replacingOccurrences(of: "\n", with: "⏎"))")
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
                AppLog.info("m3", "引擎回传 items=\(out.items.count) → 映射后 \(BlockBatch.map(out.items, in: batch).count)")
                var acronymSkipped = 0
                for (it, bi) in BlockBatch.map(out.items, in: batch) {
                    // 全大写缩写/公司名不报拼写：WCA&JC、WCA、JC Trans 这类被当成拼写错误
                    // 就是「点接受改坏公司名」的根源（知澜 11-24 揪出）。
                    if it.kind == .spelling, Self.looksLikeAcronym(it.original) { acronymSkipped += 1; continue }
                    all.append(it)
                    map.append(bi)
                }
                if acronymSkipped > 0 {
                    AppLog.info("m3", "跳过全大写缩写 \(acronymSkipped) 条（拼写不动股东/公司名）")
                }
            } catch {
                AppLog.error("m3", "review 失败：\(error)")
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
        for (it, bi) in WebText.ItemFilter.dedupeAndCap(cands, item: { $0.0 }, max: maxItems,
                                                          key: { "\($0.1)|\($0.0.original.lowercased())" }) {
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
        if !kept.isEmpty { lastNonEmptyItems = kept }
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
        // 四段日志：accept-begin → accept-write → accept-readback / accept-fail
        // 为什么这么细：爹地报过「点了接受没反应」，而日志里只有一条 ok=false，
        // 分不清是没点中、写不进去、还是写进去又回滚了。三段分开记，一眼看出卡在哪。
        // items 被 refresh 清空时用存档兜底（写回前 M3Flow 仍校验 range/original）
        let pool = Self.itemsForAccept(items, archive: lastNonEmptyItems)
        guard id >= 0, id < pool.count else {
            emit(CheckEvent(kind: "accept-fail", pid: currentPid, app: appName(currentPid), role: "card",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "越界 id=\(id) items=\(items.count) 存档=\(lastNonEmptyItems.count)", at: Date()))
            return false
        }
        if items.isEmpty {
            emit(CheckEvent(kind: "accept-begin", pid: currentPid, app: appName(currentPid), role: "card",
                            textLen: 0, sentenceLen: 0, itemCount: id, rectCount: overlay.specs.count,
                            elapsed: "-", err: "items 已清空，改用存档第 \(id) 条", at: Date()))
        }
        items = pool
        let it = pool[id]
        emit(CheckEvent(kind: "accept-begin", pid: currentPid, app: appName(currentPid), role: "card",
                        textLen: 0, sentenceLen: 0, itemCount: id, rectCount: overlay.specs.count,
                        elapsed: "-", err: "range=\(it.start)+\(it.length) \"\(it.original)\"" , at: Date()))
        let doc = docFor(itemID: id)
        var out = M3Flow.accept(items: items, only: id, in: doc, stack: M3UndoStack.shared)
        // Web 正文的读回不可靠：Mail 写回后会把 AXStaticText 换成新节点，
        // 抓着旧元素复读永远是旧文本 → 判「写回后文本与期望不一致」再回滚（11-23 实测）。
        // 补救：整棵树重新走一遍，只要正文里出现了替换后的文本，就算写进去了。
        if !out.ok, currentElement != nil, itemBlock.indices.contains(id), itemBlock[id] >= 0 {
            let expectedTrim = out.expected.trimmingCharacters(in: .whitespacesAndNewlines)
            // 写回生效有延迟（粘贴后有重排/动画），单次复读经常读到旧树 → 冤枉判失败。
            // 这里最多复核 4 次、每次间隔 300ms；判据仍是「整篇逐字等于期望」。
            for attempt in 1...4 {
                usleep(300_000)
                let fresh = WebText.blocks(of: currentElement!).map { $0.text }.joined(separator: "\n")
                let freshTrim = fresh.trimmingCharacters(in: .whitespacesAndNewlines)
                if !expectedTrim.isEmpty, freshTrim == expectedTrim,
                   Self.webReadbackRecovered(fresh: fresh, replacement: it.replacement) {
                    AppLog.info("m3", "accept readback 复核（第 \(attempt) 次）：整篇与期望逐字一致，判成功")
                    out = M3Flow.AcceptOutcome(ok: true, expected: out.expected, actual: fresh,
                                               detail: "整树复核：已写入（读回元素被宿主替换）")
                    break
                }
                AppLog.info("m3", "accept readback 复核（第 \(attempt) 次）：\(freshTrim.count) 字 vs 期望 \(expectedTrim.count) 字，还不一致")
            }
        }
        if out.ok {
            emit(CheckEvent(kind: "accept-write", pid: currentPid, app: appName(currentPid), role: "card",
                            textLen: 0, sentenceLen: 0, itemCount: id, rectCount: 0,
                            elapsed: "-", err: "→ \"\(it.replacement)\" 栈=\(M3UndoStack.shared.count)", at: Date()))
        } else {
            emit(CheckEvent(kind: "accept-fail", pid: currentPid, app: appName(currentPid), role: "card",
                            textLen: 0, sentenceLen: 0, itemCount: id, rectCount: 0,
                            elapsed: "-", err: out.detail, at: Date()))
        }
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
            // read 必须现读 AX：构造时的 block.text 是快照，写回后再读还是旧值，
            // 于是「明明写进去了」被判定成「写回后文本与期望不一致」并回滚（爹地 15:11 实测三次）。
            let el = block.element
            return ClosureDoc(pid: currentPid,
                              read: { WebText.liveText(of: el) ?? block.text },
                              writeRange: { [weak self] r, t in
                                  self?.writeWebBlock(range: r, text: t, in: block, pid: self?.currentPid ?? 0) ?? false
                              },
                              writeFull: { [weak self] t in
                                  self?.writeWebBlock(range: NSRange(location: 0, length: (block.text as NSString).length),
                                                      text: t, in: block, pid: self?.currentPid ?? 0) ?? false
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

    /// Web 正文写回的唯一收口 —— 三层，每层都要**读回验证**。
    ///
    /// 11-23 两次真机证据：
    ///   ① docFor 直接调 WebText.replace 时 write-layer 一条都没有（走的是另一条路）
    ///   ② 接上之后：write-layer=AXSelectedText 报成功，文本一个字没变 → accept-fail
    /// 所以「AX 返回 success」不算写成功，只有读回看到替换后的文本才算。
    private func writeWebBlock(range: NSRange, text: String, in block: WebText.Block, pid: pid_t) -> Bool {
        // 换到能打字的容器 + 容器坐标（块内偏移 ≠ 容器偏移）
        // 三级找容器：块元素父链 → 当前 web 正文里最大的可编辑节点 → 当前 web area 本身
        var host = WebText.editableAncestor(of: block.element)
        var hostSrc = "父链"
        if host == nil, let cur = currentElement {
            host = WebText.editableRegion(of: cur)
            if host == nil { host = cur; hostSrc = "webarea" } else { hostSrc = "正文区" }
        }
        // Mail 写信窗：强制走键盘路径。
        // Mail 的 WebArea 接受 AXSelectedTextRange 的「设置」却读回不变（selSet=谎），
        // 只要 host 非 nil 就会掉进那三层假成功里，永远改不动正文（10:00 实况：直接 none）。
        if appName(pid) == "Mail", MailProbe.isComposeWindow(pid: pid), host != nil {
            AppLog.info("m3", "web-write 强制键盘路径（Mail 写信窗的 AX 容器不可写，忽略 host=\(hostSrc)）")
            host = nil
            hostSrc = "mail-compose(强制键盘)"
        }
        let hostText = host.flatMap { AXInline.fullText(of: $0) } ?? ""
        let mapped = host != nil ? WebText.mapRange(blockText: block.text, range: range, hostText: hostText) : nil
        AppLog.info("m3", "web-write host=\(host != nil ? hostSrc : "无") map=\(mapped.map { "\($0.location)+\($0.length)" } ?? "nil") hostLen=\(hostText.count) block=\(range.location)+\(range.length)")
        if host == nil {
            AppLog.info("m3", "web-write chain=\(WebText.parentRoles(of: block.element).joined(separator: " ← "))")
        }

        // 先抢回正文焦点：没有焦点，下面每一层都是空放（11-23 真机四层全败的原因）
        let focused = returnFocusToBody(pid: pid, element: currentElement ?? host)
        AppLog.info("m3", "focus-return=\(focused ? "ok" : "fail")")
        if !focused, appName(pid) == "Mail" {
            // Mail 同时开着多个窗口时，焦点落到别人那封 = 后面 ⌘A⌘C 复制的是别人的邮件
            // （11-24 14:06：AX=210、⌘C=29544）。宁可这一条不写，也不碰。
            AppLog.info("m3", "焦点不在目标窗口 —— 不按任何键，放弃本次写回")
            return false
        }

        // 单一写回路径（知澜 11-24 定案）：键盘事件。
        // 为什么砍掉前三层：Mail 的 AXSelectedTextRange 是假成功（dump 里 56 个节点 selSet 全谎），
        // 叠三个不可靠的方式只会让失败点更多、日志更糊。默认只走键盘，
        // 老三层留在 EW_WRITE_LEGACY=1 后面仅供排查，不再参与正常判定。
        let legacyLayers = ProcessInfo.processInfo.environment["EW_WRITE_LEGACY"] == "1"

        // ① 容器上 AXSelectedText（坐标已换算）—— 仅 legacy
        if legacyLayers, let h = host, let m = mapped, let v = axRangeValue(m.location, m.length) {
            _ = AXUIElementSetAttributeValue(h, kAXSelectedTextRangeAttribute as CFString, v)
            let err = AXUIElementSetAttributeValue(h, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
            if err == .success, Self.webWriteVerified(hostText: AXInline.fullText(of: h) ?? "", mapped: m, replacement: text) {
                Diag.shared.applyMethod = "AX 写回（正文容器）"
                AppLog.info("m3", "write-layer=AXSelectedText range=\(m.location)+\(m.length)")
                return true
            }
            AppLog.info("m3", "write-layer=AXSelectedText 但读回没变（API 报 success 不做事）—— 落剪贴板")
        }

        // ② 剪贴板 ⌘V —— 必须先确认选区真的落在了容器上。
        // 11-23 真机：选区没生效也照样粘，结果 sent 被追加到正文末尾而不是覆盖 send。
        if legacyLayers, let h = host, let m = mapped, let v = axRangeValue(m.location, m.length) {
            _ = AXUIElementSetAttributeValue(h, kAXSelectedTextRangeAttribute as CFString, v)
            let landed = Self.selectionLanded(h, expected: m)
            AppLog.info("m3", "clipboard 前置：选区 \(landed ? "已落下" : "没落下，不粘") range=\(m.location)+\(m.length)")
            if landed, pasteViaClipboard(text, to: pid) {
                usleep(450_000)
                let after = AXInline.fullText(of: h) ?? ""
                if Self.webWriteVerified(hostText: after, mapped: m, replacement: text) {
                    Diag.shared.applyMethod = "剪贴板 ⌘V 兜底"
                    AppLog.info("m3", "write-layer=clipboard range=\(m.location)+\(m.length) len=\(text.count)")
                    return true
                }
                AppLog.info("m3", "clipboard 粘了但位置不对（选区丢失会粘到末尾）—— 不判成功")
            }
        }
        // ③ 暴力兜底：选中容器全文 + 粘贴「整段替换后的文本」
        //    （容器不接受区间选区时唯一还能走的路；不改别的，只改这一段）
        if legacyLayers, let h = host, let m = mapped,
           let full = WebText.replacedFullText(hostText: AXInline.fullText(of: h) ?? "", mapped: m, replacement: text),
           let all = axRangeValue(0, (full as NSString).length) {
            _ = AXUIElementSetAttributeValue(h, kAXSelectedTextRangeAttribute as CFString, all)
            let landedAll = Self.selectionLanded(h, expected: NSRange(location: 0, length: (full as NSString).length))
            AppLog.info("m3", "整段替换前置：全选 \(landedAll ? "已落下" : "没落下，跳过")")
            if landedAll, pasteViaClipboard(full, to: pid) {
                usleep(450_000)
                Diag.shared.applyMethod = "整段替换（剪贴板）"
                AppLog.info("m3", "write-layer=clipboard-full len=\(full.count)（区间写不进，改整段）")
                return true
            }
        }
        // ④ 键盘兜底：Mail 正文没有任何可编辑 AX 容器（11-23 真机 host=无）
        //    ⌘A 全选 → 读全文 → 本地改一处 → ⌘V 覆盖 → 再 ⌘A 读回验证
        if host == nil {
            let original = (block.text as NSString).substring(with: range)
            pressSelectAll(to: pid)
            // ⌘A 之后必须确认选区覆盖全文：读 AXValue 拿到全文不等于选中了全文，
            // 没选中就粘 = 追加到末尾（11-23 真机症状）。
            // ⌘A 之后确认「选中了全文」：AX 的选区读数不可信，用 ⌘C 的事实判断。
            var copied = readSelectionViaClipboard(pid: pid) ?? ""
            if copied.isEmpty {                       // 剪贴板偶发空：等一拍重试一次
                usleep(180_000)
                pressSelectAll(to: pid)
                copied = readSelectionViaClipboard(pid: pid) ?? ""
            }
            // ★ 硬闸：⌘C 必须把 AX 能读到的字全都复制到。
            // 11:31 实况：AX 读到 320 字，⌘A⌘C 只给 253 字（少 67 字，正好是签名块那几行）。
            // 拿「读多少写多少」的逻辑去改一封邮件，读少一次 = 多出来的字被静默删掉。
            // 判据：非空白字符数 ⌘C ≥ AX，否则一个字都不写。
            let axFull = WebText.blocks(of: currentElement ?? AXUIElementCreateSystemWide())
                .map { $0.text }.joined(separator: "\n")
            func visibleCount(_ t: String) -> Int {
                t.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
            }
            // 「AX 字数 == ⌘C 字数」这条闸是错的（知澜 11:44 查清）：
            // 签名里有图片，⌘C 复制 HTML 时 <img> 变成文件名文字（downloadex.png），
            // AX 读纯文本不数图片 → 两边永远不等 → 闸恒拒绝，等于把功能焊死。
            // 防吃字改由「写前备份 + 写后逐段比对 + 图片数不变，不符回滚」负责（见 replaceWholeBodyRich）。
            let axN = visibleCount(axFull), cbN = visibleCount(copied)
            // 复制量硬闸：⌘C 拿到的是目标正文的若干倍 → 焦点跑到别的邮件去了，立刻放弃。
            if axN > 0, cbN > axN * 3 {
                AppLog.info("m3", "复制量异常（⌘C \(cbN) 字 > AX \(axN) 字 ×3）—— 焦点不在目标窗口，一个字都不写")
                return false
            }
            AppLog.info("m3", "复制概况：AX=\(axN)字（不含图片文件名）⌘C=\(cbN)字（含图片文件名）—— 差值来自签名图片，不拦")
            // 先试词级替换：只动那一个词，格式（粗体/链接/图片）不受影响。
            // 失败一律回落整篇替换，绝不留在半选状态。
            // 词级（精确选一个词）默认关闭：WKWebView 里没有可靠方式指定「第 7–10 个字符」，
            // ⇧⌥→ / ⌥← / 自纠 / ⌘F 六轮全部失败（⌘F 在 WebView 只是高亮，不是可复制的选区）。
            // 词级定位改成「字符计数」（⇧→ 按 N 次），不再依赖词边界语义。
            // 要临时关掉：EW_WORD_REPLACE=0。
            if !copied.isEmpty, ProcessInfo.processInfo.environment["EW_WORD_REPLACE"] != "0" {
                let word = tryKeyboardWordReplace(original: original, replacement: text, blockText: block.text,
                                                  pid: pid, wholeBody: copied)
                if word.ok { return true }
                // 已经按过键：文本状态不可预测，绝不再走整篇替换
                if word.mutated {
                    AppLog.info("m3", "词级路径已动过键，放弃回落（避免二次写入把正文搞乱）")
                    return false
                }
            }
            // 覆盖判据：复制出来的内容必须「包含了该块原文」，且不短于该块。
            // 不能拿 copied.count 自己跟自己比（永远成立）—— 那是把校验写成恒真。
            let needleBlock = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let covered = !copied.isEmpty && (copied.count >= needleBlock.count) && copied.contains(needleBlock)
            AppLog.info("m3", "全选读回 \(copied.count) 字（块原文 \(needleBlock.count) 字，覆盖=\(covered)）")
            let selCovered = covered
            if let full = (copied.isEmpty ? nil : copied), covered,
               WebText.allowFullReplace(fullText: full),
               let newFull = WebText.replaceOnce(fullText: full, original: original, replacement: text),
               newFull != full, Self.backupDraft(full) {
                let rich = replaceWholeBodyRich(original: original, replacement: text,
                                                newFull: newFull, pid: pid)
                if rich.ok { return true }
                // 富文本路径已经按过 ⌘V：正文可能已被改动，绝不再粘一次纯文本（会双重写入）。
                if rich.pasted { return false }
                guard pasteViaClipboard(newFull, to: pid) else { return false }
                usleep(500_000)
                pressSelectAll(to: pid)
                let back = readSelectionViaClipboard(pid: pid) ?? ""
                if back.trimmingCharacters(in: .whitespacesAndNewlines) == newFull.trimmingCharacters(in: .whitespacesAndNewlines) {
                    Diag.shared.applyMethod = "键盘全选替换"
                    AppLog.info("m3", "write-layer=keyboard-all len=\(newFull.count)（正文无可编辑 AX 容器）")
                    return true
                }
                AppLog.info("m3", "write-layer=keyboard-all 但读回不一致（字数 \(back.count) vs \(newFull.count)）")
            } else {
                AppLog.info("m3", "keyboard-all 前置条件不满足（复制到 \(copied.count) 字 / 覆盖 \(selCovered) / 原文不唯一 / 正文超长拒绝覆盖）")
            }
        }
        AppLog.info("m3", "write-layer=none range=\(range.location)+\(range.length)（键盘路径前置条件不满足：选区空 / 未全选 / 原文不唯一 / 正文超长）")
        return false
    }

    /// ⌘A 之后：该进程焦点元素的选区是否覆盖全文（长度 == 全文长度）。
    /// 读 AXValue 拿到全文不代表选中了；没选中就粘 = 粘到光标处（末尾）。
    nonisolated static func selectionCoversAllText(pid: pid_t) -> Bool {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f as CFTypeRef) == AXUIElementGetTypeID() else { return false }
        var cur = f as! AXUIElement
        for _ in 0..<5 {
            if let r = axSelection(cur) {
                var val: CFTypeRef?
                if AXUIElementCopyAttributeValue(cur, kAXValueAttribute as CFString, &val) == .success,
                   let t = val as? String, !t.isEmpty {
                    return r.length >= (t as NSString).length - 1   // 容差 1（末尾换行）
                }
            }
            guard let raw = attr(cur, kAXParentAttribute as String) else { break }
            let cf = raw as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { break }
            cur = (cf as! AXUIElement)
        }
        return false
    }

    /// 选区是否真的落在期望区间（容差 0）。
    nonisolated static func selectionLanded(_ el: AXUIElement, expected: NSRange) -> Bool {
        guard let r = axSelection(el) else { return false }
        return r.location == expected.location && r.length == expected.length
    }

    /// 读回验证（纯函数）：容器文本在 mapped 位置上是否已经是替换后的文本
    nonisolated static func webWriteVerified(hostText: String, mapped: NSRange, replacement: String) -> Bool {
        let ht = hostText as NSString
        guard mapped.location >= 0, mapped.length >= 0, mapped.location + mapped.length <= ht.length else { return false }
        return ht.substring(with: mapped) == replacement
    }

    /// 整段覆盖前先把原文落盘。全选覆盖不可撤销地改写正文，
    /// 万一改错（或在长邮件上毁格式），我还能把它原样还回去。
    @discardableResult
    static func backupDraft(_ text: String) -> Bool {
        let dir = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/EnglishWriter/draft-backup")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let path = (dir as NSString).appendingPathComponent("draft-\(f.string(from: Date())).txt")
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            AppLog.info("m3", "draft-backup \(path)")
            return true
        } catch {
            AppLog.error("m3", "draft-backup 失败：\(error.localizedDescription) —— 不覆盖正文")
            return false
        }
    }

    /// 合成 ⌘A（给键盘兜底用）：Mail 正文没有可编辑 AX 容器时，只能靠键击
    /// 通用组合键（keyCode + 修饰键），键击只发给目标进程
    private func pressKey(_ vk: CGKeyCode, flags: CGEventFlags, to pid: pid_t, settleUs: useconds_t = 60_000) {
        guard pid > 0 else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.postToPid(pid); up.postToPid(pid)
        usleep(settleUs)
    }

    /// 逐字键入（等同于人手打字）。不碰剪贴板：
    /// 粘贴会把宿主当成「外部内容」，格式/撤销栈都可能被牵连；
    /// 键入是「用户输入」，宿主只改插入点，周围格式一律不动（Grammarly 也是这么做的）。
    private func typeText(_ text: String, to pid: pid_t) {
        guard pid > 0, !text.isEmpty else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        for ch in text {
            var units = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.postToPid(pid)
            up.postToPid(pid)
            usleep(12_000)
        }
        usleep(120_000)
    }

    /// 只替换「那一个词」，不动整篇 —— 保住粗体/链接/图片等格式。
    /// 只替换「那一个词」，不动整篇 —— 保住粗体/链接/图片等格式。
    /// 定位用**字符计数**（⇧→ 按 N 次 = 精确 N 个字符），不依赖 ⌥→ 的词边界语义
    /// —— 那就是前六轮失败的同一个根因。
    /// 返回 (成功, 是否已经按下过键)。按过键就不许调用方回落整篇：文本状态已不可预测。
    private func tryKeyboardWordReplace(original: String, replacement: String, blockText: String,
                                        pid: pid_t, wholeBody: String) -> (ok: Bool, mutated: Bool) {
        let noSpace = original.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
            && replacement.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        let ascii = original.allSatisfy { $0.isASCII }
        let occurrences = blockText.components(separatedBy: original).count - 1
        AppLog.info("m3", "keyboard-word 前置：noSpace=\(noSpace) ascii=\(ascii) 块内出现=\(occurrences) \"\(original)\"→\"\(replacement)\"")
        guard noSpace, ascii, !original.isEmpty, occurrences == 1 else { return (false, false) }

        let blockRange = (wholeBody as NSString).range(of: blockText)
        let rInBlock = (blockText as NSString).range(of: original)
        if blockRange.location == NSNotFound {
            // 静默失败点（11-24 知澜实测）：正文被 AppleScript/宿主重设过之后，块文本与整篇对不上，
            // 旧代码在这里一声不响地 return，用户看到的是「点了没反应，也没任何提示」。
            let head = { (t: String) -> String in String(t.prefix(40)).replacingOccurrences(of: "\n", with: "⏎") }
            AppLog.info("m3", "keyboard-word 放弃：块文本在整篇里找不到（块 \(blockText.count) 字 / 全文 \(wholeBody.count) 字）块首40=\"\(head(blockText))\" 全文首40=\"\(head(wholeBody))\"")
            return (false, false)
        }
        if rInBlock.location == NSNotFound {
            AppLog.info("m3", "keyboard-word 放弃：目标词 \"\(original)\" 不在块文本里（块 \(blockText.count) 字）")
            return (false, false)
        }
        let absOffset = blockRange.location + rInBlock.location
        let len = original.count
        guard absOffset <= 4000 else {
            AppLog.info("m3", "keyboard-word 放弃：偏移 \(absOffset) 太大（按键次数过多）")
            return (false, false)
        }
        AppLog.info("m3", "keyboard-word 定位：块=\(blockRange.location)+\(blockRange.length) 词偏移=\(absOffset) 长度=\(len) 全文\(wholeBody.count)字")

        guard returnFocusToBody(pid: pid, element: currentElement) else {
            AppLog.info("m3", "keyboard-word 放弃：焦点不在目标窗口")
            return (false, false)
        }
        pressKey(0x7E, flags: .maskCommand, to: pid, settleUs: 120_000)     // ⌘↑ 文首
        for _ in 0..<absOffset { pressKey(0x7C, flags: [], to: pid, settleUs: 5_000) }        // → × abs
        for _ in 0..<len { pressKey(0x7C, flags: .maskShift, to: pid, settleUs: 5_000) }      // ⇧→ × len
        var picked = readSelectionViaClipboard(pid: pid) ?? ""
        AppLog.info("m3", "keyboard-word 字符级选中 \"\(picked)\"（期望 \"\(original)\"）")
        var tries = 0
        while picked != original, tries < 4 {
            if picked.count > original.count {
                pressKey(0x7B, flags: .maskShift, to: pid, settleUs: 20_000)
            } else if !picked.isEmpty, original.hasPrefix(picked) {
                pressKey(0x7C, flags: .maskShift, to: pid, settleUs: 20_000)
            } else {
                break
            }
            picked = readSelectionViaClipboard(pid: pid) ?? ""
            tries += 1
            AppLog.info("m3", "keyboard-word 微调\(tries)：\"\(picked)\"")
        }
        guard picked == original else {
            AppLog.info("m3", "keyboard-word 字符级定位失败（\(picked.count)字 vs 期望 \(len)字）—— 收起选区、放弃，正文未改动")
            pressKey(0x7C, flags: [], to: pid)
            return (false, true)
        }

        typeText(replacement, to: pid)
        usleep(350_000)
        pressSelectAll(to: pid)
        var back = readSelectionViaClipboard(pid: pid) ?? ""
        if back.isEmpty { usleep(220_000); pressSelectAll(to: pid); back = readSelectionViaClipboard(pid: pid) ?? "" }
        let expected = (wholeBody as NSString).replacingCharacters(in: NSRange(location: absOffset, length: len),
                                                                   with: replacement)
        // 判据是逐字相等（不是比长度）：send→sent 同长度，若一个字都没打进去，长度也一样。
        let sameAsClip = Self.squash(back) == Self.squash(expected)
        let imagesNow = Self.webImageCount(of: currentElement)
        AppLog.info("m3", "keyboard-type 校验：逐字一致=\(sameAsClip) 读回\(Self.squash(back).count)字 期望\(Self.squash(expected).count)字 图片=\(imagesNow)")
        if !sameAsClip {
            AppLog.info("m3", "逐字差异：\(Self.firstDiff(Self.squash(back), Self.squash(expected)))")
        }
        if sameAsClip {
            Diag.shared.applyMethod = "键盘词级替换（字符计数定位）"
            AppLog.info("m3", "write-layer=keyboard-charcount \"\(original)\"→\"\(replacement)\"（逐字键入，未动剪贴板/整篇）")
            return (true, true)
        }
        AppLog.info("m3", "keyboard-type 读回不一致 —— 报失败，不再改动")
        return (false, true)
    }

    private func pressSelectAll(to pid: pid_t) {
        guard pid > 0 else { return }
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        usleep(150_000)
    }

    /// 诊断用：对比「AX 能读到多少字」与「⌘A⌘C 实际复制到多少字」，不写任何东西。
    func copyProbe(pid: pid_t, element: AXUIElement) -> (ax: Int, cb: Int, axTail: String, cbTail: String, images: Int, rtfBytes: Int) {
        let blocks = WebText.blocks(of: element)
        let axText = blocks.map { $0.text }.joined(separator: "\n")
        func vis(_ t: String) -> Int {
            t.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        }
        _ = returnFocusToBody(pid: pid, element: element)
        pressSelectAll(to: pid)
        let copied = readSelectionViaClipboard(pid: pid) ?? ""
        return (vis(axText), vis(copied),
                String(axText.suffix(40)).replacingOccurrences(of: "\n", with: "⏎"),
                String(copied.suffix(40)).replacingOccurrences(of: "\n", with: "⏎"),
                Self.webImageCount(of: element), lastCopiedRTF?.count ?? 0)
    }

    /// 复制完整性判据：⌘C 的非空白字数必须 ≥ AX 能读到的字数。
    /// 11:31 实况：AX=320、⌘C=253（少 67 字）；若放行就是「读多少写多少」，
    /// 多出来的那 67 个字会被静默删掉。两边任一为 0 时无法判定，按「不拦」处理（另有别的判据兜）。
    /// AX 树里的图片节点数（判「写回有没有把签名图片搞丢」）。
    nonisolated static func webImageCount(of el: AXUIElement?) -> Int {
        guard let el else { return 0 }
        var n = 0
        func walk(_ e: AXUIElement, _ d: Int) {
            if d > 14 { return }
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXImage" { n += 1 }
            var kidsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kidsRef) == .success,
               let kids = kidsRef as? [AXUIElement] {
                for k in kids.prefix(400) { walk(k, d + 1) }
            }
        }
        walk(el, 0)
        return n
    }

    /// 把写前的 RTF 落盘（回滚/取证用）。
    nonisolated static func backupRTF(_ rtf: Data) -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EnglishWriter/rtf-backup", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("body-\(Int(Date().timeIntervalSince1970)).rtf")
        do { try rtf.write(to: f); return f.path } catch { return nil }
    }

    /// 回滚：把最近一份 RTF 备份整篇粘回去（⌘A ⌘V）。
    func restoreFromBackup(pid: pid_t) -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/EnglishWriter/rtf-backup", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "rtf" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return da > db
            } ?? []
        guard let latest = files.first, let rtf = try? Data(contentsOf: latest) else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        if let attr = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
            pb.setString(attr.string, forType: .string)
        }
        pb.setData(rtf, forType: .rtf)
        pressSelectAll(to: pid)
        pressKey(0x09, flags: .maskCommand, to: pid, settleUs: 600_000)
        usleep(500_000)
        return true
    }

    /// 两串第一处差异的位置（逐字比对失败时用，别只报字数）。
    nonisolated static func firstDiff(_ a: String, _ b: String) -> String {
        let aa = Array(a), bb = Array(b)
        var i = 0
        while i < aa.count, i < bb.count, aa[i] == bb[i] { i += 1 }
        let ctx = { (arr: [Character]) -> String in
            guard !arr.isEmpty else { return "空" }
            let lo = max(0, i - 6), hi = min(arr.count, i + 8)
            return String(arr[lo..<hi])
        }
        return "第\(i)字起不同：实际「\(ctx(aa))」期望「\(ctx(bb))」"
    }

    /// 归一：去掉所有空白后比较。AX 树与剪贴板的换行/空行不一致，只能按非空白字符比。
    nonisolated static func squash(_ t: String) -> String {
        String(t.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    nonisolated static func copyComplete(axCount: Int, clipboardCount: Int) -> Bool {
        if axCount <= 0 { return true }          // AX 读不到时无法判定（此时也拿不到块文本）
        return clipboardCount >= axCount          // 复制到 0 字同样算「不全」，必须拒绝
    }

    /// 全大写缩写 / 含 & 的机构名：不报拼写。
    /// 判据：去掉标点后长度 ≥2 且全是字母、且全部大写（WCA、JC、HQ、WCA&JC 里的 WCA）。
    /// 反例：句首大写的普通词（"Send"）只有首字母大写，不算。
    nonisolated static func looksLikeAcronym(_ token: String) -> Bool {
        let letters = token.filter { $0.isLetter }
        guard letters.count >= 2 else { return false }
        guard letters.allSatisfy({ $0.isUppercase || !$0.isCased }) else { return false }
        // 至少要有两个真正的大写字母，避免「&」之类的噪声
        return letters.filter { $0.isUppercase }.count >= 2
    }

    /// 用 ⌘C 读选区：AX 报的选区长度在 Mail 上是假话（selSet=谎），
    /// 而「复制出来的东西」是应用自己写的系统剪贴板——这是唯一能当判据的事实。
    /// 读完立刻还原剪贴板，不动爹地原本的内容。
    /// 最近一次 ⌘C 拿到的 RTF（WebView 复制富文本时才有）。整篇替换用它保格式。
    private var lastCopiedRTF: Data?

    private func readSelectionViaClipboard(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        // 写一个哨兵先：⌘C 没生效时读到的一定是哨兵，而不是上一次的残余。
        // 11:15 两次修正读回同一段 " sen"，很可能就是剪贴板没刷新（哨兵能立刻分辨）。
        let sentinel = "__EW_CB_\(UUID().uuidString)__"
        pb.clearContents()
        pb.setString(sentinel, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            if let e = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: isDown) {
                e.flags = .maskCommand
                e.postToPid(pid)
            }
        }
        var got = pb.string(forType: .string)
        var waited = 0
        while (got == nil || got == sentinel), waited < 6 {   // 最多再等 600ms
            usleep(100_000); waited += 1
            got = pb.string(forType: .string)
        }
        lastCopiedRTF = pb.data(forType: .rtf)
        if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
        return (got == sentinel) ? nil : got
    }

    /// 把键盘焦点交回「指定的那个窗口里的正文」。
    /// 顺序：先 raise 目标窗口 → activate（不带 .activateAllWindows）→ 核对焦点窗口身份 → 才允许按键。
    /// 为什么不能先 .activateAllWindows：它会把 Mail 所有窗口抬到前面，焦点落到最上面那个
    /// （往往是爹地正在看的那封），随后 ⌘A⌘C 复制的就是他的邮件（11-24 14:06：AX=210、⌘C=29544）。
    private func returnFocusToBody(pid: pid_t, element: AXUIElement?) -> Bool {
        guard pid > 0 else { return false }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.4)

        let targetWin = windowAncestor(of: element)
        if let w = targetWin {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
        usleep(220_000)
        if let w = targetWin {          // activate 之后再抬一次，压过系统自己挑的 key 窗口
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            _ = AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            usleep(120_000)
        }
        if let el = element {
            _ = AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        var focusedWinRef: CFTypeRef?
        let gotFocused = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedWinRef) == .success
        let focusedWin: AXUIElement? = (gotFocused && focusedWinRef != nil
            && CFGetTypeID(focusedWinRef as CFTypeRef) == AXUIElementGetTypeID())
            ? (focusedWinRef as! AXUIElement) : nil
        let sameWin = (targetWin != nil && focusedWin != nil) ? CFEqual(focusedWin!, targetWin!) : false
        let frontOK = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let titleOf: (AXUIElement?) -> String = { w in
            guard let w else { return "-" }
            var t: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &t)
            return (t as? String) ?? "-"
        }
        AppLog.info("m3", "focus-return 细节 front=\(frontOK) 目标窗=\"\(titleOf(targetWin))\" 焦点窗=\"\(titleOf(focusedWin))\" 同窗=\(sameWin)")
        if !frontOK || targetWin == nil || !sameWin {
            AppLog.info("m3", "focus-return=fail（焦点不在目标窗口）—— 不按任何键，直接放弃")
            return false
        }
        var fe: CFTypeRef?
        let hasEl = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &fe) == .success
        AppLog.info("m3", "focus-return=ok（前台 + 焦点窗就是目标窗\(hasEl ? "，能读焦点元素" : "")）")
        return true
    }

    /// 从元素往上找它所属的 AXWindow。
    private func windowAncestor(of element: AXUIElement?) -> AXUIElement? {
        guard var cur = element else { return nil }
        for _ in 0..<12 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String, role == "AXWindow" { return cur }
            var pRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &pRef) == .success,
                  let p = pRef, CFGetTypeID(p as CFTypeRef) == AXUIElementGetTypeID() else { return nil }
            cur = (p as! AXUIElement)
        }
        return nil
    }

    private func selectedText(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.3)
        var focused: CFTypeRef?
        var el: AXUIElement?
        if AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
           let f = focused, CFGetTypeID(f as CFTypeRef) == AXUIElementGetTypeID() {
            el = (f as! AXUIElement)
        }
        if el == nil {
            var winRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
               let w = winRef, CFGetTypeID(w as CFTypeRef) == AXUIElementGetTypeID() {
                el = (w as! AXUIElement)
            }
        }
        guard var el else { return nil }
        // 选区可能挂在焦点元素的祖先上（Mail 的 web 正文就是这样）：
        // 依次读 AXSelectedText，再退到 AXValue，最多上溯 4 层
        for _ in 0..<5 {
            var sel: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success,
               let t = sel as? String, !t.isEmpty {
                return t
            }
            var val: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &val) == .success,
               let t = val as? String, !t.isEmpty {
                return t
            }
            guard let raw = attr(el, kAXParentAttribute as String) else { break }
            let cf = raw as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { break }
            el = (cf as! AXUIElement)
        }
        return nil
    }

    /// 写回四层降级（原位替换）：AX text operation → 选区 + AXSelectedText → 剪贴板 ⌘V（用完恢复剪贴板）
    private func layeredWrite(range: NSRange, text: String, to el: AXUIElement, pid: pid_t) -> Bool {
        guard let v = axRangeValue(range.location, range.length) else { return false }
        _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        Audit.write("Inline.accept")
        if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success {
            Diag.shared.applyMethod = "AX 写回"
            AppLog.info("m3", "write-layer=AXSelectedText range=\(range.location)+\(range.length)")
            return true
        }
        // Chromium / Mail 网页正文：AXValue / AXSelectedText 实测都写不进（11-16、11-23 两次探测）→ 剪贴板兜底
        _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        if pasteViaClipboard(text, to: pid) {
            usleep(450_000)
            // 这里**不再**用 el 的 AXValue 自证：WebArea 的 AXValue 恒空，
            // 拿它判会「粘贴成功也判失败」再回滚（11-23 实测三次 accept-fail）。
            // 写没写进去统一交给 M3Flow 的 readBack（现读块文本、带重试与空白归一）判。
            Diag.shared.applyMethod = "剪贴板 ⌘V 兜底"
            AppLog.info("m3", "write-layer=clipboard range=\(range.location)+\(range.length) len=\(text.count)")
            return true
        }
        AppLog.info("m3", "write-layer=none range=\(range.location)+\(range.length)（AX 与剪贴板都失败）")
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
    /// 属性段数量：用来量化「格式有没有变」。同一份 RTF 改一个词，段数应基本不变。
    private func attributeRunCount(_ attr: NSAttributedString) -> Int {
        var i = 0, n = 0
        while i < attr.length {
            var eff = NSRange()
            _ = attr.attributes(at: i, longestEffectiveRange: &eff,
                                in: NSRange(location: 0, length: attr.length))
            n += 1
            i = eff.length > 0 ? eff.location + eff.length : i + 1
        }
        return n
    }

    /// 富文本整篇替换：把 ⌘C 拿到的 RTF 改掉那一个词，再整篇粘回。
    /// 目的：既保住粗体/链接/字号（RTF 原样搬回），又不用在 WKWebView 里精确选词。
    /// 富文本整篇替换（三段式：备份 → 写 → 校验，不符就回滚）。
    ///
    /// 为什么不能用「字数相等」当判据：签名里有图片，⌘C 复制 HTML 时 <img> 会变成文件名
    /// 文字、AX 读文本不数图片 → 两边永远不等（11:44 查清，差 65 字全是 downloadex.png）。
    /// 真正的防吃字判据是：写后除目标词外逐字相同 + 图片节点数不变，任何一条不符就用备份回滚。
    private func replaceWholeBodyRich(original: String, replacement: String,
                                      newFull: String, pid: pid_t) -> (ok: Bool, pasted: Bool) {
        guard let rtf = lastCopiedRTF,
              let attr = try? NSAttributedString(data: rtf,
                                                 options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                 documentAttributes: nil) else {
            AppLog.info("m3", "富文本整篇：剪贴板没有 RTF（WebView 给的是纯文本），改走纯文本粘贴")
            return (false, false)
        }
        let m = NSMutableAttributedString(attributedString: attr)
        let r = (m.string as NSString).range(of: original)
        guard r.location != NSNotFound else {
            AppLog.info("m3", "富文本整篇：RTF 里找不到 \"\(original)\"，不猜，走纯文本")
            return (false, false)
        }
        let runsBefore = attributeRunCount(attr)
        let imagesBefore = Self.webImageCount(of: currentElement)
        let beforeText = (attr.string as String)
        // ① 备份：AX 纯文本 + RTF 都落盘，出问题能原样粘回去
        Self.backupDraft(newFull)
        let rtfPath = Self.backupRTF(rtf)

        m.replaceCharacters(in: r, with: replacement)
        let runsAfter = attributeRunCount(m)
        let rtfOut = try? m.data(from: NSRange(location: 0, length: m.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(newFull, forType: .string)
        if let out = rtfOut { pb.setData(out, forType: .rtf) }
        pressSelectAll(to: pid)
        pressKey(0x09, flags: .maskCommand, to: pid, settleUs: 600_000)   // ⌘V
        usleep(450_000)
        // 到这里正文已经动过，不许再粘第二次

        // ③ 校验：逐字（除目标词）+ 图片数
        var back = ""
        for _ in 0..<3 {
            pressSelectAll(to: pid)
            let one = readSelectionViaClipboard(pid: pid) ?? ""
            usleep(200_000)
            if !one.isEmpty { back = one; break }
        }
        let imagesAfter = Self.webImageCount(of: currentElement)
        let backSq = Self.squash(back), expSq = Self.squash(newFull)
        let textOK = !backSq.isEmpty && backSq == expSq
        let imgOK = imagesBefore == imagesAfter
        let runsOK = runsBefore == runsAfter || abs(runsBefore - runsAfter) <= 1
        AppLog.info("m3", "富文本整篇校验：before=\(Self.squash(beforeText).count)字 after=\(backSq.count)字 期望=\(expSq.count)字 一致=\(textOK) 图片 \(imagesBefore)→\(imagesAfter) 属性段 \(runsBefore)→\(runsAfter)")
        if textOK && imgOK && runsOK {
            Diag.shared.applyMethod = "富文本整篇替换"
            AppLog.info("m3", "write-layer=clipboard-rtf len=\(newFull.count) 图片=\(imagesAfter) 段=\(runsAfter) RTF备份=\(rtfPath ?? "-")")
            return (true, true)
        }
        // 回滚：把写前的 RTF 原样粘回去
        AppLog.info("m3", "富文本整篇校验不过（文本=\(textOK) 图片=\(imgOK) 段=\(runsOK)）—— 回滚")
        let restoreOK = restoreFromBackup(pid: pid)
        AppLog.info("m3", "回滚结果=\(restoreOK ? "已恢复原文" : "恢复失败，备份在 \(rtfPath ?? "-")")")
        return (false, true)
    }

    private func pasteViaClipboard(_ text: String, to pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        // 写一个哨兵先：⌘C 没生效时读到的一定是哨兵，而不是上一次的残余。
        // 11:15 两次修正读回同一段 " sen"，很可能就是剪贴板没刷新（哨兵能立刻分辨）。
        let sentinel = "__EW_CB_\(UUID().uuidString)__"
        pb.clearContents()
        pb.setString(sentinel, forType: .string)
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
            emit(CheckEvent(kind: "render", pid: pid, app: appName(pid), role: roleOf(el),
                            textLen: (lastText as NSString).length, sentenceLen: sentenceRange.length,
                            itemCount: items.count, rectCount: overlay.specs.count,
                            elapsed: diag.lastElapsed,
                            err: diag.lastError == "-"
                                ? items.prefix(4).map { "\($0.kind.rawValue):\($0.original)→\($0.replacement)" }.joined(separator: " | ")
                                : diag.lastError,
                            at: Date()))
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
        if !cleaned.isEmpty { lastNonEmptyItems = cleaned }
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
                            hasEditableWebField: Bool, checkReading: Bool = false,
                            inEditableWindow: Bool = false, mailReading: Bool = false,
                            composeWindow: Bool = false) -> Bool {
        // Mail 阅读窗一律不查（除非显式打开了 checkReading）：那里的可编辑节点是搜索框，
        // 不是你在写的东西（爹地 11-23：左栏画线 / 检查别人的邮件）
        if isMailBody && mailReading && !checkReading { return false }
        // 写信窗正文：Mail 的正文没有 AXTextArea（dump：textArea=0，全是 AXStaticText），
        // 所以「有可编辑控件」这条永远不成立。显式传 composeWindow 才是判据——
        // 不能拿 !mailReading 推（那会让「默认参数」的调用把阅读窗误判成写信窗，CI 当场抓到）。
        if isMailBody && composeWindow { return true }
        if editable { return true }
        if isWebBody && hasEditableWebField { return true }
        if isWebBody && inEditableWindow { return true }      // 写信窗口的正文区
        if checkReading && isWebBody && isMailBody { return true }
        return false
    }
}
