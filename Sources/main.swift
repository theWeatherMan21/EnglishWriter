// main.swift — 入口：菜单栏常驻，无 Dock 图标、无主窗口
// 无 Timer 轮询 / 无 AXObserver / 无 CGEventTap —— 只在用户点菜单那一刻读一次 AX。

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var model: AppModel!

    func applicationDidFinishLaunching(_ note: Notification) {
        model = AppModel()
        AXTarget.shared.startTracking()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "英文写作助手")
            button.image?.isTemplate = true
            button.toolTip = "英文写作助手（选中文字后点这里）"
        }

        let menu = NSMenu()
        let editItem = NSMenuItem(title: "改选中文本", action: #selector(triggerAction), keyEquivalent: "")
        editItem.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: nil)
        menu.addItem(editItem)
        let undoItem = NSMenuItem(title: "撤销上次替换", action: #selector(undoAction), keyEquivalent: "")
        menu.addItem(undoItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "跑探针（验 Mail 可读/可写）", action: #selector(probeAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "设置…", action: #selector(settingsAction), keyEquivalent: ","))
        if !AXPermission.granted() {
            menu.addItem(NSMenuItem(title: "授辅助功能权限…", action: #selector(permissionAction), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu

        // 无头探针：EW_PROBE_EXIT=1 时跑一次探针、打印 JSON、退出（给验收 / 自动化用）
        if ProcessInfo.processInfo.environment["EW_PROBE_EXIT"] == "1" {
            let report = Probe.run(model: model)
            if let d = try? JSONEncoder().encode(report),
               let s = String(data: d, encoding: .utf8) { print(s) }
            exit(report.permission ? 0 : 3)
        }

        // 首次运行且未配置：直接把设置窗口摆出来（用户点一下就完成配置）
        // EW_NO_WINDOW=1 用于无头测量，绝不弹窗
        if !SettingsStore.load().isComplete, ProcessInfo.processInfo.environment["EW_NO_WINDOW"] != "1" {
            SettingsWindowController.shared.show(model: model)
        }
    }

    @MainActor @objc private func triggerAction() { model.trigger() }

    @MainActor @objc private func undoAction() {
        if model.canUndo { model.undo() }
        else { model.showPanel(phase: .info("没有可撤销的替换（只记录本次运行内的最后一次）")) }
    }

    @MainActor @objc private func settingsAction() { SettingsWindowController.shared.show(model: model) }

    @MainActor @objc private func probeAction() {
        let report = Probe.run(model: model)
        let alert = NSAlert()
        alert.messageText = report.permission ? "探针已跑完" : "还没给辅助功能权限"
        alert.informativeText = Probe.summary(report)
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "打开系统设置")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn { AXPermission.openSettingsPane() }
    }

    @objc private func permissionAction() {
        _ = AXPermission.request()
        AXPermission.openSettingsPane()
    }

    @objc private func quitAction() { NSApp.terminate(nil) }
}

// MARK: - entry

let argv = CommandLine.arguments
if argv.contains("--selftest") {
    exit(SelfTest.run(argv))
}

let appDelegate = AppDelegate()
let application = NSApplication.shared
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
