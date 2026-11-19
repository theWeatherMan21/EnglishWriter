// HoverCard.swift — 悬停下划线出卡片：类别 / 原句(高亮错处) / 红删绿加 / 一句中文理由 / 接受·忽略·加词典
//
// 三条硬约束（照 Grammarly 的实测体验，抄错就是「卡顿」差评）：
//   1. 卡片不许抢焦点：NSPanel([.nonactivatingPanel, .borderless]) + canBecomeKey=false
//      + 按钮 acceptsFirstMouse=true（否则第一次点击会被系统吃掉）
//   2. 悬停 300ms 才开；移开立即关；卡片自身区域算「还在悬停」
//   3. 覆盖窗口 ignoresMouseEvents，所以命中测试走全局 mouseMoved 监听，不靠窗口收事件

import AppKit

// MARK: - 按钮（非激活窗口里第一次点击就生效）

final class CardButton: NSButton {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// mouseDown 不调 super：不参与窗口激活/高亮，动作放 mouseUp
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    convenience init(title: String, primary: Bool = false) {
        self.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .regularSquare
        font = .systemFont(ofSize: 12, weight: primary ? .semibold : .regular)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = (primary ? NSColor.systemBlue : NSColor.secondaryLabelColor.withAlphaComponent(0.12)).cgColor
        contentTintColor = primary ? .white : .labelColor
    }
}

// MARK: - 卡片视图

final class HoverCardView: NSView {
    var onAccept: (() -> Void)?
    var onIgnore: (() -> Void)?
    var onAddDict: (() -> Void)?
    /// 改写 / 语气：点了才发请求（不自动发，烧钱）
    var onRewrite: (() -> Void)?
    var onTone: (() -> Void)?
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?

    private let width: CGFloat = 210
    private let pad: CGFloat = 14
    private var height: CGFloat = 120

    private let kindLabel = NSTextField(labelWithString: "")
    private let sentenceField = NSTextField(labelWithAttributedString: NSAttributedString(string: ""))
    private let diffField = NSTextField(labelWithString: "")
    private let reasonField = NSTextField(wrappingLabelWithString: "")
    private let acceptBtn = CardButton(title: "接受", primary: true)
    private let ignoreBtn = CardButton(title: "忽略")
    private let dictBtn = CardButton(title: "加入词典")
    private let rewriteBtn = CardButton(title: "改写")
    private let toneBtn = CardButton(title: "语气")
    private let prevBtn = CardButton(title: "◀")
    private let nextBtn = CardButton(title: "▶")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.25
        layer?.shadowRadius = 14
        layer?.shadowOffset = CGSize(width: 0, height: -3)
        if #available(macOS 10.15, *) { layer?.cornerCurve = .continuous }

        kindLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        kindLabel.textColor = .secondaryLabelColor
        sentenceField.font = .systemFont(ofSize: 12)
        sentenceField.lineBreakMode = .byTruncatingTail
        sentenceField.maximumNumberOfLines = 3
        diffField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        reasonField.font = .systemFont(ofSize: 12)
        reasonField.textColor = .secondaryLabelColor
        reasonField.maximumNumberOfLines = 3

        acceptBtn.onClick = { [weak self] in self?.onAccept?() }
        ignoreBtn.onClick = { [weak self] in self?.onIgnore?() }
        dictBtn.onClick = { [weak self] in self?.onAddDict?() }
        rewriteBtn.onClick = { [weak self] in self?.onRewrite?() }
        prevBtn.onClick = { [weak self] in self?.onPrev?() }
        nextBtn.onClick = { [weak self] in self?.onNext?() }
        toneBtn.onClick = { [weak self] in self?.onTone?() }

