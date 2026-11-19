// GoalsWindow.swift — P4 写作目标设置窗（零预设：四项默认全空）
//
// 四项：受众 / 正式度 / 意图 / 领域。每项第一行都是「未设置」，
// 不替用户选任何默认值（爹地的规矩），未设置就是未设置。

import AppKit

final class GoalsWindow: NSObject, NSWindowDelegate {

    static let shared = GoalsWindow()

    private var window: NSWindow?
    private var pickers: [NSPopUpButton] = []
    private let fields: [(String, [String])] = [
        ("受众", ["未设置", "客户", "同事", "上级", "通用"]),
        ("正式度", ["未设置", "随意", "偏随意", "中性", "偏正式", "正式"]),
        ("意图", ["未设置", "告知", "请求", "说服", "致歉"]),
        ("领域", ["未设置", "商务", "学术", "日常"]),
    ]

    @MainActor
    func show() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }

        let h: CGFloat = 56 + CGFloat(fields.count) * 44 + 56
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: h),
                         styleMask: [.titled, .closable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "写作目标（不设也行）"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()
        window = w

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: h))
        let g = GoalsStore.load()
        pickers.removeAll()

        for (i, (name, options)) in fields.enumerated() {
            let y = h - 56 - CGFloat(i + 1) * 44
            let label = NSTextField(labelWithString: name)
            label.font = NSFont.systemFont(ofSize: 12)
            label.frame = NSRect(x: 20, y: y + 6, width: 60, height: 18)
            root.addSubview(label)

            let pop = NSPopUpButton(frame: NSRect(x: 88, y: y, width: 270, height: 26), pullsDown: false)
            pop.addItems(withTitles: options)
            // 回填已有设置（第一项永远是「未设置」= 空）
            let current: String? = [g.audience, g.formality.map { fields[1].1[$0 + 1] }, g.intent, g.domain][i]
            pop.selectItem(withTitle: current ?? "未设置")
            root.addSubview(pop)
            pickers.append(pop)
        }

        let clear = NSButton(title: "清除全部", target: self, action: #selector(clearAll))
        clear.bezelStyle = .rounded
        clear.frame = NSRect(x: 20, y: 16, width: 92, height: 28)
        root.addSubview(clear)

        let save = NSButton(title: "保存", target: self, action: #selector(saveGoals))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: 268, y: 16, width: 92, height: 28)
        root.addSubview(save)

        let hint = NSTextField(labelWithString: "未设置 = 不参与评分与提示词（不替你假设）")
        hint.font = NSFont.systemFont(ofSize: 10)
        hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 120, y: 20, width: 150, height: 16)
        root.addSubview(hint)

        w.contentView = root
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func saveGoals() {
        func val(_ i: Int) -> String? {
            let t = pickers[i].titleOfSelectedItem ?? "未设置"
            return t == "未设置" ? nil : t
        }
        var g = Goals()
        g.audience = val(0)
        g.formality = pickers[1].indexOfSelectedItem <= 0 ? nil : pickers[1].indexOfSelectedItem - 1
        g.intent = val(2)
        g.domain = val(3)
        GoalsStore.save(g)
        window?.close()
    }

    @objc private func clearAll() {
        GoalsStore.clear()
        window?.close()
    }

    func windowWillClose(_ n: Notification) { window = nil }
}
