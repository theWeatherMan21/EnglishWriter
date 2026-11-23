// FloatBall.swift — 贴着输入框的浮动球（Grammarly 那个「我在盯着」的视觉信号）
//
// 为什么必须有它：爹地「完全没反应」的直接原因不是没检查，是**没有可见反馈**。
// 线画在字下面，写邮件时视线在行尾，根本看不到。
//
// 形态（按知澜 11-18 17:48 口径 = 三态，不许两态）：
//   · 灰球（空心 + ?）= 没取到文本（没窗口 / 没焦点元素 / 中文跳过 / 该 App 关着）→「我不知道」
//   · 绿点            = 真检查过、0 命中 →「我看过了，没问题」
//   · 环 + 数字       = 有 N 条，环色按最严重类别
// 为什么必须三态：items=0 时打绿点，但「检查过没问题」和「根本没读到字」对用户是两件事；
// 打成绿点就是撒谎，用户会认定插件在装样子。
//   · 右键 = 「在此 App 关闭」→ 加进排除名单，立刻消失
//   · 左键 = 跳到下一条（有下一张卡片时）
//   · 从不抢焦点（nonactivatingPanel + 只吃自己那 22pt）

import AppKit

final class FloatBall: NSPanel {

    static let shared = FloatBall()

    /// 三态，但 **unknown 不再上屏**（11-19 爹地反馈：一个问号在屏幕上到处飘是纯噪音）。
    /// unknown 仍保留为内部状态，用于日志与诊断（「读不到文本」和「检查过 0 命中」必须能区分），
    /// 但 UI 层直接 hide()：Grammarly 在不支持的 App 里也不显示球。
    enum Phase {
        case unknown            // 没取到文本
        case clear              // 检查过、0 命中
        case issues             // 有 N 条
    }

    fileprivate(set) var phase: Phase = .clear
    fileprivate(set) var count = 0
    fileprivate(set) var severity: UnderlineKind = .grammar
    fileprivate var pid: pid_t = 0
    private let size: CGFloat = 22

