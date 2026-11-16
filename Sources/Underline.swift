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
    var color: NSColor {
        switch self {
        case .spelling: return NSColor.systemRed
        case .grammar:  return NSColor.systemRed
        case .clarity:  return NSColor.systemBlue
        case .style:    return NSColor.systemPurple
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
}

// MARK: - 画布

final class UnderlineCanvas: NSView {
    var specs: [UnderlineSpec] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard !specs.isEmpty else { return }
        NSGraphicsContext.current?.shouldAntialias = true
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
        path.lineWidth = (kind.shape == .straightThin) ? 1.0 : 1.6
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

    /// 静默模式：只算 specs、绝不上屏（A 层真机验收用 —— 屏幕上不许出现任何像素）
    /// 默认 false，生产行为不变；清空时自动复位。
    var silent = false

    /// 全局静默（--passive 被动观察用）：与 silent 的区别是 clear() 不会把它复位，
    /// 意味着整段会话内一个像素都不上屏。
    static var globallySilent = false

    init() {
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
    func render(_ specs: [UnderlineSpec]) {
        guard !specs.isEmpty else { clear(); return }
        self.specs = specs
        let box = ScreenGeom.union(specs.map(\.rect)).insetBy(dx: -6, dy: -6)
        let appKit = ScreenGeom.toAppKit(box)
        setFrame(appKit, display: false)
        canvas.specs = specs.map {
            UnderlineSpec(rect: $0.rect.offsetBy(dx: -box.minX, dy: -box.minY),
                          kind: $0.kind, itemID: $0.itemID)
        }
        canvas.needsDisplay = true
        if !silent && !Self.globallySilent { orderFrontRegardless() }
    }

    func clear() {
        specs = []
        canvas.specs = []
        orderOut(nil)
        silent = false          // 一次静默只对一次检查生效，别让后面的真机画线被静默掉
    }

    /// 当前下划线矩形（全局坐标），M3 悬停命中测试用
    func currentRects() -> [UnderlineSpec] { specs }
}
