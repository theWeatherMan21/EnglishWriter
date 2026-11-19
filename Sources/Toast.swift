// Toast.swift — 一句话反馈（「已改 · ⌘Z 撤销」这类）
//
// 为什么需要：爹地点了「接受」之后，界面只是那行消失——他无法确认到底改没改、能不能退。
// Grammarly 每次接受都给一句提示。这里做最小版：贴屏幕中下方，3 秒自消，不抢焦点、不挡点击。

import AppKit

enum Toast {

    private static var panel: NSPanel?

    @MainActor
    static func show(_ text: String, seconds: Double = 3) {
        panel?.close()
        let font = NSFont.systemFont(ofSize: 13, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: attrs)
        let w = size.width + 32, h: CGFloat = 34

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true          // 不挡点击
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let bg = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        bg.wantsLayer = true
        bg.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        bg.layer?.cornerRadius = 10
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.separatorColor.cgColor

        let label = NSTextField(labelWithString: text)
        label.font = font
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 8, width: w, height: 18)
        bg.addSubview(label)
        p.contentView = bg

        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - w / 2, y: screen.minY + 120))
        }
        p.orderFrontRegardless()
        panel = p

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            p.close()
            if panel === p { panel = nil }
        }
    }
}
