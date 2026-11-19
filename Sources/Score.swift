// Score.swift — 写作评分（P2）：纯本地，不调模型，可单元测试
//
// Grammarly 的三个数字（Overall / 四维 / 分组条数）是它的「面」，只有线没有分就永远像半成品。
//
// 口径（卡上定的）：
//   Correctness = 100 - min(100, 加权错误数 / 字数 × 1000)
//                 权重：spelling 1.0 / grammar 0.8 / clarity 0.4 / style 0.2
//   Clarity     = 平均句长、被动语态占比、冗长词命中
//   Engagement  = 词汇多样性（type/token）、句子长度方差
//   Delivery    = 与 Goals 正式度设定的偏差（无 Goals 给中性分）
//   Overall     = 四维按 0.4 / 0.3 / 0.15 / 0.15 加权
//
// 断言要求：固定文本 → 分数落在预期区间；错误越多分越低（单调性）。

import Foundation

struct WritingScore {
    var overall = 0
    var correctness = 0
    var clarity = 0
    var engagement = 0
    var delivery = 75          // 没设定 Goals 时给中性分

    var correctnessNote = ""
    var clarityNote = ""
    var engagementNote = ""
    var deliveryNote = ""
}

enum Scorer {

    static let weight: [String: Double] = ["spelling": 1.0, "grammar": 0.8, "clarity": 0.4, "style": 0.2]

    /// 主体评分：items 是已经过语言门控与合并去重的全部建议
    static func score(text: String, items: [DiffItem], formality: Int? = nil) -> WritingScore {
        var s = WritingScore()
        let words = wordCount(text)
        let sentences = splitSentences(text)

        // —— Correctness
        var weighted = 0.0
        for it in items { weighted += weight[it.type] ?? 0.3 }
        if words > 0 {
            s.correctness = max(0, 100 - Int(min(100.0, weighted / Double(words) * 1000)))
        } else {
            s.correctness = 100
        }
        let byType = Dictionary(grouping: items, by: { $0.type }).mapValues { $0.count }
        s.correctnessNote = items.isEmpty
            ? "没有拼写或语法问题"
            : "拼写 \(byType["spelling"] ?? 0) · 语法 \(byType["grammar"] ?? 0) · 清晰度 \(byType["clarity"] ?? 0) · 风格 \(byType["style"] ?? 0)"

        // —— Clarity：句长 / 被动 / 冗长词
        let avgLen = sentences.isEmpty ? 0 : sentences.map(\.count).reduce(0, +) / max(1, sentences.count)
        let longRatio = sentences.isEmpty ? 0 : Double(sentences.filter { $0.count > 28 }.count) / Double(sentences.count)
        let passive = countPassive(sentences)
        let verbose = items.filter { $0.type == "clarity" || $0.type == "style" }.count
        var clarity = 100
        if avgLen > 18 { clarity -= min(25, (avgLen - 18) * 2) }
        clarity -= Int(longRatio * 20)
        clarity -= min(15, passive * 3)
        clarity -= min(20, verbose * 3)
        s.clarity = max(0, clarity)
        s.clarityNote = "平均句长 \(avgLen) 词·被动 \(passive) 处·冗长 \(verbose) 处"

        // —— Engagement：词汇多样性 + 句长方差
        let ttr = typeTokenRatio(text)
        let variance = lengthStdDev(sentences)
        var eng = 60 + Int(ttr * 45)
        if variance > 12 { eng += 5 }
        if sentences.count < 3 { eng -= 5 }
        s.engagement = min(100, max(0, eng))
        s.engagementNote = "词汇多样性 \(Int(ttr * 100))% · 句长波动 \(Int(variance))"

        // —— Delivery：与目标正式度偏差
        let formalMarkers = ["please", "kindly", "regards", "hereby", "furthermore", "therefore"]
        let casualMarkers = ["hey", "gonna", "wanna", "stuff", "ok", "cool", "thanks!"]
        let lower = text.lowercased()
        let f = formalMarkers.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        let c = casualMarkers.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
        let measured = 50 + f * 12 - c * 12
        if let target = formality {
            let targetPct = 20 + target * 20      // 0..4 → 20..100
            let dev = abs(measured - targetPct)
            s.delivery = max(0, 100 - dev)
            s.deliveryNote = "正式度 \(measured)，目标 \(targetPct)，偏差 \(dev)"
        } else {
            s.delivery = 75
            s.deliveryNote = "未设定受众/正式度，给中性分"
        }

        s.overall = Int(Double(s.correctness) * 0.4 + Double(s.clarity) * 0.30
                        + Double(s.engagement) * 0.15 + Double(s.delivery) * 0.15)
        return s
    }

    // MARK: 小工具

    static func wordCount(_ t: String) -> Int {
        t.split(whereSeparator: { !$0.isLetter && $0 != "'" }).count
    }

    static func splitSentences(_ t: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in t {
            cur.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" {
                let s = cur.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { out.append(s) }
                cur = ""
            }
        }
        let tail = cur.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// 被动语态粗判：be 动词 + 过去分词形态（-ed / 常见不规则）
    static func countPassive(_ sentences: [String]) -> Int {
        let be = ["is", "are", "was", "were", "be", "been", "being"]
        let irregular: Set<String> = ["sent", "made", "done", "given", "taken", "shown", "known", "held", "written"]
        var n = 0
        for s in sentences {
            let w = s.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            for i in 0..<max(0, w.count - 1) where be.contains(w[i]) {
                let next = w[i + 1]
                if next.hasSuffix("ed") || irregular.contains(next) { n += 1; break }
            }
        }
        return n
    }

    static func typeTokenRatio(_ t: String) -> Double {
        let words = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard !words.isEmpty else { return 0 }
        return Double(Set(words).count) / Double(words.count)
    }

    static func lengthStdDev(_ sentences: [String]) -> Double {
        let lens = sentences.map { Double($0.split(separator: " ").count) }
        guard lens.count > 1 else { return 0 }
        let mean = lens.reduce(0, +) / Double(lens.count)
        let v = lens.reduce(0) { $0 + pow($1 - mean, 2) } / Double(lens.count)
        return sqrt(v)
    }
}
