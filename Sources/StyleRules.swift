// StyleRules.swift — 本地「清晰度 / 风格」规则引擎（补上四类里的 clarity / style）
//
// 为什么要有它：LanguageTool 只出 spelling / grammar，「跟 Grammarly 一样」缺的两类是
// clarity（啰嗦、绕）和 style（弱、不正式）。这两类不需要模型，规则就够，而且必须**毫秒级、
// 零出网、可断言** —— 所以放在本地，和 LT 一样统一出口 [DiffItem]。
//
// 铁律：
//   · 只在英文句子上跑（调用方已做中文门控）
//   · 落在 SpanGuard 保护区间（术语/箱号/港口码/金额/邮箱/链接）内的匹配一律丢弃
//   · 规则表是白名单：一条 pattern 一条 reason，可被测试逐条断言
//   · 与 LT 结果合并时由 DiffSanitize.consolidate 收口（拼写 > 语法 > 清晰度 > 风格）

import Foundation

struct StyleRule {
    let id: String
    let type: String                 // clarity / style
    let pattern: String
    let template: String             // 支持 $1 / $2
    let reason: String               // 中文理由（给卡片看）
    let caseInsensitive: Bool = true
}

enum StyleRules {

    /// 白名单规则表。加规则必须同时加测试（SelfTest.webReplaceTests 同族的 styleRulesTests）。
    static let rules: [StyleRule] = [
        // ── clarity：啰嗦 / 绕 ──
        .init(id: "clar-in-order-to", type: "clarity",
              pattern: #"\bin order to\b"#, template: "to",
              reason: "啰嗦：in order to → to"),
        .init(id: "clar-due-to-fact", type: "clarity",
              pattern: #"\bdue to the fact that\b"#, template: "because",
              reason: "啰嗦：due to the fact that → because"),
        .init(id: "clar-at-this-point", type: "clarity",
              pattern: #"\bat this point in time\b"#, template: "now",
              reason: "啰嗦：at this point in time → now"),
        .init(id: "clar-in-event-that", type: "clarity",
              pattern: #"\bin the event that\b"#, template: "if",
              reason: "啰嗦：in the event that → if"),
        .init(id: "clar-large-number", type: "clarity",
              pattern: #"\ba large number of\b"#, template: "many",
              reason: "啰嗦：a large number of → many"),
        .init(id: "clar-ability-to", type: "clarity",
              pattern: #"\b(has|have) the ability to\b"#, template: "can",
              reason: "啰嗦：has/have the ability to → can"),
        .init(id: "clar-make-decision", type: "clarity",
              pattern: #"\bmake a decision\b"#, template: "decide",
              reason: "啰嗦：make a decision → decide"),
        .init(id: "clar-in-spite-of-fact", type: "clarity",
              pattern: #"\bin spite of the fact that\b"#, template: "although",
              reason: "啰嗦：in spite of the fact that → although"),

        // ── style：弱 / 不精确 ──
        .init(id: "style-a-lot-of", type: "style",
              pattern: #"\ba lot of\b"#, template: "many",
              reason: "风格：口语化的 a lot of → many（书面更稳）"),
        .init(id: "style-kind-of", type: "style",
              pattern: #"\b(kind|sort) of\b"#, template: "somewhat",
              reason: "风格：kind of / sort of → somewhat（更书面）"),
        .init(id: "style-very-unique", type: "style",
              pattern: #"\bvery unique\b"#, template: "unique",
              reason: "风格：unique 本身已是「唯一」，不能加 very"),
        .init(id: "style-each-and-every", type: "style",
              pattern: #"\beach and every\b"#, template: "every",
              reason: "风格：each and every 冗余 → every"),
        .init(id: "style-i-think-opinion", type: "style",
              pattern: #"\bin my opinion,? I think\b"#, template: "I think",
              reason: "风格：in my opinion I think 重复表态 → I think"),
    ]

    /// 已编译规则（首次访问时编译一次；编译失败直接跳过该条，绝不崩）
    private static let compiled: [(StyleRule, NSRegularExpression)] = rules.compactMap { r in
        guard let re = try? NSRegularExpression(pattern: r.pattern,
                                                options: r.caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        return (r, re)
    }

    /// 对一句/一段英文出 clarity + style 建议（UTF-16 偏移相对传入文本）
    static func apply(to text: String, includeGuarded: Bool = false) -> [DiffItem] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let guarded = SpanGuard.guardedRanges(in: text)
        var out: [DiffItem] = []

        for (rule, re) in compiled {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let r = m.range
                guard r.location != NSNotFound, r.length > 0 else { continue }
                if !includeGuarded, guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
                let original = ns.substring(with: r)
                let replacement = re.replacementString(for: m, in: text, offset: 0,
                                                       template: rule.template)
                guard !replacement.isEmpty, replacement != original else { continue }
                out.append(DiffItem(start: r.location, length: r.length,
                                    original: original, replacement: replacement,
                                    type: rule.type, reason: rule.reason))
            }
        }
        // 本地语法兜底（无 LT / 无模型时也不能漏底线用例）：与 clarity/style 同一出口收口
        out += LocalGrammar.apply(to: text, includeGuarded: includeGuarded)
        // 规则之间也可能重叠（in order to 与 to）：按严重度收口，输出恒升序不重叠
        return DiffSanitize.consolidate(out, in: text)
    }

    /// 给测试/诊断用：命中规则 id 列表
    static func matchedRuleIDs(in text: String) -> [String] {
        let ns = text as NSString
        var out: [String] = []
        for (rule, re) in compiled where re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
            out.append(rule.id)
        }
        return out
    }
}
