// HoverCard.swift — 悬停下划线出卡片：类别 / 原句(高亮错处) / 红删绿加 / 一句中文理由 / 接受·忽略·加词典
//
// 三条硬约束（照 Grammarly 的实测体验，抄错就是「卡顿」差评）：
//   1. 卡片不许抢焦点：NSPanel([.nonactivatingPanel, .borderless]) + canBecomeKey=false
//      + 按钮 acceptsFirstMouse=true（否则第一次点击会被系统吃掉）
//   2. 悬停 200ms 才开；移开 300ms 关；卡片自身区域算「还在悬停」
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

    private let width: CGFloat = 192
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
    private let moreBtn = CardButton(title: "···")
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
        moreBtn.onClick = { [weak self] in self?.showMoreMenu() }
        rewriteBtn.onClick = { [weak self] in self?.onRewrite?() }
        prevBtn.onClick = { [weak self] in self?.onPrev?() }
        nextBtn.onClick = { [weak self] in self?.onNext?() }
        toneBtn.onClick = { [weak self] in self?.onTone?() }

        for v in [kindLabel, sentenceField, diffField, reasonField, acceptBtn, ignoreBtn, dictBtn, rewriteBtn, toneBtn, prevBtn, nextBtn, moreBtn] as [NSView] {
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
        kindLabel.stringValue = kind.categoryLine

        // 上下文句子：…前5词 ~~旧词~~ 新词 后5词…（Grammarly 卡片就是这么给的，不是两个孤立的词）
        sentenceField.maximumNumberOfLines = 3
        sentenceField.lineBreakMode = .byTruncatingTail
        sentenceField.target = self
        sentenceField.action = #selector(sentenceTapped)
        sentenceField.isBezeled = false
        sentenceField.isEditable = false
        sentenceField.isSelectable = false
        sentenceField.attributedStringValue = Self.contextSentence(
            sentence: sentence, errorRange: errorRange,
            original: original, replacement: replacement)

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
        diffField.isHidden = true        // 规格：卡片只留类别 + 上下文句 + 操作
        reasonField.isHidden = true
        _ = reason
        dictBtn.isHidden = !allowDict
        // 只有模型配置齐全时才给改写/语气入口（不给死按钮）
        let canRewrite = Rewrite.isAvailable()
        rewriteBtn.isHidden = true      // 收进「···」菜单，卡片只留主操作
        toneBtn.isHidden = true
        moreBtn.isHidden = false
        height = layoutSubviewsManually()
    }

    @objc private func sentenceTapped() { onAccept?() }

    /// 「···」更多：把次要操作收进来（加入词典 / 改写 / 语气）
    private func showMoreMenu() {
        let menu = NSMenu()
        if !dictBtn.isHidden {
            let i = NSMenuItem(title: "加入词典", action: #selector(menuDict), keyEquivalent: "")
            i.target = self; menu.addItem(i)
        }
        if Rewrite.isAvailable() {
            let r = NSMenuItem(title: "改写这段…", action: #selector(menuRewrite), keyEquivalent: "")
            r.target = self; menu.addItem(r)
            let t = NSMenuItem(title: "改语气…", action: #selector(menuTone), keyEquivalent: "")
            t.target = self; menu.addItem(t)
        }
        if menu.items.isEmpty { menu.addItem(withTitle: "没有更多操作", action: nil, keyEquivalent: "") }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func menuDict() { onAddDict?() }
    @objc private func menuRewrite() { onRewrite?() }
    @objc private func menuTone() { onTone?() }

    /// 上下文句子：前 5 词 + 旧词（红删除线）+ 新词（绿粗）+ 后 5 词
    static func contextSentence(sentence: String, errorRange: NSRange,
                                original: String, replacement: String) -> NSAttributedString {
        let ns = sentence as NSString
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]

        var before = "", after = ""
        if errorRange.location != NSNotFound, errorRange.length > 0,
           NSMaxRange(errorRange) <= ns.length {
            let head = ns.substring(to: errorRange.location)
            let tail = ns.substring(from: NSMaxRange(errorRange))
            before = head.split(separator: " ").suffix(5).joined(separator: " ")
            after = tail.split(separator: " ").prefix(5).joined(separator: " ")
            if !before.isEmpty { before = "…" + before + " " }
            if !after.isEmpty { after = " " + after + "…" }
        }
        out.append(NSAttributedString(string: before, attributes: base))
        out.append(NSAttributedString(string: original, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.12),
        ]))
        out.append(NSAttributedString(string: " " + replacement + " ", attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.systemGreen,
            .backgroundColor: NSColor.systemGreen.withAlphaComponent(0.18),
        ]))
        out.append(NSAttributedString(string: after, attributes: base))
        return out
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
        let sentenceH = min(86, max(34, sentenceField.attributedStringValue.boundingRect(
            with: NSSize(width: textW, height: 300),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 6))
        let reasonH = min(56, max(16, reasonField.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: 200)).height + 2))

        place(kindLabel, 13, gap: 6)
        place(sentenceField, sentenceH, gap: 8)
        _ = reasonH

        let btnH: CGFloat = 26
        let btnW: CGFloat = 62
        let navW: CGFloat = 26
        var x = textW + pad - btnW
        acceptBtn.isHidden = true          // 接受 = 点修复词/句子（Grammarly 同款）
        for b in [moreBtn, ignoreBtn, dictBtn] {
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
        y += 8
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

    private let panel = HoverCardPanel()          // 旧 AppKit 卡片：保留给离线自测，不再上屏
    private var usingWebCard: Bool { true }
    private var monitor: Any?
    private var hoverMonitor: Any?
    private var localMonitor: Any?
    private var dwell: DispatchWorkItem?
    private var pending: (itemID: Int, rect: CGRect)?
    private var currentOpenIndex = -1
    private var hoveringItemID = -1
    private var lastMoveAt = Date.distantPast

    var dwellDelay: TimeInterval = 0.20   // 知澜 11-19 规格：200ms 就弹
    /// 自检用：全局监听是否真的挂上了（挂不上 = 悬停永远不会响，必须能断言）
    var hoverMonitorActive: Bool { hoverMonitor != nil }
    var clickMonitorActive: Bool { monitor != nil }

    /// 两条路都保留：
    ///   · 鼠标停在划线上 200ms → 出卡片（规格要求的悬停命中，走全局 mouseMoved 监听）
    ///   · 单击划线处 → 立刻出卡片（爹地 11-19：交互要「不用等」）
    /// 覆盖窗口 ignoresMouseEvents=true，两条路都不靠窗口事件。
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.onClick() }
        }
        // 悬停命中：全局 mouseMoved；命中判定用 M1 的 HighlightRects（Quartz 左上原点）
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.onMouseMoved() }
        }
        // 点卡片内部不关（卡片自己的按钮会处理）
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] e in
            Task { @MainActor in
                guard let self else { return }
                _ = self
                if !CardWeb.shared.frame.contains(NSEvent.mouseLocation) { CardWeb.shared.dismiss() }
            }
            return e
        }
        AppLog.info("m3", "hover monitors start click=\(monitor != nil) hover=\(hoverMonitor != nil) dwell=\(Int(dwellDelay * 1000))ms")
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        if let m = hoverMonitor { NSEvent.removeMonitor(m); hoverMonitor = nil }
        if let m = localMonitor { NSEvent.removeMonitor(m); localMonitor = nil }
        dwell?.cancel()
        panel.dismiss()
        CardWeb.shared.dismiss()
    }

    /// 自检专用：走一次真实命中流程（全局静默时应当在第一行就返回，不建卡不上屏）
    func tickForAudit() { onClick() }

    /// 单击：命中某条下划线 → 打开该条卡片；没命中 → 关掉当前卡片
    /// 纯函数：给定一批下划线矩形和一个点，返回命中的那条（±3/±6 的容错）
    /// 抽出来是为了能断言——点划线这条不能只靠真人试才知道对不对
    nonisolated static func hitTest(_ specs: [UnderlineSpec], at p: CGPoint) -> UnderlineSpec? {
        M3Flow.hit(specs, at: p, dx: 3, dy: 6)
    }

    /// 点击后这段时间内的焦点变化不算数：点文字必然移动光标，光标移动会触发重检查，
    /// 重检查会把线清掉 —— 于是「点得越准，越查不到线」（11-19 竞态）。
    private(set) var lastClickAt: Date = .distantPast
    static let clickFocusGrace: TimeInterval = 0.25

    nonisolated static func shouldIgnoreFocusChange(now: Date, lastClickAt: Date,
                                        grace: TimeInterval = clickFocusGrace) -> Bool {
        now.timeIntervalSince(lastClickAt) < grace
    }

    private func onClick() {
        if UnderlineOverlay.globallySilent { return }
        // ① 先同步抓快照：任何异步/重排版之前拿到线表，命中用这份
        let specs = InlineController.shared.overlay.currentRects()
        lastClickAt = Date()
        let mouseAppKit = NSEvent.mouseLocation
        // ① 我们自己的窗口让路：试用窗口 / 卡片 / 侧栏 / 浮动球 —— 点到一律不判定、不 dismiss
        //    （否则爹地点自己窗口会被记成 Safari/Mail 的 click-miss，看起来像「没反应」）
        let ownWindows: [NSWindow] = [CardWeb.shared, Sidebar.shared, FloatBall.shared,
                                      DemoLive.shared.windowRef].compactMap { $0 }
        for w in ownWindows where w.isVisible && w.frame.contains(mouseAppKit) { return }

        let mouseQuartz = ScreenGeom.pointToQuartz(mouseAppKit)
        let hit = HoverCoordinator.hitTest(specs, at: mouseQuartz)
        // miss 必须能自证差在哪：点坐标（两种口径）、最近一条线、以及「谁画的线 vs 现在前台是谁」。
        // 只有 rectCount 时，看不出是坐标偏了、还是点在别的 App 上（那是正常 miss）。
        // owner：命中的那条线自己记的归属（画线时确定）；没命中才退回当前检查的 pid
        let ownerPid = hit?.ownerPid ?? InlineController.shared.currentPid
        // front：取最前面那层正常窗口的宿主，不用 frontmostApplication（我们的浮层会让它给错值）
        let frontPid = ScreenGeom.frontmostWindowPID(excluding: getpid())
        let frontSource = "cgwindow"
        var nearest = Double.greatestFiniteMagnitude
        var nearestRect = CGRect.null
        var nearestItem = -1
        var ndx: CGFloat = 0, ndy: CGFloat = 0      // 相对最近线的分解距离（区分「点了别行」和「整体偏移」）
        for sp in specs {
            let dx = max(sp.rect.minX - mouseQuartz.x, 0, mouseQuartz.x - sp.rect.maxX)
            let dy = max(sp.rect.minY - mouseQuartz.y, 0, mouseQuartz.y - sp.rect.maxY)
            let d = (dx * dx + dy * dy).squareRoot()
            if d < nearest { nearest = d; nearestRect = sp.rect; ndx = dx; ndy = dy; nearestItem = sp.itemID }
        }
        let diag = String(
            format: "x=%.1f y=%.1f | owner=%@(%d) front=%@(%d) src=%@ | nearest=%.1f dx=%.1f dy=%.1f item=%d rect=[%.0f,%.0f,%.0f,%.0f]",
            mouseQuartz.x, mouseQuartz.y,
            appName(ownerPid) as NSString, ownerPid,
            appName(frontPid) as NSString, frontPid, frontSource as NSString,
            nearest == .greatestFiniteMagnitude ? -1 : nearest, ndx, ndy, nearestItem,
            nearestRect.isNull ? 0 : nearestRect.minX, nearestRect.isNull ? 0 : nearestRect.minY,
            nearestRect.isNull ? 0 : nearestRect.width, nearestRect.isNull ? 0 : nearestRect.height)
        CheckLog.append(.init(kind: hit == nil ? "click-miss" : "click-hit",
                              pid: ownerPid,
                              app: appName(ownerPid),
                              role: "-", textLen: 0, sentenceLen: 0,
                              itemCount: hit?.itemID ?? -1, rectCount: specs.count,
                              elapsed: "-", err: diag, at: Date()))
        guard let h = hit else { CardWeb.shared.dismiss(); return }
        open(itemID: h.itemID, rect: h.rect)
    }

    private func onMouseMoved() {
        if UnderlineOverlay.globallySilent { return }   // 只读模式：悬停卡片一律不许出现
        // 鼠标移动频率极高：40ms 节流，命中判定本身是纯几何（几十条 rect 的 contains）
        let now = Date()
        if now.timeIntervalSince(lastMoveAt) < 0.04 { return }
        lastMoveAt = now

        let mouseAppKit = NSEvent.mouseLocation
        let mouseQuartz = ScreenGeom.pointToQuartz(mouseAppKit)

        // 落在卡片上（含旧 AppKit 卡片）→ 保持，不关也不切
        if CardWeb.shared.isVisible, CardWeb.shared.frame.contains(mouseAppKit) { return }
        if panel.containsMouse() { return }

        let specs = InlineController.shared.overlay.currentRects()
        guard let h = M3Flow.hit(specs, at: mouseQuartz, dx: 2, dy: 4) else {
            if hoveringItemID >= 0 {
                hoveringItemID = -1
                AppLog.info("m3", "hover leave → dismiss")
                CardWeb.shared.dismiss()
            }
            dwell?.cancel()
            pending = nil
            return
        }
        if hoveringItemID == h.itemID, CardWeb.shared.isVisible { return }
        if let p = pending, p.itemID == h.itemID { return }   // 已在计时
        pending = (h.itemID, h.rect)
        dwell?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.hoveringItemID = h.itemID
                AppLog.info("m3", "hover open item=\(h.itemID) cursor=(\(Int(mouseQuartz.x)),\(Int(mouseQuartz.y))) rect=(\(Int(h.rect.minX)),\(Int(h.rect.minY)),\(Int(h.rect.width)),\(Int(h.rect.height))) dwell=\(Int(self.dwellDelay * 1000))ms")
                CheckLog.append(.init(kind: "hover-hit", pid: InlineController.shared.currentPid,
                                      app: appName(InlineController.shared.currentPid),
                                      role: "-", textLen: 0, sentenceLen: 0,
                                      itemCount: h.itemID, rectCount: specs.count,
                                      elapsed: "\(Int(self.dwellDelay * 1000))ms", err: "-", at: Date()))
                self.open(itemID: h.itemID, rect: h.rect)
            }
        }
        dwell = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellDelay, execute: work)
    }

    private func open(itemID: Int, rect: CGRect) {
        if usingWebCard { openWeb(itemID: itemID, rect: rect); return }
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
                          ctrl.ignorePermanent(itemID: itemID)
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

    /// 取证用：直接把卡片摆在指定位置（不走悬停），用来截「悬停 popover」的图
    func previewCard(kind: UnderlineKind, sentence: String, errorRange: NSRange,
                     original: String, replacement: String, anchor: CGRect,
                     onAccept: @escaping () -> Void) {
        panel.present(kind: kind, sentence: sentence, errorRange: errorRange,
                      original: original, replacement: replacement, reason: "",
                      itemID: 0, anchor: anchor,
                      onAccept: onAccept,
                      onIgnore: { [weak self] in self?.panel.dismiss() },
                      onAddDict: {})     // 词典常开：交给上层决定要不要真加
        // 取证：把卡片窗口矩形写出来，截图时按它精确裁切
        let f = panel.frame
        let info: [String: Any] = ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height]
        if let d = try? JSONSerialization.data(withJSONObject: info) {
            try? d.write(to: URL(fileURLWithPath: "/tmp/card-frame.json"))
        }
    }

    /// WebView 卡片：上下文取错词前后各 5 词
    @MainActor
    private func openWeb(itemID: Int, rect: CGRect) {
        let ctrl = InlineController.shared
        guard itemID >= 0, itemID < ctrl.items.count else { return }
        let item = ctrl.items[itemID]
        let sentence = ctrl.sentenceText(forItem: itemID)
        let ns = sentence.text as NSString
        var before = "", after = ""
        if sentence.errorRange.location != NSNotFound, NSMaxRange(sentence.errorRange) <= ns.length {
            before = ns.substring(to: sentence.errorRange.location).split(separator: " ").suffix(5).joined(separator: " ")
            after = ns.substring(from: NSMaxRange(sentence.errorRange)).split(separator: " ").prefix(5).joined(separator: " ")
            if !before.isEmpty { before = "…" + before + " " }
            if !after.isEmpty { after = " " + after + "…" }
        }
        let kind: UnderlineKind = item.type == "spelling" ? .spelling
            : (item.type == "grammar" ? .grammar : (item.type == "clarity" ? .clarity : .style))
        let hex = String(format: "#%02X%02X%02X", Int(kind.color.redComponent * 255),
                         Int(kind.color.greenComponent * 255), Int(kind.color.blueComponent * 255))
        CardWeb.shared.show(category: kind.categoryLine, color: hex,
                            before: before, original: item.original, replacement: item.replacement, after: after,
                            reason: ReasonText.zh(type: item.type, reason: item.reason,
                                                  original: item.original, replacement: item.replacement),
                            anchor: rect, allowDict: true,
                            onAccept: { _ = ctrl.accept(itemID: itemID) },
                            onIgnore: { ctrl.ignorePermanent(itemID: itemID) },
                            onIgnoreSession: { ctrl.ignoreSession(itemID: itemID) },
                            onDict: { ctrl.addToDictionary(itemID: itemID) },
                            onRewrite: { RewriteFlow.start(tone: false) },
                            onTone: { RewriteFlow.start(tone: true) })
        currentOpenIndex = itemID
    }

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
