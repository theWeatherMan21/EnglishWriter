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
    private var textView: NSTextView!
    private var listBox: NSStackView!
    private var status: NSTextField!
    private var items: [DiffItem] = []
    private var checkTask: Task<Void, Never>?
    private var debounce: Timer?

    private let sample = """
    There is many reasons why we should sent the booking confirmation to the customer immediatly.

    In order to save time, we must make a decision today. Due to the fact that the vessel was delayed, the customer asked for an update.

    这段是中文：我们有一个 11/27 号的 CMA 舱位，等国外确认。

    Pozdrawiam / Best Regards, Spedytor / Forwarding Agent
    Agencji Celnych ostatnie zmiany danych oraz Terramar
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
        w.title = "英文写作助手 · 演示（随便改，改完看线）"
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

        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = true
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: 15)
        tv.textContainerInset = NSSize(width: 16, height: 16)
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.allowsUndo = true
        tv.delegate = self
        tv.string = sample
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

        let clearBtn = NSButton(title: "重填示例", target: self, action: #selector(refill))
        clearBtn.bezelStyle = .rounded
        clearBtn.frame = NSRect(x: bar.bounds.width - 96, y: 2, width: 96, height: 26)
        bar.addSubview(clearBtn)
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
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        scheduleCheck()
    }

    @objc private func refill() {
        textView.string = sample
        scheduleCheck()
    }

    // MARK: 输入 → 去抖 → 检查

    func textDidChange(_ notification: Notification) {
        scheduleCheck()
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
            let langSkipped = res.skippedCJK + counter.langSkipped
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

    @objc private func acceptRow(_ sender: NSButton) {
        guard sender.tag < items.count else { return }
        let it = items[sender.tag]
        let r = NSRange(location: it.start, length: it.length)
        guard let storage = textView.textStorage, NSMaxRange(r) <= storage.length else { return }
        if textView.shouldChangeText(in: r, replacementString: it.replacement) {
            textView.replaceCharacters(in: r, with: it.replacement)
            textView.didChangeText()      // 注册撤销，⌘Z 可回退
        }
        scheduleCheck()
    }

    func windowWillClose(_ n: Notification) {
        window = nil
    }
}
