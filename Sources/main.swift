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
    /// 改写候选菜单的暂存（点选后才应用）
    private var rewritePending: (cands: [RewriteCandidate], segment: String, segStart: Int)?

    func applicationDidFinishLaunching(_ note: Notification) {
        // ★ 2026-11-18：常驻日志 + 检查事件落盘（读者是自检 cron / 婉宜，不是用户）。
        //   格式固定 `YYYY-MM-DD HH:mm:ss LEVEL tag key=value`，selfcheck 一条 normal 全覆盖。
        AppLog.info("boot", "pid=\(getpid()) args=\(CommandLine.arguments.dropFirst().joined(separator: " "))")
        InlineController.shared.onCheck = { e in
            // 只把「引擎真失败」记 ERROR。焦点不在输入框 / 中文 / 排除 App 都是正常跳过：
            // 常驻检查在 Telegram、Finder 上也会被触发，那些不算错误（否则日志天天误报）。
            let skipKinds: Set<String> = ["no-text", "skip-cjk", "skip-excluded", "attach-app", "attach-el-fail"]
            let engineFailed = e.err != "-" && !e.err.isEmpty
                && !e.err.contains("没有焦点") && !e.err.contains("读不到文本框")
            let bad = engineFailed && !skipKinds.contains(e.kind)
            AppLog.write(bad ? "ERROR" : "INFO", "check",
                         "kind=\(e.kind) app=\(e.app) pid=\(e.pid) textLen=\(e.textLen) items=\(e.itemCount) rects=\(e.rectCount) elapsed=\(e.elapsed) err=\(e.err)")
        }
        model = AppModel()
        AppModel.diagRef = model
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
        if Rewrite.isAvailable() {
            menu.addItem(NSMenuItem(title: "改写选中段落…", action: #selector(rewriteAction), keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "建议侧栏…", action: #selector(sidebarAction), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "清掉下划线", action: #selector(clearAction), keyEquivalent: ""))
        menu.addItem(.separator())
        // 面向用户：点一下就能看见整套效果（不依赖 Mail/Word 能不能读文本）
        menu.addItem(NSMenuItem(title: "演示…", action: #selector(demoLiveAction), keyEquivalent: "e"))
        menu.addItem(NSMenuItem(title: "写作目标…", action: #selector(goalsAction), keyEquivalent: "g"))
        // ★ 调试控件（探针 / 行内渲染自测）release 不出现，只有 EW_DEBUG=1 才挂菜单——
        //   读者是我，不是用户（11-18 红线）。
        if SettingsView.debugUI {
            menu.addItem(NSMenuItem(title: "跑探针（验 Mail 可读/可写）", action: #selector(probeAction), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "行内渲染自测…", action: #selector(demoAction), keyEquivalent: ""))
        }
        // ★ 2026-11-18 爹地红线：诊断窗口能力保留，但 release 常驻 UI 不出现入口。
        //   只有 EW_DEBUG=1 才挂菜单项（排障走命令行/日志，不给用户按钮）。
        if SettingsView.debugUI {
            menu.addItem(NSMenuItem(title: "诊断…", action: #selector(diagAction), keyEquivalent: "d"))
        }
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
            if EnginePrefs.ltEnabled() {
                LocalEngineBootstrap.ensureRunning()   // 只在开关打开时才拉 JVM（默认关，省 368MB）
            }
            InlineController.shared.start()
        }

        // 首次运行且未配置：直接把设置窗口摆出来（用户点一下就完成配置）
        // EW_NO_WINDOW=1 用于无头测量，绝不弹窗
        if realShotArgs == nil, !SettingsStore.load().isComplete,
           ProcessInfo.processInfo.environment["EW_NO_WINDOW"] != "1" {
            SettingsWindowController.shared.show(model: model)
        }

        if realShotArgs == nil, ProcessInfo.processInfo.arguments.contains("--demo-live") {
            Task { @MainActor in DemoLive.shared.show() }
        }

        // 真机验收器（Mail 下划线截图）：必须由 App 自己跑，才有辅助功能授权
        if let args = realShotArgs {
            if args.contains("--axcheck") || args.contains("--axwatch") || args.contains("--axaccept")
                || args.contains("--axprobe-chrome") || args.contains("--passive") || args.contains("--probe-mail") {
                // A 层：AXValue 直写 → checkNow；B 层：只监听真人键入。两都不建窗口/不激活/不敲键/不截屏
                Task { @MainActor in
                    if args.contains("--axwatch") { await AXCheck.watch(args) }
                    else if args.contains("--axaccept") { await AXCheck.acceptRun(args) }
                    else if args.contains("--axprobe-chrome") { await ChromeProbe.run(args) }
                    else if args.contains("--passive") { await Passive.run(args) }
                    else if args.contains("--probe-mail"), args.contains("--wait-english") {
                        let ok = await MailProbe.waitForEnglish(args); exit(ok ? 0 : 1)
                    }
                    else if args.contains("--probe-mail") { let ok = await MailProbe.run(args); exit(ok ? 0 : 1) }
                    else { await AXCheck.run(args) }
                }
            } else {
                Task { @MainActor in await RealShot.run(args) }
            }
        }
    }

    @MainActor @objc private func checkNowAction() { InlineController.shared.checkNow() }
    @MainActor @objc private func demoLiveAction() { DemoLive.shared.show() }
    @MainActor @objc private func goalsAction() { GoalsWindow.shared.show() }
    @MainActor @objc private func sidebarAction() { InlineController.shared.showSidebar() }

    /// 改写选中段落：选中才亮（没选区就提示），模型没配时菜单项根本不出现
    @MainActor @objc private func rewriteAction() {
        let ctrl = InlineController.shared
        guard let ctx = ctrl.rewriteContext() else {
            ctrl.noteForRewrite("请先选中要改写的英文段落")
            return
        }
        let ns = ctx.full as NSString
        let segment = ns.substring(with: ctx.sel)
        let cfg = SettingsStore.load()
        guard cfg.isComplete else { ctrl.noteForRewrite("模型三项没填"); return }
        ctrl.noteForRewrite("改写中…（模型返回约 10–40s）")
        Task { @MainActor in
            do {
                let cands = try await Rewrite.suggest(segment: segment, config: cfg)
                guard !cands.isEmpty else { ctrl.noteForRewrite("模型没给出可用候选"); return }
                presentCandidateMenu(cands, segment: segment, segStart: ctx.sel.location, ctrl: ctrl)
            } catch {
                ctrl.noteForRewrite("改写失败：\(error)")
            }
        }
    }

    @MainActor private func presentCandidateMenu(_ cands: [RewriteCandidate], segment: String,
                                                 segStart: Int, ctrl: InlineController) {
        let menu = NSMenu()
        for (i, c) in cands.enumerated() {
            let item = NSMenuItem(title: "\(c.label)（\(c.items.count) 处）",
                                  action: #selector(applyRewriteFromMenu(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            rewritePending = (cands, segment, segStart)
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @MainActor @objc private func applyRewriteFromMenu(_ sender: NSMenuItem) {
        guard let pending = rewritePending, sender.tag < pending.cands.count else { return }
        let c = pending.cands[sender.tag]
        let n = Rewrite.apply(c, segment: pending.segment, segStart: pending.segStart, via: InlineController.shared)
        InlineController.shared.noteForRewrite(n > 0 ? "已应用「\(c.label)」：\(n) 处（⇧⌘Z 可撤销）" : "写回失败：该输入框不接受 AX 写入")
        rewritePending = nil
    }
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

    @MainActor @objc private func diagAction() { DiagWindowController.shared.show() }

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

// 真模型改写 / 语气（--live-rewrite / --live-tone）：key 只走环境变量
if argv.contains("--docscan-file") {
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    Task { ok = await DocScanCLI.run(argv); sem.signal() }
    sem.wait()
    exit(ok ? 0 : 1)
}

if argv.contains("--live-ab") {
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    Task { ok = await LiveAB.run(); sem.signal() }
    sem.wait()
    exit(ok ? 0 : 1)
}

if argv.contains("--live-rewrite") || argv.contains("--live-tone") {
    var ok = true
    let sem = DispatchSemaphore(value: 0)
    Task {
        if argv.contains("--live-rewrite") { ok = await LiveRewriteTests.runRewrite() && ok }
        if argv.contains("--live-tone") { ok = await LiveRewriteTests.runTone() && ok }
        sem.signal()
    }
    sem.wait()
    exit(ok ? 0 : 1)
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
    || argv.contains("--probe-mail")
    || argv.contains("--axprobe-chrome") {
    appDelegate.realShotArgs = argv
}
application.run()
