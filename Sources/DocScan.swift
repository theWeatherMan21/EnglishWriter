// DocScan.swift — 文档级扫描（Grammarly 扫整篇，不只光标那一句）
//
// 现网行为是「只查光标所在句」；本文件提供整篇扫描：
//   切句 → 逐句过引擎（LT + 本地 clarity/style 规则）→ 偏移回全文 → 统一收口去重
//
// 不变量（测试逐条断言）：
//   S1 句子区间首尾相接且覆盖全文（不丢字、不重叠）
//   S2 每条 edit 的 start/length 落在它来自的那一句区间内
//   S3 跨句结果合并后两两不重叠、按 start 升序
//   S4 中文占比 > 0.40 的句子直接跳过（零请求）
//   S5 同一句内重复命中只留一条（交给 consolidate）

import Foundation

enum DocScan {

    struct Result {
        var items: [DiffItem] = []
        var sentenceCount = 0
        var skippedCJK = 0
        var engine: String = ""
        var elapsed: Double = 0
    }

    /// 切句：句末标点（含换行）作为边界，返回覆盖全文的区间
    static func sentenceRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var out: [NSRange] = []
        var start = 0
        for i in 0..<ns.length {
            let ch = ns.character(at: i)
            if let scalar = Unicode.Scalar(ch), ".!?\n。！？".unicodeScalars.contains(scalar) {
                let len = i + 1 - start
                if len > 0 { out.append(NSRange(location: start, length: len)) }
                start = i + 1
            }
        }
        if start < ns.length { out.append(NSRange(location: start, length: ns.length - start)) }
        return out
    }

    static func cjkRatio(_ s: String) -> Double { LanguageGate.cjkRatio(s) }

    /// 整篇扫描。engine 可注入（测试用桩；生产传 LT+规则）
    static func scan(_ text: String,
                     engine: (String) async -> [DiffItem],
                     maxSentences: Int = 400) async -> Result {
        let t0 = Date()
        var res = Result()
        let ns = text as NSString
        let ranges = sentenceRanges(in: text)
        res.sentenceCount = ranges.count

        for r in ranges.prefix(maxSentences) {
            let sentence = ns.substring(with: r)
            guard sentence.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 else { continue }
            if cjkRatio(sentence) > LanguageGate.cjkGate { res.skippedCJK += 1; continue }
            let local = await engine(sentence)
            for var it in local {
                // S2：偏移是句内的，回填全文；越界的直接丢，绝不让它画到别处
                guard it.start >= 0, it.length > 0, it.start + it.length <= (sentence as NSString).length else { continue }
                it.start += r.location
                res.items.append(it)
            }
        }
        res.items = DiffSanitize.consolidate(res.items, in: text)
        res.elapsed = Date().timeIntervalSince(t0)
        return res
    }
}
