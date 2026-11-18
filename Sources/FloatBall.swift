// FloatBall.swift — 贴着输入框的浮动球（Grammarly 那个「我在盯着」的视觉信号）
//
// 为什么必须有它：爹地「完全没反应」的直接原因不是没检查，是**没有可见反馈**。
// 线画在字下面，写邮件时视线在行尾，根本看不到。
//
// 形态（按知洲 11-18 口径）：
//   · 贴输入框右下角悬浮，22pt
//   · 无问题 = 绿点；有问题 = 环 + 环内数字（N 条），环色按最严重类别
//   · 右键 = 「在此 App 关闭」→ 加进排除名单，立刻消失
//   · 左键 = 跳到下一条（有下一张卡片时）
//   · 从不抢焦点（nonactivatingPanel + ignoresMouseEvents=false 只吃自己那 22pt）

import AppKit

final class FloatBall: NSPanel {

    static let shared = FloatBall()

    fileprivate(set) var count = 0
    fileprivate(set) var severity: UnderlineKind = .grammar
    fileprivate var pid: pid_t = 0
    private let size: CGFloat = 22

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
        var count: Int
        var severity: UnderlineKind
        var pid: pid_t
        var anchor: CGRect          // Quartz（左上原点）
    }

    /// 每次检查后调用：count==0 显示绿点；有 N 条显示环+数字
    func update(_ st: State?) {
        guard let st else { hide(); return }
        guard st.count > 0 else {
            count = 0; severity = .grammar; pid = st.pid
            place(near: st.anchor)
            orderFrontRegardless()
            (contentView as? BallView)?.needsDisplay = true
            return
        }
        count = st.count
        severity = st.severity
        pid = st.pid
        place(near: st.anchor)
        orderFrontRegardless()
        (contentView as? BallView)?.needsDisplay = true
    }

    func hide() {
        count = 0
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
        let title = count == 0 ? "EnglishWriter：这一处没问题" : "EnglishWriter：\(count) 条建议"
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
        guard count > 0 else { return }
        HoverCoordinator.shared.openNextIssue()
    }
}

private final class BallView: NSView {
    weak var ball: FloatBall?
    init(ball: FloatBall) { self.ball = ball; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard let b = ball else { return }
        let n = b.count
        let sev = b.severity
        let r = bounds.insetBy(dx: 1, dy: 1)

        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: r).fill()

        if n == 0 {
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 6, dy: 6)).fill()
            return
        }
        let color: NSColor = sev.color
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

    override func mouseDown(with event: NSEvent) { ball?.handleLeftClick() }
    override func rightMouseDown(with event: NSEvent) { ball?.handleRightClick() }
}
