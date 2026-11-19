// DemoLive.swift — 「演示…」窗口：不碰任何外部 App，点一下就能看见整套效果
//
// 为什么要有它：爹地在 Mail 里试运气，一等就是半小时，还经常因为宿主读不到文本而「完全没反应」。
// Grammarly 也有 demo 页，这不是偷懒，是把「能不能用」和「宿主兼不兼容」解耦。
//
// 这里的检查走同一条链路：Sentence 切句 → LanguageGate 语言门控 → SpellCheck / StyleRules
// → DiffSanitize 合并 → 下划线上屏 → 点「接受」写回 → ⌘Z 撤销。
// 唯一不同：渲染用 NSTextView 原生属性（自己家的编辑器不需要 AX 覆盖层）。

import AppKit

final class DemoLive: NSObject, NSWindowDelegate, NSTextViewDelegate {

    static let shared = DemoLive()

    private var window: NSWindow?
    var windowRef: NSWindow? { window }
    private var textView: NSTextView!
    private var listBox: NSStackView!
    private var status: NSTextField!
    private var items: [DiffItem] = []
    private var lastScore = WritingScore()
    private var lastScoreText = ""
    private var didAutoOpenSidebar = false
    private var toneText = ""
    private var highlightedRange: NSRange?
    private var checkTask: Task<Void, Never>?
    private var debounce: Timer?

    /// 类别行统一文案（知澜给的固定格式）
    static func categoryLabel(_ type: String) -> String {
        switch type {
        case "spelling": return "正确性 · 修正拼写"
        case "grammar": return "正确性 · 语法问题"
        case "clarity": return "清晰度 · 精简表达"
        default: return "表达 · 调整风格"
        }
    }

    private let sample = """
    There is many reasons why we should sent the booking confirmation to the customer immediatly.

    In order to save time, we must make a decision today. Due to the fact that the vessel was delayed, the customer asked for an update.

    我们有一个 11/27 号的 CMA 舱位，等国外确认后再报给客户。

    Pozdrawiam / Best Regards, Spedytor / Forwarding Agent
    """

    @MainActor
    func show() {
        if let w = window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            scheduleCheck()
            return
        }

        let rect = NSRect(x: 0, y: 0, width: 760, height: 620)
        let w = NSWindow(contentRect: rect,
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "英文写作助手 · 试用"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w

        let root = NSView(frame: rect)

        // 文字区
        let scroll = NSScrollView(frame: NSRect(x: 18, y: 96, width: rect.width - 36, height: rect.height - 120))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = NSColor.separatorColor.cgColor

        // 用子类接住 mouseDown：NSTextView 自己会吃掉点击，gesture 常常不触发
        // （爹地点了半天「没反应」的根因之一）
        let tv = ClickTextView(frame: scroll.bounds)
        tv.isEditable = true
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 15)
        tv.textContainerInset = NSSize(width: 16, height: 16)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.allowsUndo = true
        // 屏幕上只许有一套管方下划线：关掉系统自带的拼写/语法/自动纠正
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.delegate = self
        tv.string = sample
        tv.onClickAt = { [weak self] point in
            Task { @MainActor in self?.handleClick(at: point) }
        }
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.insertionPointColor = .systemBlue
        scroll.documentView = tv
        textView = tv
        root.addSubview(scroll)

