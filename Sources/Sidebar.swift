// Sidebar.swift — P1 侧栏：把「只有线」变成「有面」
//
// Grammarly 的观感来自这个浮窗：总分圆环 + 四维评分 + 分组建议列表 + Accept/Dismiss。
// 只有下划线 + 一条卡片，永远像半成品。
//
// 规格（卡上定的）：
//   · 宽 360pt，高按内容自适应，最大 70% 屏高，可拖动
//   · 总分圆环（0-100）+ 四维（Correctness / Clarity / Engagement / Delivery）各带一句话说明
//   · 建议按 spelling → grammar → clarity → style 分组，组标题带条数
//   · 每条：类别色点 + 原文（删除线红）+ 建议（绿）+ 接受 / 忽略
//   · 点某条 → 文本定位并滚动到可见
//   · 顶部两档筛选：重要建议 / 全部建议
//   · 底部语气预测位（P3 未接时显示「—」）

import AppKit

final class Sidebar: NSPanel {

    static let shared = Sidebar()

    var onAccept: ((DiffItem) -> Void)?
    var onDismiss: ((DiffItem) -> Void)?
    var onJump: ((DiffItem) -> Void)?

    private var items: [DiffItem] = []
    private var dismissed = Set<String>()
    private var score = WritingScore()
    private var importantOnly = true

    private let ring = ScoreRing(frame: .zero)
    private let bigScore = NSTextField(labelWithString: "—")
    private let dimsBox = NSStackView()
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private let toneLabel = NSTextField(labelWithString: "语气：—（P3 未接）")
    private let filter = NSSegmentedControl(labels: ["重要建议", "全部建议"], trackingMode: .selectOne, target: nil, action: nil)

