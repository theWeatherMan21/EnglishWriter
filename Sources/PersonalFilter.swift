// PersonalFilter.swift — 个人词典 / 忽略规则的唯一过滤实现（两条引擎通道共用）
//
// 为什么单独成文件：本地 LanguageTool（LocalEngine.buildItems）与远端逐条 diff（InlineEngine.review）
// 是两条互相独立的出口。过滤只要写两份，迟早漂移成「加进词典了在浏览器里还报」，所以只允许一份实现。
//
// 三条判据（纯函数，selftest 直接喂数据，不依赖网络）：
//   1) 忽略规则命中（原词→建议 精确对，永久 ∪ 本次）→ 丢弃；
//   2) 建议的 original 整个就是词典词（含短语、大小写差异）→ 丢弃；
//   3) 建议区间与该词典词在文本里的任一出现区间**相交** → 丢弃。
//      第 3 条是「对该词的出现区间做过滤」的落地：模型给的 original 常常带前后空白或半个短语，
//      只比字符串会漏，必须按区间判。

import Foundation

enum PersonalFilter {

    /// 两个 UTF-16 区间是否相交（零长度按不相交处理）
    static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        guard a.length > 0, b.length > 0 else { return false }
        return a.location < b.location + b.length && b.location < a.location + a.length
    }

    /// 词典词在文本里的所有出现区间（大小写不敏感；短语按整串匹配）
    static func dictionaryRanges(in text: String, words: [String] = DictStore.words) -> [NSRange] {
        let ns = text as NSString
        guard ns.length > 0, !words.isEmpty else { return [] }
        var out: [NSRange] = []
        for w in words {
            let needle = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !needle.isEmpty else { continue }
            var from = 0
            while from < ns.length {
                let r = ns.range(of: needle, options: [.caseInsensitive],
                                 range: NSRange(location: from, length: ns.length - from))
                guard r.location != NSNotFound, r.length > 0 else { break }
                out.append(r)
                from = r.location + r.length
            }
        }
        return out
    }

    /// 唯一入口：丢掉被词典或忽略规则覆盖的建议，其余原样返回（顺序不变）
    static func apply(_ items: [DiffItem], in text: String,
                      words: [String] = DictStore.words,
                      ignores: IgnoreStore = .shared) -> [DiffItem] {
        guard !items.isEmpty else { return [] }
        let ns = text as NSString
        let dictRanges = dictionaryRanges(in: text, words: words)
        return items.filter { it in
            let r = it.utf16Range
            // 越界交给 DiffSanitize 收拾，这里不替它判
            guard r.location >= 0, r.location + r.length <= ns.length else { return true }
            if ignores.isIgnored(original: it.original, replacement: it.replacement) { return false }
            if DictStore.contains(it.original) { return false }
            if !words.isEmpty, DictStore.hit(in: it.original) { return false }
            if dictRanges.contains(where: { overlaps($0, r) }) { return false }
            return true
        }
    }
}