        for v in [kindLabel, sentenceField, diffField, reasonField, acceptBtn, ignoreBtn, dictBtn, rewriteBtn, toneBtn, prevBtn, nextBtn] as [NSView] {
            addSubview(v)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 从上往下排（AppKit 默认左下原点会排反）
    override var isFlipped: Bool { true }

    /// 填内容并算高度
    func configure(kind: UnderlineKind, sentence: String, errorRange: NSRange,
                   original: String, replacement: String, reason: String,
                   allowDict: Bool) {
        kindLabel.stringValue = "\(kind.labelZH) · \(kind.rawValue)"

        // 原句里把错处标红加粗
        let attr = NSMutableAttributedString(string: sentence)
        let full = NSRange(location: 0, length: (sentence as NSString).length)
        if errorRange.location >= 0, errorRange.location + errorRange.length <= full.length, errorRange.length > 0 {
            attr.addAttributes([.foregroundColor: kind.color,
                                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)], range: errorRange)
        }
        sentenceField.attributedStringValue = attr

        // 红删绿加
        let diff = NSMutableAttributedString()
        diff.append(NSAttributedString(string: original, attributes: [
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .strikethroughColor: NSColor.systemRed,
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        ]))
        diff.append(NSAttributedString(string: "  →  ", attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 12),
        ]))
        diff.append(NSAttributedString(string: replacement, attributes: [
            .foregroundColor: NSColor.systemGreen,
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
        ]))
        diffField.attributedStringValue = diff

        reasonField.stringValue = reason.isEmpty ? "（引擎没给理由）" : reason
        dictBtn.isHidden = !allowDict
        // 只有模型配置齐全时才给改写/语气入口（不给死按钮）
        let canRewrite = Rewrite.isAvailable()
        rewriteBtn.isHidden = !canRewrite
        toneBtn.isHidden = !canRewrite
        height = layoutSubviewsManually()
    }

    /// 手排（不用 Auto Layout：非激活窗口里更稳，也不受 SwiftUI 宏限制）
    @discardableResult
    private func layoutSubviewsManually() -> CGFloat {
        let textW = width - pad * 2
        var y: CGFloat = pad
        func place(_ v: NSView, _ h: CGFloat, gap: CGFloat = 6) {
            v.frame = NSRect(x: pad, y: y, width: textW, height: h)
            y += h + gap
        }
        let sentenceH = min(58, max(18, sentenceField.attributedStringValue.boundingRect(
            with: NSSize(width: textW, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 2))
        let reasonH = min(56, max(16, reasonField.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 200)).height + 2))

        place(kindLabel, 13, gap: 5)
        place(sentenceField, sentenceH, gap: 6)
        place(diffField, 18, gap: 6)
        place(reasonField, reasonH, gap: 10)

        let btnH: CGFloat = 26
        let btnW: CGFloat = 62
        let navW: CGFloat = 26
        var x = textW + pad - btnW
        for b in [dictBtn, ignoreBtn, acceptBtn] {
            if b.isHidden { continue }
            b.frame = NSRect(x: x, y: y, width: btnW, height: btnH)
            x -= btnW + 6
        }
        // 翻条：◀ n/N ▶ 放右侧
        var nx = textW + pad - navW
        for b in [nextBtn, prevBtn] {
            b.frame = NSRect(x: nx, y: y - btnH - 6, width: navW, height: btnH)
            nx -= navW + 6
        }
        y += 6
        if !rewriteBtn.isHidden || !toneBtn.isHidden {
            var x2: CGFloat = pad
            for b in [rewriteBtn, toneBtn] {
                if b.isHidden { continue }
                b.frame = NSRect(x: x2, y: y, width: btnW, height: btnH)
                x2 += btnW + 6
            }
            y += btnH + pad
        } else {
            y += pad - 6
        }
        return y
    }

    var preferredSize: NSSize { NSSize(width: width, height: height) }

    /// 缩略重排（首次 layout 时把算好的 frame 生效）
    func finalizeLayout() {
        _ = layoutSubviewsManually()
        needsDisplay = true
    }
}

// MARK: - 卡片窗口

final class HoverCardPanel: NSPanel {
    private let card = HoverCardView()
    private(set) var shownItemID: Int = -1

    init() {
        Audit.window()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)) + 1)
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                              .fullScreenAuxiliary, .transient]
        contentView = card
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(kind: UnderlineKind, sentence: String, errorRange: NSRange,
                 original: String, replacement: String, reason: String,
                 itemID: Int, anchor: CGRect,
                 onAccept: @escaping () -> Void,
                 onIgnore: @escaping () -> Void,
                 onAddDict: (() -> Void)?,
                 onRewrite: (() -> Void)? = nil,
                 onTone: (() -> Void)? = nil,
                 onPrev: (() -> Void)? = nil,
                 onNext: (() -> Void)? = nil) {
        card.onAccept = onAccept
        card.onIgnore = onIgnore
        card.onAddDict = onAddDict
        card.onRewrite = onRewrite
        card.onTone = onTone
        card.onPrev = onPrev
        card.onNext = onNext
        card.configure(kind: kind, sentence: sentence, errorRange: errorRange,
                       original: original, replacement: replacement, reason: reason,
                       allowDict: onAddDict != nil)
        let size = card.preferredSize
        setContentSize(size)
        card.frame = NSRect(origin: .zero, size: size)
        card.finalizeLayout()

        // 下划线下方 4pt；下方越界就翻到上方；左右夹进屏幕
        var box = CGRect(x: anchor.minX, y: anchor.maxY + 4, width: size.width, height: size.height)
        if let screen = ScreenGeom.screen(containingQuartz: anchor) {
            let vis = ScreenGeom.toQuartz(screen.visibleFrame)
            if box.maxY > vis.maxY { box.origin.y = anchor.minY - 4 - size.height }
            box.origin.x = min(max(box.minX, vis.minX + 6), vis.maxX - size.width - 6)
            box.origin.y = min(max(box.minY, vis.minY + 6), vis.maxY - size.height - 6)
        }
        setFrame(ScreenGeom.toAppKit(box), display: true)
        shownItemID = itemID
        if !UnderlineOverlay.globallySilent {
            Audit.show()
            orderFrontRegardless()
        }
    }

    func dismiss() {
        shownItemID = -1
        orderOut(nil)
    }

    /// 鼠标是否落在卡片上（AppKit 坐标）
    func containsMouse() -> Bool {
        guard isVisible else { return false }
        return frame.contains(NSEvent.mouseLocation)
    }
}

