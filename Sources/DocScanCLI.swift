// DocScanCLI.swift — 文档级扫描的命令行入口（对真实文件跑，产出 JSON 证据，不依赖界面）
//
// 用法：
//   ./build/英文写作助手 --docscan-file <path> [--docscan-out <json>]
// 引擎：本地拼写（NSSpellChecker）+ 清晰度/风格规则；LT 若开着且在线则并进去；模型接口不在这里自动调
//
// 为什么要有它：`DocScan` 只有单测和注入桩，没在真实文本上跑过。这个入口把「整篇扫描」
// 变成一条可复跑的命令，产出的 JSON 能直接给人看：多少句、跳过多少中文句、报了什么。

import Foundation

enum DocScanCLI {

    static func run(_ argv: [String]) async -> Bool {
        guard let i = argv.firstIndex(of: "--docscan-file"), i + 1 < argv.count else {
            print("用法：--docscan-file <path> [--docscan-out <json>]")
            return false
        }
        let path = argv[i + 1]
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("读不到文件：\(path)")
            return false
        }
        print("\n--- 文档级扫描（整篇）---")
        print("  文件：\(path)  字符数：\((text as NSString).length)")

        let ltOn = EnginePrefs.ltEnabled()
        let ltOK = ltOn ? await LocalEngine.available() : false
        print("  引擎：系统拼写 + 本地规则" + (ltOK ? " + LanguageTool" : "（LT 未启用/离线）"))

        let res = await DocScan.scan(text) { sentence in
            var items = SpellCheck.items(in: sentence) + StyleRules.apply(to: sentence)
            if ltOK, let out = try? await LocalEngine.review(text: sentence) {
                items += out.items
            }
            return DiffSanitize.consolidate(items, in: sentence)
        }

        let ns = text as NSString
        print("  句子 \(res.sentenceCount) 句，跳过非英文 \(res.skippedCJK) 句，命中 \(res.items.count) 条，耗时 \(Int(res.elapsed * 1000))ms")
        for it in res.items.prefix(20) {
            let line = ns.substring(with: NSRange(location: it.start, length: it.length))
            print("    [\(it.type)] \(it.original) → \(it.replacement)（原句片段：\(line)）")
        }

        let out: [String: Any] = [
            "file": path,
            "chars": ns.length,
            "sentences": res.sentenceCount,
            "skippedCJK": res.skippedCJK,
            "edits": res.items.count,
            "elapsedMs": Int(res.elapsed * 1000),
            "engine": ltOK ? "spell+rules+languagetool" : "spell+rules",
            "items": res.items.map {
                ["start": $0.start, "length": $0.length, "original": $0.original,
                 "replacement": $0.replacement, "type": $0.type, "reason": $0.reason]
            },
        ]
        var outPath = FileManager.default.currentDirectoryPath + "/qa/evidence/docscan.json"
        if let j = argv.firstIndex(of: "--docscan-out"), j + 1 < argv.count { outPath = argv[j + 1] }
        let dir = (outPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: outPath))
            print("  证据：\(outPath)")
        }
        // 判定：必须扫出条目、且所有偏移都能在原文上取出（不许越界）
        let inBounds = res.items.allSatisfy { $0.start >= 0 && $0.start + $0.length <= ns.length }
        print(inBounds ? "RESULT: PASS" : "RESULT: FAIL（有偏移越界）")
        return inBounds && !res.items.isEmpty
    }
}
