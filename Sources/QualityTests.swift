// QualityTests.swift — 业务英文质量的离线回归（不联网、不碰宿主 App）
//
// 为什么要有它：建议「看起来在工作」不等于「真的查得准」。
// 这组夹具是航运邮件里真实会出现的句子（错例 + 正确例），逐条比对：
//   · 错例必须被标出来（召回）
//   · 正确例一条都不许报（误报）
// 判据：召回 ≥ 80%，误报 = 0。

import Foundation

enum QualityTests {
    struct Case {
        var text: String
        var mustCatch: [String]      // 必须命中的原文片段
        var label: String
    }

    /// 错例：真实业务邮件里的典型错误
    static let bad: [Case] = [
        .init(text: "There is many reasons for the delay.", mustCatch: ["There is many reasons"], label: "主谓一致"),
        .init(text: "We should sent the documents immediately.", mustCatch: ["sent"], label: "动词形态"),
        .init(text: "Please kindly advise us the vessel schedule.", mustCatch: ["advise us"], label: "动词缺介词"),
        .init(text: "The cargo was load yesterday.", mustCatch: ["was load"], label: "被动语态"),
        .init(text: "I have send the invoice last week.", mustCatch: ["send"], label: "完成时"),
        .init(text: "We will shipping the goods tomorrow.", mustCatch: ["will shipping"], label: "将来时"),
        .init(text: "Attached please find the B/L copy immediatly.", mustCatch: ["immediatly"], label: "拼写"),
        .init(text: "They was not informed about the change.", mustCatch: ["They was"], label: "主谓一致"),
        .init(text: "Looking forward to hear from you.", mustCatch: ["to hear"], label: "不定式"),
        .init(text: "The shipment have arrived at the port.", mustCatch: ["shipment have"], label: "主谓一致"),
    ]

    /// 正确例：不许报任何错
    static let good: [String] = [
        "Please find the attached bill of lading for your reference.",
        "The vessel is scheduled to depart on 12 December.",
        "We have booked 20 GP containers for this shipment.",
        "Kindly confirm the delivery order at your earliest convenience.",
        "The free time is 10 days from the date of discharge.",
        "Our agent will contact you once the cargo is released.",
        "Thank you for your prompt reply.",
        "The freight rate is subject to space availability.",
    ]

    static func run(_ argv: [String]) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        if argv.contains("--deep") { return runDeep() }
        var caught = 0, missed: [String] = []
        var falsePositives: [String] = []

        func items(_ text: String) -> [DiffItem] {
            let cjk = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
            guard cjk == 0 else { return [] }
            var out = SpellCheck.items(in: text)
            out += LocalGrammar.apply(to: text)
            out += StyleRules.apply(to: text)
            return DiffSanitize.consolidate(out, in: text)
        }

        print("--- 业务英文离线质量回归 ---")
        for c in bad {
            let found = items(c.text)
            let hit = c.mustCatch.contains { m in
                found.contains { $0.original.localizedCaseInsensitiveContains(m) || m.localizedCaseInsensitiveContains($0.original) }
            }
            if hit { caught += 1 } else { missed.append("\(c.label)：\(c.text)") }
        }
        for g in good {
            let found = items(g)
            if !found.isEmpty {
                falsePositives.append("\(g) → " + found.map { "\($0.original)→\($0.replacement)" }.joined(separator: ", "))
            }
        }

        let recall = Double(caught) / Double(bad.count) * 100
        if recall >= 80 { SelfTest.ok("quality: 召回 ≥80%", String(format: "%.0f%%（%d/%d）", recall, caught, bad.count)) }
        else { SelfTest.bad("quality: 召回", String(format: "%.0f%%（%d/%d）", recall, caught, bad.count)) }

        if falsePositives.isEmpty { SelfTest.ok("quality: 正确句零误报", "\(good.count) 句") }
        else { SelfTest.bad("quality: 误报 \(falsePositives.count) 句", falsePositives[0]) }

        for m in missed { print("  MISS: \(m)") }
        for f in falsePositives { print("  FP  : \(f)") }
        return (recall >= 80 && falsePositives.isEmpty) ? 0 : 1
    }
}

// MARK: - 深度检查（真模型，走 /v1/check 同一条链）
extension QualityTests {
    /// 用模型跑同一组夹具：召回（错例句必须命中）+ 误报（正确句不许报）
    /// 结论只服务产品判断：模型这条路到底比本地规则强多少，值不值得默认开。
    static func runDeep() -> Int32 {
        let cfg = SettingsStore.load()
        guard cfg.isComplete else {
            print("SKIP deep：模型未配置（设置面板三项为空）")
            return 77
        }
        var caught = 0
        var missed: [String] = []
        var fps: [String] = []
        var times: [Int] = []

        func items(_ text: String) -> ([DiffItem], Int) {
            let sem = DispatchSemaphore(value: 0)
            var out: [DiffItem] = []
            var ms = 0
            Task {
                let payload = await LocalAPI.check(text: text, language: "en-GB")
                ms = payload["elapsedMs"] as? Int ?? 0
                if let raw = payload["edits"] as? [[String: Any]] {
                    out = raw.compactMap { e in
                        guard let s = e["start"] as? Int, let l = e["length"] as? Int,
                              let o = e["original"] as? String, let r = e["replacement"] as? String,
                              let t = e["type"] as? String else { return nil }
                        return DiffItem(start: s, length: l, original: o, replacement: r,
                                        type: t, reason: e["reason"] as? String ?? "")
                    }
                }
                sem.signal()
            }
            sem.wait()
            return (out, ms)
        }

        print("--- 业务英文深度检查（真模型 \(cfg.model)）---")
        for c in QualityTests.bad {
            let (found, ms) = items(c.text)
            times.append(ms)
            let hit = c.mustCatch.contains { m in
                found.contains { $0.original.localizedCaseInsensitiveContains(m) || m.localizedCaseInsensitiveContains($0.original) }
            }
            if hit { caught += 1 } else { missed.append("\(c.label)：\(c.text)") }
        }
        for g in QualityTests.good {
            let (found, ms) = items(g)
            times.append(ms)
            if !found.isEmpty {
                fps.append("\(g) → " + found.map { "\($0.original)→\($0.replacement)" }.joined(separator: ", "))
            }
        }

        let recall = Double(caught) / Double(QualityTests.bad.count) * 100
        let avg = times.isEmpty ? 0 : times.reduce(0, +) / times.count
        SelfTest.ok("deep: 召回", String(format: "%.0f%%（%d/%d）", recall, caught, QualityTests.bad.count))
        if fps.isEmpty { SelfTest.ok("deep: 正确句零误报", "\(QualityTests.good.count) 句") }
        else { SelfTest.bad("deep: 误报 \(fps.count) 句", fps[0]) }
        print("  平均耗时 \(avg)ms／句（上限 8000ms）")
        for m in missed { print("  MISS: \(m)") }
        for f in fps { print("  FP  : \(f)") }
        return (recall >= 80 && fps.isEmpty) ? 0 : 1
    }
}