    /// 三态判定（纯函数，自测直接断言；渲染侧不许另写一套）
    /// textLen == nil / 0 → 没取到文本 → unknown；items > 0 → issues；其余 clear
    static func phase(textLen: Int?, itemCount: Int) -> Phase {
        guard let len = textLen, len > 0 else { return .unknown }
        return itemCount > 0 ? .issues : .clear
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 22, height: 22),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary, .transient]
        contentView = BallView(ball: self)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    struct State {
        var phase: Phase
        var count: Int
        var severity: UnderlineKind
        var pid: pid_t
        var anchor: CGRect          // Quartz（左上原点）
    }

    /// 每次检查后调用（三态：unknown / clear / issues）
    func update(_ st: State?) {
        guard let st else { hide(); return }
        if st.phase == .unknown { hide(); return }   // 读不到文本 / 不支持的 App：不显示球，别挂问号
        phase = st.phase
        count = st.phase == .issues ? st.count : 0
        severity = st.severity
        pid = st.pid
        place(near: st.anchor)
        orderFrontRegardless()
        (contentView as? BallView)?.needsDisplay = true
    }

    func hide() {
        count = 0
        phase = .clear
        orderOut(nil)
    }

    /// 球（Quartz 左上原点）→ AppKit 窗口 frame。
    /// 必须用**全局** topOffset（主屏高度），不能用球所在那块屏的高度：
    /// 单屏时两者相等看不出来，一接副屏球就越跑越偏（爹地 11-19 实报「到处乱飘」）。
    static func appKitFrame(ballTopLeft p: CGPoint, size: CGFloat, topOffset: CGFloat) -> NSRect {
        ScreenGeom.toAppKit(CGRect(x: p.x, y: p.y, width: size, height: size), topOffset: topOffset)
    }

    private func place(near q: CGRect) {
        // 用 anchor 所在那块屏（不是永远主屏），并按可见区夹紧
        let screen = NSScreen.screens.first { s in
            ScreenGeom.toQuartz(s.frame).intersects(q)
        } ?? NSScreen.main
        let visible = ScreenGeom.toQuartz(screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900))
        let p = BallPlacement.resolve(anchor: q, screenVisible: visible, size: size)
        // Quartz（左上原点）→ AppKit：一律走全局口径（主屏高度），不手写换算
        setFrame(FloatBall.appKitFrame(ballTopLeft: p, size: size, topOffset: ScreenGeom.topOffset),
                 display: false)
    }

    // MARK: 交互

    func handleRightClick() {
        let menu = NSMenu()
        let title: String
        switch phase {
        case .unknown: title = "EnglishWriter：这里读不到文本"
        case .clear:   title = "EnglishWriter：这一处没问题"
        case .issues:  title = "EnglishWriter：\(count) 条建议"
        }
        let info = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let off = NSMenuItem(title: "在此 App 关闭", action: #selector(disableForApp), keyEquivalent: "")
        off.target = self
        menu.addItem(off)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func disableForApp() {
        guard pid > 0 else { return }
        if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, !bid.isEmpty {
            EnginePrefs.addExcludedApp(bid)
        }
        EnginePrefs.addExcludedApp(appName(pid))
        InlineController.shared.clearUnderlines()
        hide()
    }

    func handleLeftClick() {
        // Grammarly 口径（知澜 11-19 P1 规格）：**点球 = 开建议侧栏**。
        // 旧行为是「跳到下一条建议」，那是卡的交互，不是产品的入口。
        // 侧栏已开着 → 再点一次收起（同 Grammarly 的 toggle 手感）。
        if InlineController.shared.isSidebarVisible {
            InlineController.shared.hideSidebar()
        } else {
            InlineController.shared.showSidebar()
        }
    }
}

private final class BallView: NSView {
    weak var ball: FloatBall?
    init(ball: FloatBall) { self.ball = ball; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let b = ball else { return }
        BallArt.draw(in: bounds, phase: b.phase, count: b.count, severity: b.severity)
    }

    override func mouseDown(with event: NSEvent) { ball?.handleLeftClick() }
    override func rightMouseDown(with event: NSEvent) { ball?.handleRightClick() }
}

/// 球的绘制实现（唯一一份）：上屏的 BallView 与离屏快照共用，
/// 避免「截图好看、上屏另一套」这种自欺欺人的证据。
enum BallArt {

    static func draw(in bounds: NSRect, phase: FloatBall.Phase, count n: Int, severity: UnderlineKind) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: r).fill()

        switch phase {
        case .unknown:
            // 空心灰环 + ?：明确表达「我不知道」，和绿点、数字环一眼区分
            let grey = NSColor.tertiaryLabelColor
            grey.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 1.5
            ring.stroke()
            let glyph = "?" as NSString
            let gAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: grey,
            ]
            let gs = glyph.size(withAttributes: gAttrs)
            glyph.draw(at: NSPoint(x: bounds.midX - gs.width / 2, y: bounds.midY - gs.height / 2),
                       withAttributes: gAttrs)

        case .clear:
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill()

        case .issues:
            let color: NSColor = severity.color
            color.setStroke()
            let ring = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5))
            ring.lineWidth = 2.5
            ring.stroke()

            let text = "\(min(n, 99))" as NSString
            let font = NSFont.systemFont(ofSize: n > 9 ? 9 : 11, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let sz = text.size(withAttributes: attrs)
            text.draw(at: NSPoint(x: bounds.midX - sz.width / 2, y: bounds.midY - sz.height / 2),
                      withAttributes: attrs)
        }
    }

    /// 离屏渲染三态成一张 PNG（取证用，不开窗、不上屏）
    /// 判据：文件存在且宽高符合期望；像素级差异由 SVG/PNG 目视确认。
    @discardableResult
    static func snapshot(to path: String, cell: CGFloat = 88) -> Bool {
        let states: [(FloatBall.Phase, Int, UnderlineKind)] = [
            (.unknown, 0, .grammar),
            (.clear, 0, .grammar),
            (.issues, 3, .grammar),
        ]
        let w = cell * CGFloat(states.count)
        let h = cell
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        // 外观固定成浅色：系统一进深色模式，windowBackgroundColor 会变黑，
        // 同一份代码渲出来的图就不同 —— 视觉基线因此会「无故变红」（11-19 夜实测）
        let forced = NSAppearance(named: .aqua)
        forced?.performAsCurrentDrawingAppearance {
            renderStates(states, cell: cell)
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: url)) != nil
    }

    private static func renderStates(_ states: [(FloatBall.Phase, Int, UnderlineKind)],
                                     cell: CGFloat) {
        let w = CGFloat(states.count) * cell, h = cell
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        for (i, st) in states.enumerated() {
            let cellRect = NSRect(x: CGFloat(i) * cell, y: 0, width: cell, height: cell)
            let ballRect = cellRect.insetBy(dx: (cell - 22 * 2) / 2, dy: (cell - 22 * 2) / 2)
            NSGraphicsContext.current?.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: ballRect.minX, yBy: ballRect.minY)
            t.scale(by: 2)     // 2 倍放大，肉眼能看清
            t.concat()
            BallArt.draw(in: NSRect(x: 0, y: 0, width: 22, height: 22), phase: st.0, count: st.1, severity: st.2)
            NSGraphicsContext.current?.restoreGraphicsState()
        }
    }
}
