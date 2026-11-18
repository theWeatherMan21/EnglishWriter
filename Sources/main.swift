// main.swift — 入口：菜单栏常驻，无 Dock 图标、无主窗口
// v0.2：常驻 + AXObserver 输入感知 + 行内下划线（《Grammarly 同款》口径）

import AppKit

// MARK: - 本地引擎自举（静默，不弹窗）

enum LocalEngineBootstrap {
    static func scriptPath() -> String? {
        var candidates: [String] = []
        if let res = Bundle.main.resourcePath { candidates.append(res + "/languagetool-up.sh") }
        candidates.append(NSHomeDirectory() + "/dev/EnglishWriter/scripts/languagetool-up.sh")
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static var lastSpawn: Date = .distantPast

    /// 节流版：闲置退出之后用户继续打字时自动把 LT 拉回来（120s 内最多一次，避免反复起 JVM）
    static func ensureRunningThrottled() {
        guard Date().timeIntervalSince(lastSpawn) > 120 else { return }
        lastSpawn = Date()
        ensureRunning()
    }

    /// 已经在跑就什么都不做；没装也不打扰用户（回落模型接口）
    static func ensureRunning() {
        Task.detached {
            if await LocalEngine.available(force: true) { return }
            guard let script = scriptPath() else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            do {
                try p.run()
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if !out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    FileHandle.standardError.write(("[lt] " + out + "\n").data(using: .utf8)!)
                }
            } catch {
                FileHandle.standardError.write(("[lt] spawn failed: \(error)\n").data(using: .utf8)!)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var model: AppModel!
    private var demo: DemoController?
    /// --realshot 传进来的参数（真机验收器在 didFinishLaunching 之后跑）
    var realShotArgs: [String]?

    func applicationDidFinishLaunching(_ note: Notification) {
        model = AppModel()
        AXTarget.shared.startTracking()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "英文写作助手")
            button.image?.isTemplate = true
            button.toolTip = "英文写作助手（常驻检查，错误处自动画线）"
        }

        let menu = NSMenu()
        let editItem = NSMenuItem(title: "改选中文本", action: #selector(triggerAction), keyEquivalent: "")
        editItem.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: nil)
        menu.addItem(editItem)
        let undoItem = NSMenuItem(title: "撤销上次替换", action: #selector(undoAction), keyEquivalent: "")
        menu.addItem(undoItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "立即检查当前段落", action: #selector(checkNowAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "清掉下划线", action: #selector(clearAction), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "跑探针（验 Mail 可读/可写）", action: #selector(probeAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "行内渲染自测…", action: #selector(demoAction), keyEquivalent: ""))
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

        // 本机 HTTP 接口（给浏览器扩展用）：只绑 127.0.0.1 + token 鉴权
        LocalAPI.shared.start()

        // LT 是 JVM（常驻 368MB）：闲置 10 分钟就让它退出，下次检查再按需拉起
        LocalEngine.startIdleWatchdog()

        // 常驻输入感知（M2）：AXObserver + 800ms 去抖；无授权时静默降级
        if ProcessInfo.processInfo.environment["EW_NO_INLINE"] != "1" {
            LocalEngineBootstrap.ensureRunning()     // 本地引擎没起就悄悄拉起来（不弹窗）
            InlineController.shared.start()
        }

        // 首次运行且未配置：直接把设置窗口摆出来（用户点一下就完成配置）
        // EW_NO_WINDOW=1 用于无头测量，绝不弹窗
        if realShotArgs == nil, !SettingsStore.load().isComplete,
           ProcessInfo.processInfo.environment["EW_NO_WINDOW"] != "1" {
            SettingsWindowController.shared.show(model: model)
        }

        // 真机验收器（Mail 下划线截图）：必须由 App 自己跑，才有辅助功能授权
        if let args = realShotArgs {
            if args.contains("--axcheck") || args.contains("--axwatch") || args.contains("--axaccept")
                || args.contains("--axprobe-chrome") || args.contains("--passive") {
                // A 层：AXValue 直写 → checkNow；B 层：只监听真人键入。两都不建窗口/不激活/不敲键/不截屏
                Task { @MainActor in
                    if args.contains("--axwatch") { await AXCheck.watch(args) }
                    else if args.contains("--axaccept") { await AXCheck.acceptRun(args) }
                    else if args.contains("--axprobe-chrome") { await ChromeProbe.run(args) }
                    else if args.contains("--passive") { await Passive.run(args) }
                    else { await AXCheck.run(args) }
                }
            } else {
                Task { @MainActor in await RealShot.run(args) }
            }
        }
    }

    @MainActor @objc private func checkNowAction() { InlineController.shared.checkNow() }
    @MainActor @objc private func clearAction() { InlineController.shared.clearUnderlines() }

    @MainActor @objc private func demoAction() {
        let d = DemoController()
        demo = d
        let opts = DemoController.DemoOptions(shotPath: nil)
        _ = d.run(opts)
    }

    @MainActor @objc private func triggerAction() { model.trigger() }

    @MainActor @objc private func undoAction() {
        if InlineController.shared.undoLastAccept() { return }
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

// M1 渲染自测台：--demo / --demo-selfcheck / --ax-selftest / --snapshot <path> / --shot <path>
if argv.contains("--demo") || argv.contains("--demo-selfcheck")
    || argv.contains("--ax-selftest") || argv.contains("--snapshot") {
    var opts = DemoController.DemoOptions()
    opts.selfCheckOnly = argv.contains("--demo-selfcheck")
    opts.axSelfCheck = argv.contains("--ax-selftest")
    if let i = argv.firstIndex(of: "--snapshot"), i + 1 < argv.count { opts.snapshotPath = argv[i + 1] }
    if let i = argv.firstIndex(of: "--shot"), i + 1 < argv.count { opts.shotPath = argv[i + 1] }
    let demoApp = NSApplication.shared
    demoApp.setActivationPolicy(.accessory)
    var code: Int32 = 0
    var controller: DemoController?
    MainActor.assumeIsolated {
        let c = DemoController()
        controller = c
        code = c.run(opts)
    }
    if opts.shotPath == nil { exit(code) }      // 断言/快照模式：跑完就退，不留窗口
    demoApp.run()                               // 屏幕截图模式：等回调里 terminate
    exit(code)
}

let appDelegate = AppDelegate()
let application = NSApplication.shared
application.delegate = appDelegate
application.setActivationPolicy(.accessory)

// 真机验收器：--realshot <outDir> …，由 App 自己发起（TCC 授权只认这个二进制）
if argv.contains("--realshot") || argv.contains("--axdump") || argv.contains("--axprobe")
    || argv.contains("--axcheck") || argv.contains("--axwatch") || argv.contains("--axaccept") || argv.contains("--passive")
    || argv.contains("--axprobe-chrome") {
    appDelegate.realShotArgs = argv
}
application.run()
