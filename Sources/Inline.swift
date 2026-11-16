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

    struct InlineDiag: CustomStringConvertible {
        var checks = 0
        var requests = 0
        var skippedChinese = 0
        var dedupedHits = 0
        var lastError = "-"
        var lastElapsed = "-"
        var lastRectCount = 0
        var description: String {
            "checks=\(checks) requests=\(requests) cjkSkip=\(skippedChinese) dedupe=\(dedupedHits) rects=\(lastRectCount) elapsed=\(lastElapsed) err=\(lastError)"
        }
    }

    // MARK: 生命周期

    func start() {
        guard focusObserver == nil else { return }
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
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastFocusPid = front.processIdentifier
            attachObserver(pid: front.processIdentifier)
        }
    }

    func stop() {
        detachObserver()
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
        attachElementObserver(pid: pid)
    }

    private func attachElementObserver(pid: pid_t) {
        guard let observer, let el = AXInline.focusedElement(pid: pid) else { return }
        if let old = observedElement, CFEqual(old, el) { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            AXObserverAddNotification(observer, el, n as CFString, refcon)
        }
        observedElement = el
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

    func checkNow() {
        guard enabled else { return }
        guard AXPermission.granted() else { diag.lastError = "无辅助功能权限"; return }
        let pid = lastFocusPid
        guard pid > 0 else { return }
        guard let el = AXInline.focusedElement(pid: pid) else { diag.lastError = "没有焦点文本框"; return }
        guard let full = AXInline.fullText(of: el) else { diag.lastError = "读不到文本框内容"; return }

        let caret = AXInline.selectedRange(el)?.location ?? (full as NSString).length
        let sentenceRange = Sentence.around(caret: caret, in: full)
        let sentence = Sentence.text(sentenceRange, in: full)
        guard sentence.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 else {
            overlay.clear(); items = []; return
        }
        // 语言门控：中文占比超阈值 → 一个请求都不发
        if shouldSkipAsChinese(sentence) {
            diag.skippedChinese += 1
            overlay.clear(); items = []
            return
        }
        // 同文本不重复请求
        let hash = "\(pid):\(sentence.hashValue)"
        if lastHash[pid] == hash { diag.dedupedHits += 1; return }
        lastHash[pid] = hash

        diag.checks += 1
        lastText = full

        let cfg = SettingsStore.load()

        // 引擎选择：本地 LanguageTool 在线就优先用它（毫秒级、零成本、不出网）；
        // 不可用且用户填了模型三件套 → 走 OpenAI 兼容逐条 diff；两者都没有 → Mock（自测路径）
        Task { [weak self] in
            let ltOK = await LocalEngine.available()
            if ltOK {
                do {
                    let out = try await LocalEngine.review(text: sentence, language: "en-GB")
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
                await MainActor.run {
                    guard let self else { return }
                    self.diag.lastElapsed = String(format: "%.2fs", out.elapsed)
                    self.diag.lastError = "-"
                    self.apply(items: self.shift(out.items, by: sentenceRange.location),
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

    // MARK: 渲染

    private func apply(items newItems: [DiffItem], sentenceRange: NSRange, element el: AXUIElement, pid: pid_t) {
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
        diag.lastRectCount = specs.count
        guard !specs.isEmpty else { diag.lastError = "算不出屏幕矩形"; return }
        overlay.render(specs)
        overlayPid = pid
        printRects(specs, items: cleaned)
    }

    func clearUnderlines() { overlay.clear(); items = [] }

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
