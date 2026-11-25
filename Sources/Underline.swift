// Underline.swift — 行内下划线渲染器（Grammarly 灵魂：错误处直接在原文上画线）
//
// 结构照 Grammarly：HighlightSpan(= 一条错误) → HighlightRects(= 按视觉行拆开的矩形)。
// 一个透明 NSPanel 覆盖目标窗口区域，canvas 逐段画波浪线 / 直线 / 虚线。
// 覆盖窗口 ignoresMouseEvents = true：绝不抢焦点、不挡点击；
// M3 的悬停卡片靠全局 mouseMoved 监听 + 命中测试解决，不靠窗口收事件。

import AppKit

// MARK: - 类型

enum UnderlineKind: String, Codable, CaseIterable {
    case spelling
    case grammar
    case clarity
    case style

    static func from(_ raw: String) -> UnderlineKind {
        switch raw.lowercased() {
        case "spelling", "spell", "typo":        return .spelling
        case "clarity", "concision", "wordy":    return .clarity
        case "style", "tone", "suggestion":      return .style
        default:                                 return .grammar
        }
    }

    /// 颜色 × 形状双编码（色盲友好）
    /// 卡片类别行（知澜 11-19 固定格式）
    var categoryLine: String {
        switch self {
        case .spelling: return "正确性 · 修正拼写"
        case .grammar:  return "正确性 · 语法问题"
        case .clarity:  return "清晰度 · 精简表达"
        case .style:    return "表达 · 调整风格"
        }
    }

    var color: NSColor {
        switch self {
        // 知澜 11-19 给的精确色值（与 Grammarly 一致）：
        // 正确性 #EE1437 红 / 清晰度 #4A6EDE 蓝 / 表达 紫 / 吸引力 绿
        case .spelling: return NSColor(srgbRed: 0xEE/255.0, green: 0x14/255.0, blue: 0x37/255.0, alpha: 1)
        case .grammar:  return NSColor(srgbRed: 0xEE/255.0, green: 0x14/255.0, blue: 0x37/255.0, alpha: 1)
        case .clarity:  return NSColor(srgbRed: 0x4A/255.0, green: 0x6E/255.0, blue: 0xDE/255.0, alpha: 1)
        case .style:    return NSColor(srgbRed: 0x9B/255.0, green: 0x51/255.0, blue: 0xD2/255.0, alpha: 1)
        }
    }

    var shape: WaveShape {
        switch self {
        case .spelling: return .wavy
        case .grammar:  return .straight
        case .clarity:  return .straightThin
        case .style:    return .dotted
        }
    }

    var labelZH: String {
        switch self {
        case .spelling: return "拼写"
        case .grammar:  return "语法"
        case .clarity:  return "清晰度"
        case .style:    return "风格"
        }
    }
}

enum WaveShape { case wavy, straight, straightThin, dotted }

/// 一条错误在屏幕上的落点（全局坐标、左上原点）
struct UnderlineSpec: Equatable {
    var rect: CGRect
    var kind: UnderlineKind
    var itemID: Int = -1
    /// 这条线是给哪个 App 画的。归属在画线时就确定，点击时绝不靠「当前焦点」反查（会反查到别的 App）
    var ownerPid: pid_t = 0
    /// 最后一次被检查确认的时间。超过 2s 没被确认 → 自动隐藏，屏幕上不留没人管的线
    var stamp: Date = Date()

    static func == (a: UnderlineSpec, b: UnderlineSpec) -> Bool {
        a.rect == b.rect && a.kind == b.kind && a.itemID == b.itemID
    }

    /// 纯函数：挑出「还有效」的线。
    /// 判据两条：① 超过 ttl 没被复验确认 → 灭；② 宿主不再是当前前台 App → 灭（切走后残影）。
    static func alive(_ specs: [UnderlineSpec], now: Date, ttl: TimeInterval,
                      frontPid: pid_t? = nil) -> [UnderlineSpec] {
        specs.filter { sp in
            if now.timeIntervalSince(sp.stamp) > ttl { return false }
            if let f = frontPid, sp.ownerPid != 0, sp.ownerPid != f { return false }
            return true
        }
    }
}

// MARK: - 画布

final class UnderlineCanvas: NSView {
    var flashRect: CGRect? { didSet { needsDisplay = true } }
    var specs: [UnderlineSpec] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.shouldAntialias = true
        if let f = flashRect {
            NSColor.systemYellow.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: f, xRadius: 3, yRadius: 3).fill()
        }
        guard !specs.isEmpty else { return }
        for spec in specs { UnderlinePainter.stroke(spec.rect, spec.kind) }
    }
}

