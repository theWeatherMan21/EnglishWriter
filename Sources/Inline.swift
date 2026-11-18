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
    private var pending: DispatchWorkItem?
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
    }
    /// 外部注册的观察者（--passive 用）。默认 nil = 零开销。
    var onCheck: ((CheckEvent) -> Void)?

    private func emit(_ e: CheckEvent) {
        onCheck?(e)
        CheckLog.append(e)      // 常驻落盘：爹地「打了没反应」时，我能拿事实说话
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
        var engineChoice = "语法：未定"
        var description: String {
            "checks=\(checks) requests=\(requests) cjkSkip=\(skippedChinese) dedupe=\(dedupedHits) fallback=\(fallbackTextArea) rects=\(lastRectCount) elapsed=\(lastElapsed) err=\(lastError) | \(engineChoice)"
        }
    }

    // MARK: 生命周期

    func start() {
        guard focusObserver == nil else { return }
        HoverCoordinator.shared.start()      // 悬停卡片（全局 mouseMoved + 300ms 停留）
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.lastFocusPid = app.processIdentifier
                self?.attachObserver(pid: app.processIdentifier)
            }
        }
        startPolling()
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
        guard pid > 0, let el = AXInline.focusedElement(pid: pid) ?? AXInline.biggestTextArea(pid: pid),
              let full = AXInline.fullText(of: el) else { return nil }
        let sel = AXInline.selectedRange(el) ?? currentSentenceRange
        let ns = full as NSString
        let clamped = NSRange(location: min(sel.location, ns.length),
                              length: min(sel.length, max(0, ns.length - min(sel.location, ns.length))))
        guard clamped.length > 0 else { return nil }
        currentElement = el
        currentPid = pid
        return (el, pid, full, clamped)
    }

    /// 改写建议：把候选的逐条 diff 当作本次条目（不刷新 UI、不重查）
    func adoptForRewrite(_ newItems: [DiffItem]) {
        items = newItems
        itemBlock = newItems.map { _ in -1 }
    }

    /// 改写建议：留一个「整段」撤销快照，回滚仍走 undoLastAccept()
    func setUndoSnapshot(_ item: DiffItem, element: AXUIElement?) {
        lastAccept = (item, -1, element)
    }

    /// 轮询兜底：布局/焦点通知会丢（知洲 11-18 指出的 Grammarly 行为：每秒轮一次）。
    /// 只读文本比对，不直接调引擎；文本变了才走正常去抖检查。
    private var pollTimer: Timer?
    private func startPolling() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.lastFocusPid > 0 else { return }
                guard let el = AXInline.focusedElement(pid: self.lastFocusPid) ?? AXInline.biggestTextArea(pid: self.lastFocusPid),
                      let t = AXInline.fullText(of: el) else { return }
                if t != self.lastText { self.scheduleCheck(delay: 0.2) }
            }
        }
    }

    /// 被动/验收模式用：onCheck 装好之后再补挂一次前台 App
    /// （start() 早于 onCheck 赋值，否则「启动时前台已是你正在打字的 App」这类情况会一条事件都不发）
    func reattachFrontmost() {
        guard enabled, AXPermission.granted() else { return }
        startPolling()
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

    private func attachObserver(pid: pid_t) {
        guard pid > 0, AXPermission.granted() else { return }
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
        emit(CheckEvent(kind: "attach-app", pid: pid, app: appName(pid), role: "-", textLen: 0, sentenceLen: 0,
                        itemCount: 0, rectCount: 0, elapsed: "-", err: "-", at: Date()))
        attachElementObserver(pid: pid)
    }

    private func attachElementObserver(pid: pid_t) {
        guard let observer else { return }
        // 焦点可能落在窗口/工具栏（AXWindow）上而不是文本区：那样 valueChanged 永远不会来。
        // 真机实测（TextEdit）：刚激活时 focusedElement 就是 AXWindow → 必须改挂窗口里最大的可读 AXTextArea。
        if var cand = AXInline.focusedElement(pid: pid) {
            let role = attrString(cand, kAXRoleAttribute as String) ?? ""
            if role != "AXTextArea" && role != "AXTextField" && role != "AXWebArea" {
                if let better = AXInline.biggestTextArea(pid: pid) { cand = better }
            }
            let refcon2 = Unmanaged.passUnretained(self).toOpaque()
            if let old = observedElement, CFEqual(old, cand) { return }
            for n in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
                AXObserverAddNotification(observer, cand, n as CFString, refcon2)
            }
            observedElement = cand
            emit(CheckEvent(kind: "attach-el", pid: pid, app: appName(pid),
                            role: attrString(cand, kAXRoleAttribute as String) ?? "?", textLen: 0, sentenceLen: 0,
                            itemCount: 0, rectCount: 0, elapsed: "-", err: "-", at: Date()))
            return
        }
        guard let el = AXInline.focusedElement(pid: pid) else {
            emit(CheckEvent(kind: "attach-el-fail", pid: pid, app: appName(pid), role: "-", textLen: 0,
                            sentenceLen: 0, itemCount: 0, rectCount: 0, elapsed: "-", err: "没有焦点元素", at: Date()))
            return
        }
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
        if EnginePrefs.isExcluded(bundleId: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                                  appName: appName(pid)) {
            emit(CheckEvent(kind: "skip-excluded", pid: pid, app: appName(pid), role: "",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                            elapsed: "-", err: "-", at: Date()))
            return
        }
        guard var el = explicit ?? AXInline.focusedElement(pid: pid) else { diag.lastError = "没有焦点文本框"; return }
        var full = AXInline.fullText(of: el)
        if full == nil {
            // 焦点落在窗口/工具栏上时读到空：改取该 App 前台窗口里最大的可读 AXTextArea，别白丢这次检查
            if let alt = AXInline.biggestTextArea(pid: pid), let f2 = AXInline.fullText(of: alt) {
                el = alt
                full = f2
                diag.fallbackTextArea += 1
            }
        }
        if full == nil {
            emit(CheckEvent(kind: "no-text", pid: pid, app: appName(pid), role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0, elapsed: "-",
                            err: "读不到文本框内容", at: Date()))
        }
        guard let full else { diag.lastError = "读不到文本框内容"; return }
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
        // 语言门控：中文占比超阈值 → 一个请求都不发
        if shouldSkipAsChinese(sentence) {
            diag.skippedChinese += 1
            emit(CheckEvent(kind: "skip-cjk", pid: pid, app: appName(pid), role: attrString(el, kAXRoleAttribute as String) ?? "",
                            textLen: (full as NSString).length, sentenceLen: (sentence as NSString).length,
                            itemCount: 0, rectCount: 0, elapsed: "-", err: "-", at: Date()))
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
        let instant = DiffSanitize.consolidate(SpellCheck.items(in: sentence) + StyleRules.apply(to: sentence), in: sentence)
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
                let out = try await InlineEngine.review(text: sentence, config: cfg)
                let mergedModel = DiffSanitize.consolidate(out.items + instant, in: sentence)
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

    private func checkWeb(pid: pid_t, body: AXUIElement) {
        let blks = WebText.blocks(of: body)
        guard !blks.isEmpty else {
            diag.lastError = "Web 正文里没有可读文本块"
            overlay.clear(); items = []; blocks = []; itemBlock = []
            return
        }
        blocks = blks
        lastText = blks.map(\.text).joined(separator: "\n")
        diag.checks += 1

        let sigMarkers = SpanGuard.signatureMarkers
        Task { [weak self] in
            guard let self else { return }
            let ltOK = await LocalEngine.available()
            if !ltOK { LocalEngineBootstrap.ensureRunningThrottled() }   // 闲置退出后按需拉回（节流 120s）
            var all: [DiffItem] = []
            var map: [Int] = []
            var firstError: String?
            for (bi, b) in blks.enumerated() {
                let t = b.text
                guard t.trimmingCharacters(in: .whitespacesAndNewlines).count >= 4 else { continue }
                if shouldSkipAsChinese(t) { continue }
                // 整块就是签名行 → 不检查
                let lowered = t.lowercased()
                if sigMarkers.contains(where: { lowered.hasPrefix($0.lowercased()) }) { continue }
                guard ltOK else { firstError = "本地引擎未启动"; continue }
                do {
                    let out = try await LocalEngine.review(text: t, language: EnginePrefs.language())
                    let t0 = Date()
                    await MainActor.run {
                        self.diag.lastElapsed = String(format: "%.0fms", Date().timeIntervalSince(t0) * 1000)
                    }
                    for it in out.items { all.append(it); map.append(bi) }
                } catch {
                    firstError = "LT: \(error)"
                }
            }
            await MainActor.run {
                if let e = firstError { self.diag.lastError = e } else { self.diag.lastError = "-" }
                self.applyWeb(items: all, blockMap: map, blocks: blks, pid: pid)
            }
        }
    }

    private func applyWeb(items newItems: [DiffItem], blockMap: [Int], blocks blks: [WebText.Block], pid: pid_t) {
        var kept: [DiffItem] = []
        var keptMap: [Int] = []
        var specs: [UnderlineSpec] = []
        for (i, it) in newItems.enumerated() where i < blockMap.count {
            let bi = blockMap[i]
            guard bi < blks.count else { continue }
            let b = blks[bi]
            let ns = b.text as NSString
            guard it.length > 0, it.start >= 0, it.start + it.length <= ns.length else { continue }
            guard ns.substring(with: it.utf16Range) == it.original else { continue }   // 偏移对不上一律不画
            if IgnoreStore.shared.isIgnored(original: it.original, replacement: it.replacement) { continue }
            let rects = WebText.lineRects(for: it.utf16Range, in: b)
            guard !rects.isEmpty else { continue }
            let id = kept.count
            kept.append(it)
            keptMap.append(bi)
            for r in rects { specs.append(UnderlineSpec(rect: r, kind: it.kind, itemID: id)) }
        }
        items = kept
        itemBlock = keptMap
        diag.lastRectCount = specs.count
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

    private var lastAccept: (item: DiffItem, blockIndex: Int, element: AXUIElement?)?

    /// 接受一条：只替换这一处，保留撤销栈（AXSelectedText 写入选区）
    @discardableResult
    func accept(itemID id: Int) -> Bool {
        guard id >= 0, id < items.count else { return false }
        let it = items[id]
        let bi = itemBlock.indices.contains(id) ? itemBlock[id] : -1
        var ok = false
        if bi >= 0, bi < blocks.count {
            ok = WebText.replace(range: it.utf16Range, with: it.replacement, in: blocks[bi])
            if ok { lastAccept = (it, bi, nil) }
        } else if let el = currentElement, let v = axRangeValue(it.start, it.length) {
            _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
            Audit.write("Inline.accept")
            ok = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, it.replacement as CFTypeRef) == .success
            if ok { lastAccept = (it, -1, el) }
            // Chromium 网页字段：AXValue 与 AXSelectedText 实测都写不进（2026-11-16 探测），
            // 剪贴板 ⌘V 兜底 —— 只在 AX 写失败时走，原生 AppKit 路径行为不变。
            if !ok {
                _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
                if pasteViaClipboard(it.replacement, to: currentPid) {
                    usleep(450_000)
                    if (attrString(el, kAXValueAttribute as String) ?? "").contains(it.replacement) {
                        ok = true
                        lastAccept = (it, -1, el)
                        Diag.shared.applyMethod = "剪贴板 ⌘V 兜底"
                    }
                }
            }
        }
        diag.lastError = ok ? "已接受：\(it.original) → \(it.replacement)" : "写回失败：这个输入框不接受 AX 写入"
        if ok, Diag.shared.applyMethod != "剪贴板 ⌘V 兜底" { Diag.shared.applyMethod = "AX 写回" }
        refresh()
        return ok
    }

    /// 撤销上一条接受：把 replacement 换回 original
    @discardableResult
    func undoLastAccept() -> Bool {
        guard let last = lastAccept else { return false }
        let replLen = (last.item.replacement as NSString).length
        var ok = false
        if last.blockIndex >= 0, last.blockIndex < blocks.count {
            ok = WebText.replace(range: NSRange(location: last.item.start, length: replLen),
                                 with: last.item.original, in: blocks[last.blockIndex])
        } else if let el = last.element, let v = axRangeValue(last.item.start, replLen) {
            _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
            Audit.write("Inline.undo")
            ok = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, last.item.original as CFTypeRef) == .success
            if !ok {     // Chromium 兜底：剪贴板 ⌘V
                _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
                if pasteViaClipboard(last.item.original, to: currentPid) {
                    usleep(450_000)
                    ok = (attrString(el, kAXValueAttribute as String) ?? "").contains(last.item.original)
                }
            }
        }
        if ok {
            lastAccept = nil
            Diag.shared.undoCount += 1
            diag.lastError = "已撤销：\(last.item.replacement) → \(last.item.original)"
        } else {
            diag.lastError = "撤销失败"
        }
        refresh()
        return ok
    }

    /// 忽略这一条：同「原词→建议」以后不再提示
    func ignore(itemID id: Int) {
        guard id >= 0, id < items.count else { return }
        let it = items[id]
        IgnoreStore.shared.ignore(original: it.original, replacement: it.replacement)
        diag.lastError = "已忽略：\(it.original) → \(it.replacement)"
        refresh()
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
        guard !cleaned.isEmpty else {
            overlay.clear(); items = []
            diag.lastRectCount = 0
            return
        }
        var specs: [UnderlineSpec] = []
        for (idx, it) in cleaned.enumerated() {
            let rects = AXInline.lineRects(for: it.utf16Range, in: el)
            for r in rects {
                specs.append(UnderlineSpec(rect: r, kind: it.kind, itemID: idx))
            }
        }
        items = cleaned
        itemBlock = Array(repeating: -1, count: cleaned.count)
        diag.lastRectCount = specs.count
        guard !specs.isEmpty else { diag.lastError = "算不出屏幕矩形"; return }
        overlay.render(specs)
        overlayPid = pid
        printRects(specs, items: cleaned)
    }

    func clearUnderlines() {
        HoverCoordinator.shared.dismissCard()
        overlay.clear()
        items = []
        FloatBall.shared.hide()
    }

    /// 浮动球：无问题绿点 / N 条环+数字（Grammarly 那个「我在盯着」的信号）
    private func updateFloatBall(items: [DiffItem], specs: [UnderlineSpec], element el: AXUIElement, pid: pid_t) {
        guard !UnderlineOverlay.globallySilent else { return }   // 被动模式一个像素都不上
        let box = specs.isEmpty ? elementRectQuartz(el)
                                : specs.reduce(CGRect.null) { $0.union($1.rect) }
        guard !box.isNull, box.width > 0 else { FloatBall.shared.hide(); return }
        let worst = items.map { CategoryPrefsSeverity($0.kind) }.max() ?? 0
        let sev: UnderlineKind = items.first(where: { CategoryPrefsSeverity($0.kind) == worst })?.kind ?? .grammar
        FloatBall.shared.update(.init(count: specs.count, severity: sev, pid: pid, anchor: box))
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
