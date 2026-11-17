// Passive.swift — 被动只读观察模式（--passive）与其自证（--passive --selfcheck）
//
// 目的：在不打扰爹地、不写任何内容、不上屏一个像素、不存正文的前提下，
// 收集「真机某 App 里打字会不会触发 AXObserver」的证据（Mail WebKit / Notes / 任意 App）。
//
// 铁律（对应 11-16 红线）：
//   · 只读：不 setText、不发键击、不截屏、不 activate 任何 App
//   · 下划线全程 globallySilent（clear() 也不复位），悬停卡片同样被压住
//   · 不弹卡片、不弹窗、不新建任何窗口
//   · 日志只存元信息：pid / 应用名 / role / 文本长度 / 句子长度 / 命中数 / 矩形数 / 耗时 / 错误
//     —— 正文一个字都不落盘
//
// 用法：
//   open -a 英文写作助手.app --args --passive <outFile> [--seconds 600]
//   open -a 英文写作助手.app --args --passive <outFile> --selfcheck [<evidence.json>]
// 产物：<outFile> 每行一条 JSON（JSONL）；--selfcheck 落 qa/evidence/passive-selfcheck.json
//
// 自证口径（仪器不能自述）：
//   A 段 正控：先在内存里调一次 applyEdits，断言写回计数确实 +1 —— 证明计数器是活的；
//   B 段 只读：走真实检查/渲染/悬停入口，断言写回、剪贴板、窗口上屏计数全 0；
//   C 段 字段：从落盘的 JSONL 读回，逐行断言七个必需字段齐全且可解析。

import AppKit

enum Passive {

    /// 每行日志的必需字段（自检逐条核；少一个就算仪器坏了）
    static let requiredFields = ["ts", "pid", "app", "role", "textLen", "rects", "elapsed"]

    // MARK: - 日志行（唯一序列化入口：run 与 selfcheck 共用，避免「自检走另一条路」）

    static func jsonObject(_ e: InlineController.CheckEvent, iso: ISO8601DateFormatter) -> [String: Any] {
        let ts = iso.string(from: e.at)
        return [
            // 必需七字段（canonical）
            "ts": ts,
            "pid": Int(e.pid),
            "app": e.app,
            "role": e.role,
            "textLen": e.textLen,
            "rects": e.rectCount,
            "elapsed": e.elapsed,
            // 附加字段（诊断用）
            "kind": e.kind,
            "sentenceLen": e.sentenceLen,
            "itemCount": e.itemCount,
            "err": e.err,
            // 兼容旧读者（parity 样例用过这两个名字）
            "at": ts,
            "rectCount": e.rectCount,
        ]
    }