/// 画线的唯一实现：屏幕上的 canvas 与离线快照共用这一段，保证「看到的就是测到的」
enum UnderlinePainter {
    static func stroke(_ r: CGRect, _ kind: UnderlineKind) {
        let color = kind.color
        // 线画在文字基线下方 1.0pt，厚度 1.6pt
        let y = r.maxY - 1.0
        let path = NSBezierPath()
        // 2px 起步：1px 在 Retina 上肉眼几乎看不见（爹地「点了没反应」的观感来源之一）
        path.lineWidth = 2.0
        path.lineJoinStyle = .round
        path.lineCapStyle = .round
        switch kind.shape {
        case .straight, .straightThin:
            path.move(to: NSPoint(x: r.minX, y: y))
            path.line(to: NSPoint(x: r.maxX, y: y))
        case .dotted:
            path.setLineDash([1.5, 2.5], count: 2, phase: 0)
            path.move(to: NSPoint(x: r.minX, y: y))
            path.line(to: NSPoint(x: r.maxX, y: y))
        case .wavy:
            let amp: CGFloat = 1.3
            let period: CGFloat = 5.0
            var x = r.minX
            path.move(to: NSPoint(x: x, y: y))
            var up = true
            while x < r.maxX {
                let nx = min(x + period / 2, r.maxX)
                let cy = up ? y - amp : y + amp
                path.curve(to: NSPoint(x: nx, y: y),
                           controlPoint1: NSPoint(x: x + (nx - x) * 0.5, y: cy),
                           controlPoint2: NSPoint(x: x + (nx - x) * 0.5, y: cy))
                x = nx
                up.toggle()
            }
        }
        color.setStroke()
        path.stroke()
    }
}

// MARK: - 覆盖窗口

final class UnderlineOverlay: NSPanel {
    private let canvas = UnderlineCanvas()
    private(set) var specs: [UnderlineSpec] = []
    /// 定位闪示：点侧栏某条 → 对应词黄底 2 秒（Grammarly 那一环）
    private var flash: CGRect?

    /// 静默模式：只算 specs、绝不上屏（A 层真机验收用 —— 屏幕上不许出现任何像素）
    /// 默认 false，生产行为不变；清空时自动复位。
    var silent = false

    /// 全局静默（--passive 被动观察用）：与 silent 的区别是 clear() 不会把它复位，
    /// 意味着整段会话内一个像素都不上屏。
    static var globallySilent = false

    init() {
        Audit.window()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true          // 不收事件、不挡点击（悬停卡片走全局监听）
        acceptsMouseMovedEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                              .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false
        contentView = canvas
        canvas.autoresizingMask = [.width, .height]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// 画一批下划线。rects 是全局屏幕坐标（左上原点）。
    func render(_ incoming: [UnderlineSpec]) {
        guard !incoming.isEmpty else { clear(reason: "no-items"); return }
        // 硬闸（知澜 11-25）：pid 丢了、矩形为 0、或整条线不在任何屏幕里 —— 一律不画。
        // 实测出现过 pid=0 / [-3977,4810] 这种飞出屏幕的 spec：宁可这条不画，也不许画到看不见的地方。
        var specs: [UnderlineSpec] = []
        var rejected: [String] = []
        for s in incoming {
            if s.ownerPid == 0 { rejected.append("no-pid@\(s.kind)"); continue }
            if s.rect.width <= 0 || s.rect.height <= 0 { rejected.append("zero-rect@\(s.kind)"); continue }
            let appKit = ScreenGeom.toAppKit(s.rect)
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(appKit) }
            if !onScreen {
                rejected.append("off-screen@\(s.kind)\(Int(s.rect.minX)),\(Int(s.rect.minY))")
                continue
            }
            specs.append(s)
        }
        if !rejected.isEmpty {
            CheckLog.append(.init(kind: "underline-reject", pid: incoming.first?.ownerPid ?? 0,
                                  app: appName(incoming.first?.ownerPid ?? 0), role: "-",
                                  textLen: 0, sentenceLen: 0, itemCount: incoming.count, rectCount: rejected.count,
                                  elapsed: "-", err: rejected.prefix(6).joined(separator: " "), at: Date()))
        }
        guard !specs.isEmpty else { clear(reason: "all-rejected"); return }
        self.specs = specs
        var all = specs.map(\.rect)
        if let f = flash { all.append(f) }
        let box = ScreenGeom.union(all).insetBy(dx: -6, dy: -6)
        let appKit = ScreenGeom.toAppKit(box)
        setFrame(appKit, display: false)
        canvas.specs = specs.map {
            UnderlineSpec(rect: $0.rect.offsetBy(dx: -box.minX, dy: -box.minY),
                          kind: $0.kind, itemID: $0.itemID)
        }
        canvas.flashRect = flash?.offsetBy(dx: -box.minX, dy: -box.minY)
        canvas.needsDisplay = true
        let sig = specs.map { "\($0.itemID):\(Int($0.rect.minX)),\(Int($0.rect.minY))" }.joined(separator: "|")
        // 新进程第一笔必须无条件留痕：sig 从 nil 起，别让「签名没变」吃掉第一次证据（知澜 11-25）
        if lastDrawSig == nil || lastDrawSig != sig {
            lastDrawSig = sig
            let brief = specs.prefix(4).map { "\($0.kind)@\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width)),\(Int($0.rect.height))" }.joined(separator: " ")
            CheckLog.append(.init(kind: "underline-draw", pid: specs.first?.ownerPid ?? 0,
                                  app: appName(specs.first?.ownerPid ?? 0), role: "-",
                                  textLen: 0, sentenceLen: 0, itemCount: specs.count, rectCount: specs.count,
                                  elapsed: "-", err: "n=\(specs.count) ttl=\(Int(specTTL))s [\(brief)]", at: Date()))
        }
        if !silent && !Self.globallySilent {
            Audit.show()
            orderFrontRegardless()
        }
    }

