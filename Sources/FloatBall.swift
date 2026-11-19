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

    /// 三态。unknown 是显式状态，不是「隐藏」：
    /// 隐藏时用户看不见任何信号，等于「插件死了」，和「我不知道」不是一回事。
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

    private func place(near q: CGRect) {
        // Quartz → AppKit：y 用主屏高度翻
        let h = NSScreen.screens.first?.frame.height ?? 900
        let x = q.maxX + 6
        let yTop = q.minY + 2
        let appKitY = h - yTop - size
        setFrame(NSRect(x: x, y: appKitY, width: size, height: size), display: false)
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
        guard phase == .issues, count > 0 else { return }
        HoverCoordinator.shared.openNextIssue()
    }
}

private final class BallView: NSView {
    weak var ball: FloatBall?
    init(ball: FloatBall) { self.ball = ball; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let b = ball else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)

        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: r).fill()

        switch b.phase {
        case .unknown:
            // 空心灰环 + ?：明确表达「我不知道」，和绿点、数字环都能一眼区分
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
            let n = b.count
            let color: NSColor = b.severity.color
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

    override func mouseDown(with event: NSEvent) { ball?.handleLeftClick() }
    override func rightMouseDown(with event: NSEvent) { ball?.handleRightClick() }
}