    static func makeWriter(_ outPath: String) -> ((InlineController.CheckEvent) -> Void)? {
        let dir = (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outPath, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: outPath) else { return nil }
        fh.seekToEndOfFile()
        let iso = ISO8601DateFormatter()
        return { e in
            let obj = jsonObject(e, iso: iso)
            if let d = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: d, encoding: .utf8) {
                fh.write(Data((line + "\n").utf8))
            }
        }
    }

    // MARK: - 被动观察

    @MainActor
    static func run(_ argv: [String]) async {
        if argv.contains("--selfcheck") { selfcheck(argv) }

        var outPath = NSHomeDirectory() + "/dev/EnglishWriter/out/passive.jsonl"
        if let i = argv.firstIndex(of: "--passive"), i + 1 < argv.count { outPath = argv[i + 1] }
        var seconds: Double = 600
        if let i = argv.firstIndex(of: "--seconds"), i + 1 < argv.count, let d = Double(argv[i + 1]) { seconds = d }

        guard let write = makeWriter(outPath) else {
            FileHandle.standardError.write("[passive] 打不开输出文件\n".data(using: .utf8)!); exit(2)
        }

        UnderlineOverlay.globallySilent = true      // 一个像素都不上屏
        var counts: [String: Int] = [:]
        var byApp: [String: Int] = [:]

        InlineController.shared.onCheck = { e in
            counts[e.kind, default: 0] += 1
            if e.kind == "check" || e.kind == "render" { byApp[e.app, default: 0] += 1 }
            write(e)
        }

        InlineController.shared.reattachFrontmost()   // 补挂：启动时前台可能已经是你正在用的 App

        print("[passive] 只读观察中，\(Int(seconds))s 或 Ctrl-C 结束；日志 \(outPath)")
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        let summary: [String: Any] = ["events": counts, "byApp": byApp, "path": outPath,
                                      "audit": Audit.snapshot]
        if let d = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: d, encoding: .utf8) ?? "")
        }
        exit(0)
    }

    // MARK: - 自证

    @MainActor
    static func selfcheck(_ argv: [String]) -> Never {
        var evidencePath = FileManager.default.currentDirectoryPath + "/qa/evidence/passive-selfcheck.json"
        if let i = argv.firstIndex(of: "--selfcheck"), i + 1 < argv.count, !argv[i + 1].hasPrefix("--") {
            let p = argv[i + 1]
            evidencePath = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
        }
        let logPath = (evidencePath as NSString).deletingPathExtension + ".jsonl"

        var checks: [[String: Any]] = []
        func record(_ name: String, _ pass: Bool, _ detail: String) {
            checks.append(["name": name, "pass": pass, "detail": detail])
            print("\(pass ? "PASS" : "FAIL")  \(name)  — \(detail)")
        }

        UnderlineOverlay.globallySilent = true
        let ctrl = InlineController.shared          // 与真跑一样：先建常驻控制器（overlay 对象在此分配）
        _ = HoverCoordinator.shared                 // 悬停协调器同样先建（卡片窗口对象，never visible）

        // ---------- A 段：正控（证明计数器不是死代码）----------
        Audit.reset()
        let probe = DiffItem(start: 0, length: 3, original: "abc", replacement: "abd", type: "spelling", reason: "selfcheck")
        _ = applyEdits([probe], to: "abc")
        let positive = Audit.writeTotal
        record("正控·写回计数器是活的", positive == 1, "applyEdits 后 writeTotal=\(positive)，期望 1")

        // ---------- B 段：只读（真入口 + 真渲染，全程零副作用）----------
        let windowsBefore = NSApp.windows.count
        Audit.reset()

        guard let write = makeWriter(logPath) else {
            print("FAIL  自检日志打不开：\(logPath)"); exit(2)
        }
        // 1) 真实事件通道：把写入器挂到与 --passive 完全同一个回调上
        ctrl.onCheck = { e in write(e) }

        // 2) 真实检查入口（不指定元素：本进程没有焦点文本框，只走 no-text 分支，依然不许写）
        let selfPid = ProcessInfo.processInfo.processIdentifier
        ctrl.checkNow(for: selfPid, element: nil)
        // 3) 真实渲染入口：给一个有矩形的 spec，globallySilent 下只算不显
        let fakeRect = CGRect(x: 100, y: 100, width: 120, height: 14)
        ctrl.overlay.render([UnderlineSpec(rect: fakeRect, kind: .spelling, itemID: 0)])
        // 4) 真实悬停入口：全局静默时必须在第一行返回（不许弹卡）
        HoverCoordinator.shared.tickForAudit()
        // 5) 合成一条「有命中、有矩形」的事件，走同一序列化路径，供 C 段验字段
        write(InlineController.CheckEvent(kind: "render", pid: selfPid, app: "SelfCheck",
                                          role: "AXTextArea", textLen: 42, sentenceLen: 42,
                                          itemCount: 3, rectCount: 3, elapsed: "0ms",
                                          err: "-", at: Date()))

        let writeTotal = Audit.writeTotal
        record("只读·写回计数为 0", writeTotal == 0, "writeCalls=\(Audit.writeCalls)")
        record("只读·剪贴板写入为 0", Audit.pasteboardWrites == 0, "pasteboardWrites=\(Audit.pasteboardWrites)")
        record("只读·窗口上屏计数为 0", Audit.windowShows == 0, "windowShows=\(Audit.windowShows)")
        let windowsAfter = NSApp.windows.count
        // 菜单栏常驻图标（NSStatusBarWindow）是 App 本体的一部分，不是「屏幕上多出一块内容」；
        // 内容窗口（下划线覆盖层 / 卡片 / 设置 / 自测台）一个都不许可见。
        let systemChrome: Set<String> = ["NSStatusBarWindow", "NSMenuWindow", "_NSMenuWindow"]
        let visible = NSApp.windows
            .filter { $0.isVisible && !systemChrome.contains($0.className) }
            .map { $0.className }
        record("只读·没有新建窗口对象", windowsAfter == windowsBefore, "windows \(windowsBefore) → \(windowsAfter)")
        record("只读·没有任何内容窗口可见", visible.isEmpty,
               visible.isEmpty ? "除常驻菜单栏项（NSStatusBarWindow）外无可见窗口"
                               : "isVisible=true 的窗口：\(visible)")
        record("只读·overlay 未上屏", !ctrl.overlay.isVisible, "overlay.isVisible=\(ctrl.overlay.isVisible)")

        // ---------- C 段：日志字段（从磁盘读回来核，不信内存）----------
        Thread.sleep(forTimeInterval: 0.05)
        let lines = (try? String(contentsOfFile: logPath, encoding: .utf8))?
            .split(separator: "\n").map(String.init) ?? []
        record("日志·有落盘行", !lines.isEmpty, "\(logPath) 共 \(lines.count) 行")
        var fieldOK = true
        var missing: [String] = []
        for line in lines {
            guard let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else {
                fieldOK = false; missing.append("<不是合法 JSON>"); continue
            }
            for f in Self.requiredFields where obj[f] == nil {
                fieldOK = false; missing.append(f)
            }
        }
        record("日志·七字段齐全", fieldOK,
               fieldOK ? "每行含 \(requiredFields.joined(separator: "/"))"
                       : "缺字段：\(Set(missing).sorted())")

        // ---------- 汇总 ----------
        let pass = checks.allSatisfy { ($0["pass"] as? Bool) == true }
        let payload: [String: Any] = [
            "check": "passive-selfcheck",
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": Int(selfPid),
            "pass": pass,
            "results": checks,
            "requiredFields": requiredFields,
            "logPath": logPath,
            "audit": Audit.snapshot,
            "instrumentedSites": [
                "applyEdits", "WebText.replace", "AXSelectedText", "AXSelectedText.undo",
                "Inline.accept", "Inline.undo", "pasteboard(AXTarget|Inline)",
                "window: UnderlineOverlay/CardPanel/HoverCardPanel/Settings/Demo",
            ],
            "note": "A 段正控后已 reset；B 段所有计数都是 reset 之后的实测值。覆盖窗口对象在进程启动时分配、从不 orderFront，所以「创建对象数」按启动前基线比对、上屏计数单独统计。",
        ]
        let dir = (evidencePath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: evidencePath))
        }
        print("\nRESULT: \(pass ? "PASS" : "FAIL")")
        print("证据：\(evidencePath)")
        exit(pass ? 0 : 1)
    }
}

private extension String {
    /// qa/evidence/x.json → qa/evidence/x
    var deletingExtension: String { (self as NSString).deletingPathExtension }
}