        // 状态栏
        let bar = NSView(frame: NSRect(x: 18, y: 54, width: rect.width - 36, height: 30))
        let label = NSTextField(labelWithString: "准备检查…")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 2, y: 6, width: 420, height: 18)
        bar.addSubview(label)
        status = label

        let clearBtn = NSButton(title: "重新载入示例", target: self, action: #selector(refill))
        clearBtn.bezelStyle = .rounded
        clearBtn.frame = NSRect(x: bar.bounds.width - 96, y: 2, width: 96, height: 26)
        bar.addSubview(clearBtn)

        let deepBtn = NSButton(title: "深度检查", target: self, action: #selector(deepCheck))
        deepBtn.bezelStyle = .rounded
        deepBtn.frame = NSRect(x: bar.bounds.width - 348, y: 2, width: 122, height: 26)
        deepBtn.isHidden = !Rewrite.isAvailable() || !SettingsStore.load().isComplete
        if !deepBtn.isHidden { bar.addSubview(deepBtn) }

        let sideBtn = NSButton(title: "打开建议面板", target: self, action: #selector(openSidebar))
        sideBtn.bezelStyle = .rounded
        sideBtn.frame = NSRect(x: bar.bounds.width - 220, y: 2, width: 118, height: 26)
        bar.addSubview(sideBtn)
        root.addSubview(bar)

        // 建议列表
        let listScroll = NSScrollView(frame: NSRect(x: 18, y: 12, width: rect.width - 36, height: 38))
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        let stack = NSStackView(frame: listScroll.bounds)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        listScroll.documentView = stack
        listBox = stack
        root.addSubview(listScroll)

        w.contentView = root
        // --demo-offscreen：窗口放屏幕外跑检查，不抢焦点不起屏（静默取证用）
        if ProcessInfo.processInfo.arguments.contains("--demo-offscreen") {
            w.setFrameOrigin(NSPoint(x: -6000, y: -6000))
            w.orderBack(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        scheduleCheck()
    }

    @MainActor @objc private func openSidebar() {
        let sb = Sidebar.shared
        sb.onAccept = { [weak self] it in
            Task { @MainActor in self?.applyItem(it) }
        }
        sb.onDismiss = { [weak self] it in
            Task { @MainActor in self?.removePaint(for: it) }
        }
        sb.onJump = { [weak self] it in
            Task { @MainActor in self?.focusItem(it) }
        }
        sb.onAcceptAll = { [weak self] in
            Task { @MainActor in self?.acceptAll() }
        }
        sb.present(items: items, score: lastScore, at: nil)
    }

    /// 正文联动：黄底高亮 2 秒 + 滚动到可见 + 把窗口提到前面（Grammarly 点一下就能定位的那一环）
    @MainActor
    func focusItem(_ it: DiffItem) {
        let r = NSRange(location: it.start, length: it.length)
        guard let storage = textView.textStorage, NSMaxRange(r) <= storage.length else { return }
        window?.makeKeyAndOrderFront(nil)
        textView.setSelectedRange(r)
        textView.scrollRangeToVisible(r)
        textView.showFindIndicator(for: r)      // 系统自带的黄色闪示，2 秒自动消失，不污染文本属性

        // 再补一层我们自己的黄底，保证在深色/浅色主题下都看得见；2 秒后撤掉并重画下划线
        storage.beginEditing()
        storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: r)
        storage.endEditing()
        // 高亮挂到「用户处理为止」：切到别的建议 / 接受 / 忽略 / 关侧栏才消失
        // （2 秒闪示实测来不及看，知澜打回：Grammarly 的高亮是挂着的）
        clearHighlight()
        highlightedRange = r
    }

    /// 取证：把悬停卡片摆到第一条建议的正下方（跟真实悬停同一套渲染）
    @MainActor
    func showCardPreview(_ it: DiffItem) {
        let r = NSRange(location: it.start, length: it.length)
        let screen = textView.firstRect(forCharacterRange: r, actualRange: nil)
        let winRect = textView.convert(screen, to: nil)
        guard let win = window else { return }
        let screenRect = win.convertToScreen(winRect)
        var anchor = CGRect(x: screenRect.minX, y: NSScreen.screens[0].frame.height - screenRect.minY,
                            width: max(8, screenRect.width), height: max(8, screenRect.height))
        anchor.origin.y += anchor.height
        let kind: UnderlineKind = it.type == "spelling" ? .spelling : (it.type == "grammar" ? .grammar : (it.type == "clarity" ? .clarity : .style))
        HoverCoordinator.shared.previewCard(kind: kind, sentence: textView.string, errorRange: r,
                                            original: it.original, replacement: it.replacement,
                                            anchor: anchor) { [weak self] in
            Task { @MainActor in self?.applyItem(it) }
        }
    }

    @MainActor
    private func clearHighlight() {
        guard let r = highlightedRange, let storage = textView.textStorage, NSMaxRange(r) <= storage.length else {
            highlightedRange = nil
            return
        }
        storage.beginEditing()
        storage.removeAttribute(.backgroundColor, range: r)
        storage.endEditing()
        highlightedRange = nil
        paint(items)
    }

    /// 全部接受：offset 一次性算好，**从大到小**反向应用（前面改了会把后面的偏移顶走）
    @MainActor
    func acceptAll() {
        let target = items.sorted { $0.start > $1.start }
        guard !target.isEmpty else { return }
        textView.undoManager?.beginUndoGrouping()
        var applied = 0
        for it in target {
            let r = NSRange(location: it.start, length: it.length)
            guard NSMaxRange(r) <= textView.string.utf16.count else { continue }
            let repl = it.replacementRespectingSentenceCase(in: textView.string)
            if textView.shouldChangeText(in: r, replacementString: repl) {
                textView.replaceCharacters(in: r, with: repl)
                textView.didChangeText()
                applied += 1
            }
        }
        textView.undoManager?.endUndoGrouping()
        clearHighlight()
        if applied > 0 { Toast.show("已改 \(applied) 处 · ⌘Z 撤销") }
        scheduleCheck()
    }

    @MainActor
    private func applyItem(_ it: DiffItem) {
        let r = NSRange(location: it.start, length: it.length)
        guard let storage = textView.textStorage, NSMaxRange(r) <= storage.length else { return }
        if textView.shouldChangeText(in: r, replacementString: it.replacement) {
            textView.replaceCharacters(in: r, with: it.replacement)
            textView.didChangeText()
        }
        scheduleCheck()
    }

    /// 忽略一条：只去掉这条的下划线，不改文本
    @MainActor
    private func removePaint(for it: DiffItem) {
        clearHighlight()
        guard let storage = textView.textStorage else { return }
        let r = NSRange(location: it.start, length: it.length)
        guard NSMaxRange(r) <= storage.length else { return }
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: r)
        storage.removeAttribute(.underlineColor, range: r)
        storage.endEditing()
    }

    /// 深度检查：把当前全文丢给模型（语法/清晰度/风格四类），5–8 秒回来并合并到现有建议
    @MainActor @objc private func deepCheck() {
        let text = textView.string
        let cfg = SettingsStore.load()
        guard cfg.isComplete else { status.stringValue = "模型三项没填，深度检查不可用"; return }
        status.stringValue = "模型检查中…（约 5–8 秒）"
        Task { @MainActor in
            let t0 = Date()
            do {
                let out = try await InlineEngine.review(text: text, config: cfg, timeout: 90)
                let merged = DiffSanitize.consolidate(
                    SpellCheck.items(in: text) + StyleRules.apply(to: text) + out.items, in: text)
                self.items = merged
                self.paint(merged)
                self.renderList(merged)
                self.lastScore = Scorer.score(text: text, items: merged, formality: nil)
                self.lastScoreText = text
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                let fast = CategoryPrefs.fastMode()
                let reasoning = fast ? "none" : "默认"
                self.status.stringValue = "\(merged.count) 条建议（模型 \(out.items.count) 条）· \(ms)ms · reasoning=\(reasoning)"
                if Sidebar.shared.isVisible { Sidebar.shared.present(items: merged, score: self.lastScore, at: nil) }
            } catch {
                self.status.stringValue = "模型检查失败：\(error)"
            }
        }
    }

    @MainActor @objc private func refill() {
        textView.string = sample
        scheduleCheck()
    }

    // MARK: 输入 → 去抖 → 检查

    func textDidChange(_ notification: Notification) {
        scheduleCheck()
    }

    /// 点正文里的词 → 侧栏对应卡片展开并高亮（双向联动的另一半）
    @MainActor
    private func handleClick(at p: NSPoint) {
        guard let tv = textView else { return }
        let idx = tv.characterIndexForInsertion(at: p)
        let hit = items.first(where: { idx >= $0.start && idx < $0.start + max(1, $0.length) })
        let hitIdx = hit.flatMap { h in items.firstIndex(where: { (it: DiffItem) -> Bool in it.start == h.start }) }
        CheckLog.append(.init(kind: hit == nil ? "click-miss" : "click-hit",
                              pid: ProcessInfo.processInfo.processIdentifier,
                              app: "英文写作助手", role: "NSTextView",
                              textLen: (textView.string as NSString).length, sentenceLen: 0,
                              itemCount: hitIdx ?? -1,
                              rectCount: items.count, elapsed: "-", err: "-", at: Date()))
        guard let hit else { return }
        Sidebar.shared.select(start: hit.start)
        focusItem(hit)
        showCardPreview(hit)
    }

    private func scheduleCheck() {
        debounce?.invalidate()
        debounce = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.runCheck() }
        }
    }

    @MainActor
    private func runCheck() {
        let text = textView.string
        guard !text.isEmpty else { items = []; paint([]); renderList([]); return }
        let t0 = Date()
        checkTask?.cancel()
        checkTask = Task { @MainActor in
            final class Counter { var langSkipped = 0 }
            let counter = Counter()
            let res = await DocScan.scan(text) { sentence in
                // 语言门控：中文/波兰语/德语…一个字都不查（实案：一封波兰语邮件曾被报 410 条）
                guard LanguageGate.isEnglish(sentence) else { counter.langSkipped += 1; return [] }
                return DiffSanitize.consolidate(
                    SpellCheck.items(in: sentence) + StyleRules.apply(to: sentence), in: sentence)
            }
            if Task.isCancelled { return }
            let items = res.items
            self.items = items
            self.paint(items)
            self.renderList(items)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            // 评分（P2 纯本地）
            self.lastScore = Scorer.score(text: text, items: items, formality: GoalsStore.load().formality)
            self.lastScoreText = text
            // 把每条建议的屏幕矩形登记给 overlay：点击命中测试与卡片用的就是这一份
            var hitSpecs: [UnderlineSpec] = []
            for (i, it) in items.enumerated() {
                let r = NSRange(location: it.start, length: it.length)
                guard let win = self.window else { break }
                let inView = self.textView.firstRect(forCharacterRange: r, actualRange: nil)
                if inView.isEmpty { continue }
                let inWin = self.textView.convert(inView, to: nil)
                let scr = win.convertToScreen(inWin)
                let q = CGRect(x: scr.minX, y: (NSScreen.screens.first?.frame.height ?? 900) - scr.maxY,
                               width: max(4, scr.width), height: max(8, scr.height))
                let kind: UnderlineKind = it.type == "spelling" ? .spelling
                    : (it.type == "grammar" ? .grammar : (it.type == "clarity" ? .clarity : .style))
                hitSpecs.append(UnderlineSpec(rect: q, kind: kind, itemID: i))
            }
            InlineController.shared.overlay.adoptSpecsForHitTest(hitSpecs)

            CheckLog.append(.init(kind: "demo-check",
                                  pid: ProcessInfo.processInfo.processIdentifier,
                                  app: "英文写作助手", role: "NSTextView",
                                  textLen: (text as NSString).length, sentenceLen: res.sentenceCount,
                                  itemCount: items.count, rectCount: hitSpecs.count,
                                  elapsed: "\(Int(Date().timeIntervalSince(t0) * 1000))ms",
                                  err: "-", at: Date()))
            let langSkipped = res.skippedCJK + counter.langSkipped
            if ProcessInfo.processInfo.arguments.contains("--card-demo"), !self.didAutoOpenSidebar, !items.isEmpty {
                self.didAutoOpenSidebar = true
                self.showCardPreview(items[0])
            }
            if ProcessInfo.processInfo.arguments.contains("--jump-demo"), !self.didAutoOpenSidebar, !items.isEmpty {
                self.didAutoOpenSidebar = true
                self.openSidebar()
                self.focusItem(items[0])
            }
            if ProcessInfo.processInfo.arguments.contains("--accept-all-demo"), !self.didAutoOpenSidebar, !items.isEmpty {
                self.didAutoOpenSidebar = true
                self.acceptAll()
            }
            if ProcessInfo.processInfo.arguments.contains("--deep"), !self.didAutoOpenSidebar {
                self.didAutoOpenSidebar = true
                self.deepCheck()
            }
            if ProcessInfo.processInfo.arguments.contains("--sidebar-open"), !self.didAutoOpenSidebar, !items.isEmpty {
                self.didAutoOpenSidebar = true
                self.openSidebar()
            }
            // 语气（P3）：≥150 字符才判；模型优先、失败回落本地，出结果才更新，绝不阻塞
            if (text as NSString).length >= Tone.minChars {
                Task { @MainActor in
                    if let t = await Tone.detect(text, config: SettingsStore.load()) {
                        Sidebar.shared.setTone("\(t.primary)（次要 \(t.secondary)，\(t.source == "model" ? "模型" : "本地")）")
                        self.toneText = "\(t.primary) / \(t.secondary)"
                    }
                }
            } else {
                Sidebar.shared.setTone("文本太短（<150 字符），暂不判断")
            }
            self.status.stringValue = "\(items.count) 条建议 · \(res.sentenceCount) 句 / 跳过非英文 \(langSkipped) 句 · \(ms)ms · 语言门控开"
        }
    }

    // MARK: 渲染（原生属性，等价于外部 App 的覆盖层下划线）

    @MainActor
    private func paint(_ items: [DiffItem]) {
        guard let storage = textView.textStorage else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: full)
        storage.removeAttribute(.underlineColor, range: full)
        for it in items {
            let r = NSRange(location: it.start, length: it.length)
            guard NSMaxRange(r) <= storage.length else { continue }
            let style = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
            storage.addAttribute(.underlineStyle, value: style, range: r)
            storage.addAttribute(.underlineColor, value: color(for: it.type), range: r)
        }
        storage.endEditing()
    }

    private func color(for type: String) -> NSColor {
        switch type {
        case "spelling": return .systemRed
        case "grammar": return .systemOrange
        case "clarity": return .systemBlue
        default: return .systemPurple
        }
    }

    @MainActor
    private func renderList(_ items: [DiffItem]) {
        for v in listBox.arrangedSubviews { listBox.removeArrangedSubview(v); v.removeFromSuperview() }
        if items.isEmpty {
            let l = NSTextField(labelWithString: "没有建议（示例里的中文与波兰语已被语言门控跳过，这是对的）")
            l.font = NSFont.systemFont(ofSize: 11)
            l.textColor = .tertiaryLabelColor
            listBox.addArrangedSubview(l)
            return
        }
        for (i, it) in items.prefix(8).enumerated() {
            let btn = NSButton(title: "\(it.original) → \(it.replacement)", target: self, action: #selector(acceptRow(_:)))
            btn.tag = i
            btn.bezelStyle = .rounded
            btn.font = NSFont.systemFont(ofSize: 11)
            listBox.addArrangedSubview(btn)
        }
    }

    @MainActor @objc private func acceptRow(_ sender: NSButton) {
        guard sender.tag < items.count else { return }
        let it = items[sender.tag]
        let r = NSRange(location: it.start, length: it.length)
        guard let storage = textView.textStorage, NSMaxRange(r) <= storage.length else { return }
        let repl = it.replacementRespectingSentenceCase(in: textView.string)
        if textView.shouldChangeText(in: r, replacementString: repl) {
            textView.replaceCharacters(in: r, with: repl)
            textView.didChangeText()      // 注册撤销，⌘Z 可回退
            Toast.show("已改 1 处 · ⌘Z 撤销")
        }
        clearHighlight()
        scheduleCheck()
    }

    func windowWillClose(_ n: Notification) {
        Sidebar.shared.orderOut(nil)
        window = nil
    }
}

/// 点击能直接拿到坐标的 NSTextView（gesture 会被文本视图吞掉，用子类最稳）
final class ClickTextView: NSTextView {
    var onClickAt: ((NSPoint) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onClickAt?(p)
        super.mouseDown(with: event)
    }
}