// MARK: - 悬停协调器（全局 mouseMoved + 300ms 停留）

@MainActor
final class HoverCoordinator {
    static let shared = HoverCoordinator()

    private let panel = HoverCardPanel()
    private var monitor: Any?
    private var dwell: DispatchWorkItem?
    private var pending: (itemID: Int, rect: CGRect)?
    private var currentOpenIndex = -1

    var dwellDelay: TimeInterval = 0.30

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.onMouseMoved() }
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        dwell?.cancel()
        panel.dismiss()
    }

    /// 自检专用：走一次真实命中流程（全局静默时应当在第一行就返回，不建卡不上屏）
    func tickForAudit() { onMouseMoved() }

    private func onMouseMoved() {
        if UnderlineOverlay.globallySilent { return }   // 只读模式：悬停卡片一律不许出现
        let mouseAppKit = NSEvent.mouseLocation
        let mouseQuartz = ScreenGeom.toQuartz(NSRect(origin: mouseAppKit, size: .zero)).origin
        let specs = InlineController.shared.overlay.currentRects()

        // 落在卡片上 → 保持
        if panel.containsMouse() { return }

        // 落在某条下划线上（往上下各放宽 3pt，好点）
        let hit = specs.first { $0.rect.insetBy(dx: -2, dy: -4).contains(mouseQuartz) }
        guard let h = hit else {
            if panel.shownItemID >= 0 { panel.dismiss() }
            dwell?.cancel()
            pending = nil
            return
        }
        if panel.shownItemID == h.itemID { return }
        if let p = pending, p.itemID == h.itemID { return }   // 已在计时
        pending = (h.itemID, h.rect)
        dwell?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.open(itemID: h.itemID, rect: h.rect) }
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellDelay, execute: work)
    }

    private func open(itemID: Int, rect: CGRect) {
        let ctrl = InlineController.shared
        guard itemID >= 0, itemID < ctrl.items.count else { return }
        let item = ctrl.items[itemID]
        let sentence = ctrl.sentenceText(forItem: itemID)

        panel.present(kind: item.kind,
                      sentence: sentence.text,
                      errorRange: sentence.errorRange,
                      original: item.original,
                      replacement: item.replacement,
                      reason: item.reason,
                      itemID: itemID,
                      anchor: rect,
                      onAccept: { [weak self] in
                          self?.panel.dismiss()
                          ctrl.accept(itemID: itemID)
                      },
                      onIgnore: { [weak self] in
                          self?.panel.dismiss()
                          ctrl.ignore(itemID: itemID)
                      },
                      onAddDict: { [weak self] in
                          self?.panel.dismiss()
                          ctrl.addToDictionary(itemID: itemID)
                      },
                      onRewrite: { [weak self] in
                          self?.panel.dismiss()
                          RewriteFlow.start(tone: false)
                      },
                      onTone: { [weak self] in
                          self?.panel.dismiss()
                          RewriteFlow.start(tone: true)
                      },
                      onPrev: { [weak self] in
                          self?.panel.dismiss()
                          self?.openPrevIssue()
                      },
                      onNext: { [weak self] in
                          self?.panel.dismiss()
                          self?.openNextIssue()
                      })
    }

    func dismissCard() { panel.dismiss() }

    @MainActor
    func openPrevIssue() {
        let ctrl = InlineController.shared
        guard !ctrl.items.isEmpty else { return }
        currentOpenIndex = (currentOpenIndex - 1 + ctrl.items.count) % ctrl.items.count
        let id = currentOpenIndex
        guard let rect = ctrl.overlay.currentRects().first(where: { $0.itemID == id })?.rect else { return }
        open(itemID: id, rect: rect)
    }

    /// 浮动球左键：跳到下一条没看过的建议
    @MainActor
    func openNextIssue() {
        let ctrl = InlineController.shared
        guard !ctrl.items.isEmpty else { return }
        currentOpenIndex = (currentOpenIndex + 1) % ctrl.items.count
        let id = currentOpenIndex
        let specs = ctrl.overlay.currentRects().filter { $0.itemID == id }
        guard let rect = specs.first?.rect else { return }
        open(itemID: id, rect: rect)
    }
}
