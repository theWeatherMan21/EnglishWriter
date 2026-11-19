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