    /// 只登记命中区域、不上屏（试用窗口自己的编辑器用原生属性画线，
    /// 但点击命中测试和卡片仍走同一条 overlay 通道，避免两套逻辑）
    func adoptSpecsForHitTest(_ newSpecs: [UnderlineSpec]) {
        specs = newSpecs
    }

    /// 闪示一个位置：黄底 2 秒后自动消失（不改宿主文本、不抢焦点）
    /// 高亮一个位置：挂着直到 clearHighlight()/重新 render（用户处理完才消失）
    func highlight(_ rect: CGRect) {
        guard !silent, !Self.globallySilent else { return }
        flash = rect.insetBy(dx: -2, dy: -2)
        render(specs)
    }

    func clearHighlight() {
        flash = nil
        render(specs)
    }

    /// 屏幕上当前有没有线（给定期复验用）
    var hasUnderlines: Bool { !specs.isEmpty }

    /// 兜底存活时间。注意：2s 太短——人只是「看着不动」而没有敲字时，没有任何事件来刷新 stamp，
    /// 线会在 2 秒后自己消失（11-19 实测：render rect=3，19 秒后点击时 rectCount=0）。
    /// 现在改成 60s 兜底 + 宿主切换立刻灭（见 alive 的 frontPid 判据）。
    // 线只活到「下一次确认」为止：3 秒内没有新结果就自灭（爹地 11-23 报「下划线滞留」）
    private let specTTL: TimeInterval = 8.0      // 知澜定 8 秒兜底：同文本没结果也不许秒灭
    private var lastDrawSig: String? = nil
    private var ttlTimer: Timer?

    /// 清掉所有超过 TTL 没被确认的线（滚走 / 窗口移走 / 切 App 的残影兜底）
    func pruneStale(maxAge: TimeInterval? = nil) {
        let ttl = maxAge ?? specTTL
        let now = Date()
        let front = ScreenGeom.frontmostWindowPID()
        let keep = UnderlineSpec.alive(specs, now: now, ttl: ttl, frontPid: front)
        guard keep.count != specs.count else { return }
        // 线为什么消失必须留证据：是超时、还是宿主换了（或宿主进程没了）
        let dropped = specs.count - keep.count
        let expired = specs.filter { now.timeIntervalSince($0.stamp) > ttl }.count
        let wrongHost = specs.filter { sp in
            now.timeIntervalSince(sp.stamp) <= ttl && sp.ownerPid != 0 && sp.ownerPid != front
        }.count
        CheckLog.append(.init(kind: "prune", pid: front, app: appName(front), role: "-",
                              textLen: 0, sentenceLen: 0, itemCount: dropped, rectCount: keep.count,
                              elapsed: "-",
                              err: "掉 \(dropped) 条（超时 \(expired) / 宿主不符 \(wrongHost)；宿主=%@(\(front))",
                              at: Date()))
        specs = keep
        canvas.specs = keep
        if keep.isEmpty { orderOut(nil) }
    }

    /// 同一段文本被轮询再次确认时刷新时间戳：线只在「没人再确认」时才灭，
    /// 不是因为用户停下来看（否则 3 秒后线会自己在屏幕上消失）。
    func touch(pid: pid_t) {
        guard !specs.isEmpty else { return }
        let now = Date()
        specs = specs.map { sp in
            var s = sp
            if s.ownerPid == pid || s.ownerPid == 0 { s.stamp = now }
            return s
        }
    }

    func startTTLWatchdog() {
        guard ttlTimer == nil else { return }
        ttlTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pruneStale() }
        }
    }

    func clear(reason: String = "unspecified") {
        let had = specs.count
        flash = nil
        specs = []
        canvas.specs = []
        orderOut(nil)
        silent = false          // 一次静默只对一次检查生效，别让后面的真机画线被静默掉
        if had > 0 {
            lastDrawSig = nil
            CheckLog.append(.init(kind: "underline-clear", pid: 0, app: "-", role: "-",
                                  textLen: 0, sentenceLen: 0, itemCount: 0, rectCount: 0,
                                  elapsed: "-", err: "reason=\(reason) 掉了\(had)条", at: Date()))
        }
    }

    /// 当前下划线矩形（全局坐标），M3 悬停命中测试用
    func currentRects() -> [UnderlineSpec] { specs }
}
