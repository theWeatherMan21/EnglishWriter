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
    var onAcceptAll: (() -> Void)?

    private var items: [DiffItem] = []
    private var dismissed = Set<String>()
    private var score = WritingScore()
    private var importantOnly = true

    private let ring = ScoreRing(frame: .zero)
    private let bigScore = NSTextField(labelWithString: "—")
    private let dimsBox = NSStackView()
    private let listScroll = NSScrollView()
    private let listStack = NSStackView()
    private let toneLabel = NSTextField(labelWithString: "")   // 没结果就不显示，不许出现「未接/占位」字样
    private let filter = NSSegmentedControl(labels: ["重要建议", "全部建议"], trackingMode: .selectOne, target: nil, action: nil)

    private let width: CGFloat = 360
    // 视觉节奏：4 的倍数，标题 13/正文 11/说明 10，行高 30，卡片圆角 10
    private let m: CGFloat = 8

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

        let title = NSTextField(labelWithString: "Overall · 总评分")
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
        let scoreCaption = NSTextField(labelWithString: "总评分")
        scoreCaption.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        scoreCaption.textColor = .secondaryLabelColor
        scoreCaption.alignment = .center
        scoreCaption.frame = NSRect(x: 18, y: 404, width: 84, height: 14)
        scoreCaption.tag = 991
        root.addSubview(scoreCaption)

        let close = NSButton(title: "✕", target: self, action: #selector(closePanel))
        close.isBordered = false
        close.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        close.contentTintColor = .tertiaryLabelColor
        close.frame = NSRect(x: width - 34, y: 484, width: 20, height: 20)
        root.addSubview(close)

        // 四维
        dimsBox.orientation = .vertical
        dimsBox.alignment = .leading
        dimsBox.spacing = 4
        dimsBox.frame = NSRect(x: 108, y: 330, width: 240, height: 156)
        root.addSubview(dimsBox)

        // 筛选
        filter.target = self
        filter.action = #selector(filterChanged)
        filter.selectedSegment = 0
        filter.frame = NSRect(x: 18, y: 310, width: 200, height: 24)
        root.addSubview(filter)

        let acceptAll = NSButton(title: "全部接受", target: self, action: #selector(acceptAllTapped))
        acceptAll.bezelStyle = .rounded
        acceptAll.controlSize = .small
        acceptAll.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        acceptAll.frame = NSRect(x: width - 106, y: 308, width: 88, height: 26)
        acceptAll.tag = 992
        root.addSubview(acceptAll)

        // 列表
        listScroll.frame = NSRect(x: 12, y: 44, width: width - 24, height: 258)
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
            listStack.widthAnchor.constraint(equalToConstant: width - 36),
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
        let contentH = CGFloat(620)
        let h = min(maxH, contentH)
        setContentSize(NSSize(width: width, height: h))
        listScroll.frame = NSRect(x: 12, y: 44, width: width - 24, height: h - 44 - 300 + 250)
        ring.frame = NSRect(x: 18, y: h - 124, width: 84, height: 84)
        bigScore.frame = NSRect(x: 18, y: h - 96, width: 84, height: 30)
        contentView?.viewWithTag(991)?.frame = NSRect(x: 18, y: h - 116, width: 84, height: 14)
        // 关闭按钮跟着高度走（固定 y 会被 resize 顶出可视区）
        if let close = contentView?.subviews.first(where: { ($0 as? NSButton)?.title == "✕" }) {
            close.frame = NSRect(x: width - 34, y: h - 36, width: 20, height: 20)
        }
        dimsBox.frame = NSRect(x: 108, y: h - 194, width: 240, height: 156)
        filter.frame = NSRect(x: 18, y: h - 210, width: 200, height: 24)
        contentView?.viewWithTag(992)?.frame = NSRect(x: width - 106, y: h - 212, width: 88, height: 26)
        listScroll.frame = NSRect(x: 12, y: 44, width: width - 24, height: h - 210 - 34)
        toneLabel.frame = NSRect(x: 18, y: 16, width: width - 36, height: 16)
        if let root = contentView {
            for v in root.subviews where v !== listScroll && v !== toneLabel { _ = v }
        }
    }

    // MARK: 渲染

    @objc private func closePanel() { orderOut(nil); onAcceptAll = nil }

    @objc private func acceptAllTapped() {
        onAcceptAll?()
        render()
    }

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
        let band = score.overall >= 80 ? "良好" : (score.overall >= 50 ? "需注意" : "需改进")
        contentView?.viewWithTag(991)?.removeFromSuperview()
        let caption = NSTextField(labelWithString: "总评分 · \(band)")
        caption.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        caption.textColor = tone(score.overall)
        caption.alignment = .center
        caption.tag = 991
        let hh = contentView?.frame.height ?? 520
        caption.frame = NSRect(x: 12, y: hh - 118, width: 96, height: 14)
        contentView?.addSubview(caption)
        ring.value = Double(score.overall) / 100.0
        ring.needsDisplay = true

        for v in dimsBox.arrangedSubviews { dimsBox.removeArrangedSubview(v); v.removeFromSuperview() }
        for (name, val, note) in [("正确性", score.correctness, score.correctnessNote),
                                  ("清晰度", score.clarity, score.clarityNote),
                                  ("吸引力", score.engagement, score.engagementNote),
                                  ("表达", score.delivery, score.deliveryNote)] {
            // 一行：中文维度名 + 分数 + 进度条；下一行：一句话说明
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            row.alignment = .centerY
            let n = NSTextField(labelWithString: name)
            n.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            n.widthAnchor.constraint(equalToConstant: 44).isActive = true
            let v = NSTextField(labelWithString: "\(val)")
            v.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            v.textColor = tone(val)
            v.widthAnchor.constraint(equalToConstant: 24).isActive = true
            let bar = ScoreBar()
            bar.value = Double(val) / 100.0
            bar.color = tone(val)
            bar.widthAnchor.constraint(equalToConstant: 148).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
            row.addArrangedSubview(n); row.addArrangedSubview(v); row.addArrangedSubview(bar)

            let noteLabel = NSTextField(labelWithString: note)
            noteLabel.font = NSFont.systemFont(ofSize: 10)
            noteLabel.textColor = .tertiaryLabelColor
            noteLabel.lineBreakMode = .byTruncatingTail
            noteLabel.widthAnchor.constraint(equalToConstant: 216).isActive = true

            let col = NSStackView(views: [row, noteLabel])
            col.orientation = .vertical
            col.alignment = .leading
            col.spacing = 1
            dimsBox.addArrangedSubview(col)
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
        let titles = ["spelling": "正确性 · 拼写", "grammar": "正确性 · 语法",
                      "clarity": "清晰度 · 冗长表达", "style": "表达 · 风格"]
        for t in order {
            let group = live.filter { $0.type == t }
            guard !group.isEmpty else { continue }
            let gap = NSView()
            gap.heightAnchor.constraint(equalToConstant: t == order.first ? 2 : 12).isActive = true
            listStack.addArrangedSubview(gap)
            if t != order.first {
                let line = NSView()
                line.wantsLayer = true
                line.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor
                line.heightAnchor.constraint(equalToConstant: 1).isActive = true
                line.widthAnchor.constraint(equalToConstant: width - 40).isActive = true
                listStack.addArrangedSubview(line)
                let g2 = NSView(); g2.heightAnchor.constraint(equalToConstant: 6).isActive = true
                listStack.addArrangedSubview(g2)
            }
            let head = NSStackView()
            head.orientation = .horizontal
            head.spacing = 6
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.layer?.backgroundColor = color(for: t).cgColor
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            let h = NSTextField(labelWithString: titles[t] ?? t)
            h.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            h.textColor = .labelColor
            let c = NSTextField(labelWithString: "\(group.count)")
            c.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            c.textColor = .secondaryLabelColor
            head.addArrangedSubview(dot); head.addArrangedSubview(h); head.addArrangedSubview(c)
            listStack.addArrangedSubview(head)
            for it in group { listStack.addArrangedSubview(rowView(for: it)) }
            let spacer = NSView()
            spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
            listStack.addArrangedSubview(spacer)
        }
    }

    private func rowView(for it: DiffItem) -> NSView {
        let row = HoverRow()
        row.orientation = .horizontal
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        row.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.03).cgColor

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = color(for: it.type).cgColor
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let label = NSTextField(labelWithAttributedString: diffText(it))
        label.lineBreakMode = .byTruncatingTail
        label.widthAnchor.constraint(equalToConstant: 132).isActive = true
        label.tag = it.start
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(jumpRow(_:))))

        let jumpBtn = NSButton(title: "定位", target: self, action: #selector(jumpRow(_:)))
        jumpBtn.bezelStyle = .inline
        jumpBtn.controlSize = .small
        jumpBtn.font = NSFont.systemFont(ofSize: 9)
        jumpBtn.isBordered = false
        jumpBtn.contentTintColor = .secondaryLabelColor
        jumpBtn.tag = it.start
        jumpBtn.widthAnchor.constraint(equalToConstant: 26).isActive = true

        let acceptBtn = NSButton(title: "接受", target: self, action: #selector(acceptRow(_:)))
        acceptBtn.bezelStyle = .rounded
        acceptBtn.controlSize = .small
        acceptBtn.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        acceptBtn.contentTintColor = .controlAccentColor
        acceptBtn.tag = it.start

        let dismissBtn = NSButton(title: "忽略", target: self, action: #selector(dismissRow(_:)))
        dismissBtn.bezelStyle = .inline
        dismissBtn.controlSize = .small
        dismissBtn.font = NSFont.systemFont(ofSize: 11)
        dismissBtn.contentTintColor = .secondaryLabelColor
        dismissBtn.tag = it.start

        for b in [jumpBtn, acceptBtn, dismissBtn] { b.identifier = NSUserInterfaceItemIdentifier("\(it.start)") }
        row.addArrangedSubview(dot); row.addArrangedSubview(label)
        row.addArrangedSubview(jumpBtn); row.addArrangedSubview(acceptBtn); row.addArrangedSubview(dismissBtn)

        // 理由（模型给的 reason 直接显示，没有就按类型给一句人话）
        var reasonText = it.reason.isEmpty ? defaultReason(it.type) : it.reason
        if reasonText.contains(it.original) && reasonText.contains(it.replacement) { reasonText = "" }
        let reason = NSTextField(wrappingLabelWithString: reasonText)
        reason.font = NSFont.systemFont(ofSize: 10)
        reason.textColor = .tertiaryLabelColor
        reason.preferredMaxLayoutWidth = 300
        reason.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let col = NSStackView(views: reasonText.isEmpty ? [row] : [row, reason])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        col.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 6, right: 4)
        return col
    }

    private func tone(_ v: Int) -> NSColor {
        if v >= 80 { return .systemGreen }
        if v >= 50 { return .systemOrange }
        return .systemRed
    }

    /// 拼写类：把「真正变的字母」加粗下划线，别让 immediatly→immediately 看着像一样
    private func diffText(_ it: DiffItem) -> NSAttributedString {
        return SpellingDiff.attributed(original: it.original, replacement: it.replacement)
    }

    private func diffTextLegacy(_ it: DiffItem) -> NSAttributedString {
        let a = it.original, b = it.replacement
        let ca = Array(a), cb = Array(b)
        var pre = 0
        while pre < min(ca.count, cb.count), ca[pre] == cb[pre] { pre += 1 }
        var suf = 0
        while suf < min(ca.count - pre, cb.count - pre),
              ca[ca.count - 1 - suf] == cb[cb.count - 1 - suf] { suf += 1 }
        func parts(_ arr: [Character]) -> (String, String, String) {
            let p = String(arr[0..<pre])
            let mid = String(arr[pre..<(arr.count - suf)])
            let s = String(arr[(arr.count - suf)...])
            return (p, mid, s)
        }
        let (pa, ma, sa) = parts(ca)
        let (pb, mb, sb) = parts(cb)
        let out = NSMutableAttributedString()
        let normal: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]
        let oldBad: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.systemRed,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue]
        let newGood: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.systemGreen]
        out.append(NSAttributedString(string: pa, attributes: normal))
        out.append(NSAttributedString(string: ma, attributes: oldBad))
        out.append(NSAttributedString(string: sa + " → " + pb, attributes: normal))
        out.append(NSAttributedString(string: mb, attributes: newGood))
        out.append(NSAttributedString(string: sb, attributes: normal))
        return out
    }

    private func defaultReason(_ type: String) -> String {
        switch type {
        case "spelling": return "拼写错误"
        case "grammar": return "语法问题"
        case "clarity": return "表达可以更简洁"
        default: return "风格建议"
        }
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

    @objc private func jumpRow(_ sender: Any) {
        let tag: Int
        if let b = sender as? NSButton { tag = b.tag }
        else if let g = sender as? NSClickGestureRecognizer, let v = g.view { tag = v.tag }
        else { return }
        guard let it = item(at: tag) else { return }
        onJump?(it)
    }

    func setTone(_ s: String) {
        toneLabel.stringValue = s.isEmpty ? "" : "语气：\(s)"
        toneLabel.isHidden = s.isEmpty
    }
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

/// 四维横向进度条
final class ScoreBar: NSView {
    var value: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let track = NSBezierPath(roundedRect: bounds, xRadius: h / 2, yRadius: h / 2)
        NSColor.quaternaryLabelColor.setFill()
        track.fill()
        var w = bounds.width * CGFloat(min(1, max(0, value)))
        w = max(w, h)   // 太小时也留个圆头
        let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h),
                                xRadius: h / 2, yRadius: h / 2)
        color.setFill()
        fill.fill()
    }
}

/// 建议行容器：hover 给淡背景（Grammarly 那种「这行可以点」的暗示）
final class HoverRow: NSStackView {
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
        }
    }

    override func mouseExited(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }
}