    private let width: CGFloat = 360

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 360, height: 520),
                   styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        buildUI()
    }

    override var canBecomeKey: Bool { true }

    private func buildUI() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 520))
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let title = NSTextField(labelWithString: "写作检查")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.frame = NSRect(x: 18, y: 484, width: 200, height: 18)
        root.addSubview(title)

        // 总分圆环
        ring.frame = NSRect(x: 18, y: 396, width: 84, height: 84)
        root.addSubview(ring)
        bigScore.font = NSFont.monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        bigScore.alignment = .center
        bigScore.frame = NSRect(x: 18, y: 424, width: 84, height: 30)
        root.addSubview(bigScore)

        // 四维
        dimsBox.orientation = .vertical
        dimsBox.alignment = .leading
        dimsBox.spacing = 4
        dimsBox.frame = NSRect(x: 116, y: 386, width: 226, height: 96)
        root.addSubview(dimsBox)

        // 筛选
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.selectedSegment = 0
        filter.frame = NSRect(x: 18, y: 348, width: 200, height: 24)
        root.addSubview(filter)

        // 列表
        listScroll.frame = NSRect(x: 12, y: 44, width: width - 24, height: 296)
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false
        listScroll.borderType = .noBorder
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 6
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let clip = FlippedView()
        clip.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.topAnchor.constraint(equalTo: clip.topAnchor, constant: 2),
            listStack.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: clip.trailingAnchor, constant: -8),
        ])
        listScroll.documentView = clip
        root.addSubview(listScroll)

        // 底部语气
        toneLabel.font = NSFont.systemFont(ofSize: 11)
        toneLabel.textColor = .tertiaryLabelColor
        toneLabel.frame = NSRect(x: 18, y: 16, width: width - 36, height: 16)
        root.addSubview(toneLabel)

        contentView = root
    }

    // MARK: 对外接口

    func present(items: [DiffItem], score: WritingScore, at point: NSPoint? = nil) {
        self.items = items
        self.score = score
        dismissed.removeAll()
        render()
        sizeToFit()
        if let p = point {
            var origin = NSPoint(x: p.x - width / 2, y: p.y - 40)
            let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            origin.x = max(screen.minX + 8, min(origin.x, screen.maxX - width - 8))
            origin.y = max(screen.minY + 8, min(origin.y, screen.maxY - frame.height - 8))
            setFrameOrigin(origin)
        } else if !isVisible {
            let screen = NSScreen.screens.first?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            setFrameOrigin(NSPoint(x: screen.maxX - width - 24, y: screen.midY - frame.height / 2))
        }
        orderFrontRegardless()
    }

    private func sizeToFit() {
        let maxH = (NSScreen.screens.first?.visibleFrame.height ?? 900) * 0.7
        let contentH = CGFloat(44 + 300 + 60)
        let h = min(maxH, contentH)
        setContentSize(NSSize(width: width, height: h))
        listScroll.frame = NSRect(x: 12, y: 44, width: width - 24, height: h - 44 - 300 + 250)
        ring.frame = NSRect(x: 18, y: h - 124, width: 84, height: 84)
        bigScore.frame = NSRect(x: 18, y: h - 96, width: 84, height: 30)
        dimsBox.frame = NSRect(x: 116, y: h - 134, width: 226, height: 96)
        filter.frame = NSRect(x: 18, y: h - 172, width: 200, height: 24)
        listScroll.frame = NSRect(x: 12, y: 44, width: width - 24, height: h - 172 - 34)
        toneLabel.frame = NSRect(x: 18, y: 16, width: width - 36, height: 16)
        if let root = contentView {
            for v in root.subviews where v !== listScroll && v !== toneLabel { _ = v }
        }
    }

    // MARK: 渲染

    @objc private func filterChanged() {
        importantOnly = filter.selectedSegment == 0
        render()
    }

    private func visibleItems() -> [DiffItem] {
        let live = items.filter { !dismissed.contains(key($0)) }
        guard importantOnly else { return live }
        return live.filter { $0.type == "spelling" || $0.type == "grammar" || $0.type == "clarity" }
    }

    private func key(_ it: DiffItem) -> String { "\(it.start)-\(it.length)-\(it.replacement)" }

    private func render() {
        bigScore.stringValue = "\(score.overall)"
        ring.value = Double(score.overall) / 100.0
        ring.needsDisplay = true

        for v in dimsBox.arrangedSubviews { dimsBox.removeArrangedSubview(v); v.removeFromSuperview() }
        for (name, val, note) in [("Correctness", score.correctness, score.correctnessNote),
                                  ("Clarity", score.clarity, score.clarityNote),
                                  ("Engagement", score.engagement, score.engagementNote),
                                  ("Delivery", score.delivery, score.deliveryNote)] {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let n = NSTextField(labelWithString: name)
            n.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            n.textColor = .labelColor
            n.widthAnchor.constraint(equalToConstant: 78).isActive = true
            let v = NSTextField(labelWithString: "\(val)")
            v.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            v.textColor = val >= 80 ? .systemGreen : (val >= 55 ? .systemOrange : .systemRed)
            v.widthAnchor.constraint(equalToConstant: 26).isActive = true
            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = NSFont.systemFont(ofSize: 9)
            noteLabel.textColor = .tertiaryLabelColor
            noteLabel.lineBreakMode = .byTruncatingTail
            noteLabel.widthAnchor.constraint(equalToConstant: 108).isActive = true
            row.addArrangedSubview(n); row.addArrangedSubview(v); row.addArrangedSubview(noteLabel)
            dimsBox.addArrangedSubview(row)
        }

        for v in listStack.arrangedSubviews { listStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let live = visibleItems()
        if live.isEmpty {
            let l = NSTextField(labelWithString: "没有更多建议")
            l.font = NSFont.systemFont(ofSize: 12)
            l.textColor = .tertiaryLabelColor
            listStack.addArrangedSubview(l)
            return
        }
        let order = ["spelling", "grammar", "clarity", "style"]
        let titles = ["spelling": "Correctness · 拼写", "grammar": "Correctness · 语法",
                      "clarity": "Clarity · 清晰度", "style": "Delivery · 风格"]
        for t in order {
            let group = live.filter { $0.type == t }
            guard !group.isEmpty else { continue }
            let h = NSTextField(labelWithString: "\(titles[t] ?? t)（\(group.count)）")
            h.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            h.textColor = .secondaryLabelColor
            listStack.addArrangedSubview(h)
            for it in group { listStack.addArrangedSubview(rowView(for: it)) }
            let spacer = NSView()
            spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
            listStack.addArrangedSubview(spacer)
        }
    }

    private func rowView(for it: DiffItem) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = color(for: it.type).cgColor
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let text = NSMutableAttributedString()
        text.append(NSAttributedString(string: it.original + " → ", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.systemRed,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]))
        text.append(NSAttributedString(string: it.replacement, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.systemGreen,
        ]))
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(equalToConstant: 196).isActive = true

        let jumpBtn = NSButton(title: "", target: self, action: #selector(jumpRow(_:)))
        jumpBtn.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: nil)
        jumpBtn.isBordered = false
        jumpBtn.tag = it.start
        jumpBtn.widthAnchor.constraint(equalToConstant: 18).isActive = true

        let acceptBtn = NSButton(title: "接受", target: self, action: #selector(acceptRow(_:)))
        acceptBtn.bezelStyle = .rounded
        acceptBtn.controlSize = .small
        acceptBtn.font = NSFont.systemFont(ofSize: 10)
        acceptBtn.tag = it.start

        let dismissBtn = NSButton(title: "忽略", target: self, action: #selector(dismissRow(_:)))
        dismissBtn.bezelStyle = .rounded
        dismissBtn.controlSize = .small
        dismissBtn.font = NSFont.systemFont(ofSize: 10)
        dismissBtn.tag = it.start

        for b in [jumpBtn, acceptBtn, dismissBtn] { b.identifier = NSUserInterfaceItemIdentifier("\(it.start)") }
        row.addArrangedSubview(dot); row.addArrangedSubview(label)
        row.addArrangedSubview(jumpBtn); row.addArrangedSubview(acceptBtn); row.addArrangedSubview(dismissBtn)
        return row
    }

    private func color(for type: String) -> NSColor {
        switch type {
        case "spelling": return .systemRed
        case "grammar": return .systemOrange
        case "clarity": return .systemBlue
        default: return .systemPurple
        }
    }

    private func item(at start: Int) -> DiffItem? {
        visibleItems().first { $0.start == start } ?? items.first { $0.start == start }
    }

    @objc private func acceptRow(_ sender: NSButton) {
        guard let it = item(at: sender.tag) else { return }
        onAccept?(it)
        dismissed.insert(key(it))
        render()
    }

    @objc private func dismissRow(_ sender: NSButton) {
        guard let it = item(at: sender.tag) else { return }
        onDismiss?(it)
        dismissed.insert(key(it))
        render()
    }

    @objc private func jumpRow(_ sender: NSButton) {
        guard let it = item(at: sender.tag) else { return }
        onJump?(it)
    }

    func setTone(_ s: String) { toneLabel.stringValue = "语气：\(s)" }
}

/// 总分圆环
final class ScoreRing: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 6, dy: 6)
        let bg = NSBezierPath(ovalIn: r)
        NSColor.quaternaryLabelColor.setStroke()
        bg.lineWidth = 6
        bg.stroke()

        let fg = NSBezierPath()
        fg.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY),
                     radius: r.width / 2, startAngle: 90, endAngle: 90 - 360 * value, clockwise: true)
        color.setStroke()
        fg.lineWidth = 6
        fg.lineCapStyle = .round
        fg.stroke()
    }

    private var color: NSColor {
        if value >= 0.8 { return .systemGreen }
        if value >= 0.55 { return .systemOrange }
        return .systemRed
    }
}

/// 翻转坐标系（让列表从顶部往下排）
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
