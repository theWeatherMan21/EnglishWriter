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
            // 图标旁边加两个字母：细铅笔在一排菜单栏图标里几乎看不见，
            // 爹地 11-23 因此以为 App 没起来（实测 statusItem 在屏上，只是认不出）。
            button.title = " EW"
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
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

        // 菜单栏图标自证：--status-probe 打印 statusItem 的窗口与屏几何后退出。
        // 为什么需要：爹地 11-23 报「看不到图标」，光看代码没法区分
        // 「没创建」「被系统藏进溢出区」「创建了但在屏外」——这三件事修法完全不同。
        if CommandLine.arguments.contains("--status-probe") {
            // 立刻打印一次，再等 1.2 秒（状态栏条目是 runloop 起来后才布局的）打印第二次
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                let b2 = self.statusItem.button
                let w2 = b2?.window
                let f2 = w2?.frame ?? .zero
                print("status-probe[+1.2s]: isVisible=\(w2?.isVisible ?? false) frame=(\(Int(f2.minX)),\(Int(f2.minY)),\(Int(f2.width))x\(Int(f2.height)))")
                exit(0)
            }
            let btn = statusItem.button
            let win = btn?.window
            let scr = NSScreen.screens.first
            let f = win?.frame ?? .zero
            let vis = win?.isVisible ?? false
            print("status-probe: exists=\(statusItem != nil) isVisible=\(vis) frame=(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height)))")
            print("status-probe: screen=\((scr?.frame.debugDescription ?? "?")) menuBarHeight=\(NSStatusBar.system.thickness)")
            print("status-probe: onScreen=\(scr?.frame.contains(f) ?? false) buttonImage=\(btn?.image != nil) imageSize=\(btn?.image?.size.debugDescription ?? "nil")")
            for name in ["pencil.and.outline", "pencil.line", "square.and.pencil", "text.badge.checkmark"] {
                let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
                print("status-probe: symbol \(name) = \(img == nil ? "nil" : "\(img!.size)")")
            }
        }

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
        // CLI 验收/探针模式只做它自己的事：绝不装全局点击监听，否则会和常驻实例抢点击
        let cliFlagsInApp = ["--realshot", "--axdump", "--axprobe", "--axcheck", "--axwatch",
                             "--axaccept", "--probe-mail", "--passive", "--axprobe-chrome",
                             "--demo-offscreen"]   // 离屏试用窗口：不许装全局监听，免得和常驻实例抢点击
        let isProbeMode = ProcessInfo.processInfo.arguments.contains { cliFlagsInApp.contains($0) }
        if ProcessInfo.processInfo.environment["EW_NO_INLINE"] != "1", !isProbeMode {
            if EnginePrefs.ltEnabled() {
                LocalEngineBootstrap.ensureRunning()   // 只在开关打开时才拉 JVM（默认关，省 368MB）
            }
            InlineController.shared.start()
            // 谁在写这份日志：常驻实例带 pid 落一条，排查「两个实例抢点击」时一眼可见
            CheckLog.append(.init(kind: "instance", pid: getpid(), app: "英文写作助手",
                                  role: "resident", textLen: 0, sentenceLen: 0,
                                  itemCount: 0, rectCount: 0, elapsed: "-",
                                  err: "resident start", at: Date()))
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
                || args.contains("--axprobe-chrome") || args.contains("--passive") || args.contains("--probe-mail")
                || args.contains("--mail-selftest") {
                // A 层：AXValue 直写 → checkNow；B 层：只监听真人键入。两都不建窗口/不激活/不敲键/不截屏
                Task { @MainActor in
                    if args.contains("--axwatch") { await AXCheck.watch(args) }
                    else if args.contains("--axaccept") { await AXCheck.acceptRun(args) }
                    else if args.contains("--axprobe-chrome") { await ChromeProbe.run(args) }
                    else if args.contains("--passive") { await Passive.run(args) }
                    else if args.contains("--mail-selftest") { exit(MailSelfTest.run(args)) }
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
// --privacy / --style / --ui / --webui 等分组开关也必须能单独跑，
// 否则它们掉进常驻模式被单实例锁 exit 0，验收通道等于断的（知澜 11-19 实锤）
if argv.contains("--selftest") || argv.contains("--privacy") || argv.contains("--style")
    || argv.contains("--ui") || argv.contains("--score")
    || argv.contains("--lang") || argv.contains("--diffhl") || argv.contains("--m3") || argv.contains("--settings")
    || argv.contains("--clickdiag") || argv.contains("--rewrite-selftest") || argv.contains("--acceptflow") {
    exit(SelfTest.run(argv))
}

// 视觉基线逐像素比对（离屏）
if argv.contains("--pngdiff") {
    exit(PNGDiff.run(argv))
}

// Mail 块路径的离屏验收（不碰真实 Mail）：mail-selftest
if argv.contains("--mail-selftest") {
    exit(MailSelfTest.run(argv))
}

// 业务英文离线质量回归（召回 / 误报）
if argv.contains("--quality") {
    exit(QualityTests.run(argv))
}

// key window 可编辑元素（无焦点时的确定性回退路径）
if argv.contains("--keywin") {
    exit(KeyWinProbe.run(argv))
}

// 引擎就绪状态（给 CI 对账：curl 说通、App 也必须说通）
if argv.contains("--lt-ready") {
    let sem = DispatchSemaphore(value: 0)
    var ok = false
    Task {
        ok = await LocalEngine.available(force: true)
        sem.signal()
    }
    sem.wait()
    print("lt-ready: \(ok ? "就绪" : "未就绪")")
    exit(ok ? 0 : 1)
}

// 真机闭环核对：把日志算成一条结论（出线 / 点中 / 写回 / 失败原因）
if let i = argv.firstIndex(of: "--e2e-report") {
    let mins = (i + 1 < argv.count) ? (Int(argv[i + 1]) ?? 10) : 10
    exit(E2EReport.run(minutes: mins))
}

// 画线率 KPI（rectCount / 有建议次数），按 App 汇总 check-log
if argv.contains("--kpi") {
    exit(KPI.run(argv))
}

// M3 链路驱动（离线、不建窗口）：命中 → 弹出 → 接受 → 撤销 → 忽略，行级日志
if argv.contains("--m3-drive") {
    let i = argv.firstIndex(of: "--m3-drive")!
    let out = (i + 1 < argv.count && !argv[i + 1].hasPrefix("--")) ? argv[i + 1] : "out/m3-drive.log"
    let r = M3Drive.run(out: out)
    print("=== M3 链路驱动：PASS \(r.pass) / FAIL \(r.fail) ===")
    exit(r.fail == 0 ? 0 : 1)
}

// M3 悬停监听的**真实事件**取证：挂全局 mouseMoved 并真收到一次合成事件（不建窗口）
if argv.contains("--m3-monitors") {
    exit(M3MonitorProbe.run())
}

// 真模型改写 / 语气（--live-rewrite / --live-tone）：key 只走环境变量
if argv.contains("--docscan-file") {
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    Task { ok = await DocScanCLI.run(argv); sem.signal() }
    sem.wait()
    exit(ok ? 0 : 1)
}

if argv.contains("--ax-elements") {
    var code: Int32 = 0
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
        code = AXElementsProbe.run(argv)
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(code)
}

if argv.contains("--settings-snapshot") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SettingsSnapshot.run(argv) }
    exit(code)
}

if argv.contains("--sidebar-snapshot") {
    var code: Int32 = 0
    MainActor.assumeIsolated { code = SidebarSnapshot.run(argv) }
    exit(code)
}

if argv.contains("--ball-snapshot") {
    let out = argv.firstIndex(of: "--ball-snapshot").flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
        ?? (ProcessInfo.processInfo.environment["EW_OUT"].map { $0 + "/ball-states.png" })
        ?? (FileManager.default.currentDirectoryPath + "/out/ball-states.png")
    let ok = BallArt.snapshot(to: out)
    print(ok ? "球态快照：\(out)" : "球态快照失败：\(out)")
    exit(ok ? 0 : 1)
}
if argv.contains("--webui") {
    exit(WebUISelfTest.run(argv))
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
        if argv.contains("--live-rewrite") { ok = await LiveRewriteTests.runBatch(labels: Rewrite.defaultLabels, tag: "rewrite") && ok }
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
    || argv.contains("--mail-selftest")
    || argv.contains("--axprobe-chrome") {
    appDelegate.realShotArgs = argv
}
// MARK: 单实例 & 模式判定
// 两个实例同时跑 = 两个全局点击监听抢同一批点击（11-19 实测：第一次被空 specs 的实例接住，
// 第二次谁都没接到）。所以：常驻模式用一个文件锁，抢不到锁就退出。
let cliFlags = ["--selftest", "--mail-selftest", "--kpi", "--e2e-report", "--keywin", "--quality", "--realshot", "--axdump", "--axprobe",
                "--axcheck", "--axwatch", "--axaccept", "--probe-mail", "--passive", "--axprobe-chrome",
                "--sidebar-snapshot", "--settings-snapshot", "--ball-snapshot", "--status-probe"]
let isCLIMode = argv.contains { cliFlags.contains($0) }
if !isCLIMode {
    let lockPath = (NSHomeDirectory() as NSString)
        .appendingPathComponent("Library/Application Support/EnglishWriter/resident.lock")
    try? FileManager.default.createDirectory(atPath: (lockPath as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    if fd >= 0, flock(fd, LOCK_EX | LOCK_NB) != 0 {
        FileHandle.standardError.write("[single-instance] 已有常驻实例在跑，本实例退出\n".data(using: .utf8)!)
        exit(0)
    }
}

application.run()
