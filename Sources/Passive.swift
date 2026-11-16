// Passive.swift — 被动只读观察模式（--passive）
//
// 目的：在不打扰爹地、不写任何内容、不上屏一个像素、不存正文的前提下，
// 收集「真机某 App 里打字会不会触发 AXObserver」的证据（Mail WebKit / Notes / 任意 App）。
//
// 铁律（对应 11-16 红线）：
//   · 只读：不 setText、不发键击、不截屏
//   · 下划线全程 globallySilent（clear() 也不复位）
//   · 不弹卡片、不弹窗
//   · 日志只存元信息：pid / 应用名 / role / 文本长度 / 句子长度 / 命中数 / 矩形数 / 耗时 / 错误
//     —— 正文一个字都不落盘
//
// 用法：
//   open -a 英文写作助手.app --args --passive <outFile> [--seconds 600]
// 产物：<outFile> 每行一条 JSON（JSONL），退出时打印汇总

import AppKit

enum Passive {

    @MainActor
    static func run(_ argv: [String]) async {
        var outPath = NSHomeDirectory() + "/dev/EnglishWriter/out/passive.jsonl"
        if let i = argv.firstIndex(of: "--passive"), i + 1 < argv.count { outPath = argv[i + 1] }
        var seconds: Double = 600
        if let i = argv.firstIndex(of: "--seconds"), i + 1 < argv.count, let d = Double(argv[i + 1]) { seconds = d }

        let dir = (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: outPath, contents: nil)
        guard let fh = FileHandle(forWritingAtPath: outPath) else {
            FileHandle.standardError.write("[passive] 打不开输出文件\n".data(using: .utf8)!); exit(2)
        }
        fh.seekToEndOfFile()

        UnderlineOverlay.globallySilent = true      // 一个像素都不上屏
        var counts: [String: Int] = [:]
        var byApp: [String: Int] = [:]
        let iso = ISO8601DateFormatter()

        InlineController.shared.onCheck = { e in
            counts[e.kind, default: 0] += 1
            if e.kind == "check" || e.kind == "render" { byApp[e.app, default: 0] += 1 }
            let obj: [String: Any] = [
                "at": iso.string(from: e.at),
                "kind": e.kind,
                "pid": Int(e.pid),
                "app": e.app,
                "role": e.role,
                "textLen": e.textLen,
                "sentenceLen": e.sentenceLen,
                "itemCount": e.itemCount,
                "rectCount": e.rectCount,
                "elapsed": e.elapsed,
                "err": e.err,
            ]
            if let d = try? JSONSerialization.data(withJSONObject: obj),
               let line = String(data: d, encoding: .utf8) {
                fh.write(Data((line + "\n").utf8))
            }
        }

        print("[passive] 只读观察中，\(Int(seconds))s 或 Ctrl-C 结束；日志 \(outPath)")
        let t0 = Date()
        while Date().timeIntervalSince(t0) < seconds {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        fh.synchronizeFile()
        let summary: [String: Any] = ["events": counts, "byApp": byApp, "path": outPath]
        if let d = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: d, encoding: .utf8) ?? "")
        }
        exit(0)
    }
}
