// LocalGrammar.swift — 本地语法兜底（零进程、零出网、毫秒级）
//
// 为什么必须有它（2026-11-19 实测缺口）：
//   LT 默认关、模型三件套可能没填、模型要 3–8 秒；
//   在这种「只有本地」的组合下，`There is many reasons` / `we should sent` / `We was` 一条都不报，
//   而这三条正是任何写作工具都不能漏的底线用例（知澜 11-19 10:43 判为缺陷）。
//   模型能抓（--deep 实测 4/4），但不能让「有没有网、填没填 key」决定基本功能在不在。
//
// 铁律（与 StyleRules 一致）：
//   · 白名单规则：一条 pattern、一条模板、一句中文理由，可被测试逐条断言
//   · 精度优先于召回：宁可漏，不可误报。每条规则都必须带「不许触发」的反例测试
//   · 落在 SpanGuard 保护区间（术语/箱号/港口码/金额/邮箱/链接）内的一律丢弃
//   · 只对英文句子生效（调用方已做中文门控；规则本身也是英文 pattern）
//
// 加规则的动作固定为两步：rules 里加一条 + SelfTest.grammarTests 里加正例和反例，缺一不算。

import Foundation

struct GrammarRule {
    let id: String
    let pattern: String
    let template: String                    // 支持 $1 / $2
    let reason: String
    /// 命中位置前一个词落在这些词里就不报（处理虚拟语气、疑问倒装等合法形态）
    var notAfter: [String] = []
}

enum LocalGrammar {

    /// 复数判定用的限定词/数量词。注意排除 a lot of / a number of：
    /// 「There is a lot of cargo」是合法的（单数一致），不能一起抓。
    private static let pluralMarkers = "many|several|numerous|few|a few|lots of|two|three|four|five|six|seven|eight|nine|ten|dozens of|hundreds of"

    static let rules: [GrammarRule] = [
        // ── there is/are 存在句一致 ──
        .init(id: "g-there-is-plural", pattern: "(?<=\\bthere )is(?=\\s+(?:\(pluralMarkers))\\b)",
              template: "are", reason: "主谓一致：There is + 复数 → There are"),
        .init(id: "g-there-was-plural", pattern: "(?<=\\bthere )was(?=\\s+(?:\(pluralMarkers))\\b)",
              template: "were", reason: "主谓一致：There was + 复数 → There were"),

        // ── 人称代词 + be ──
        .init(id: "g-plural-pronoun-was", pattern: "\\b(we|they|you)\\s+was\\b",
              template: "$1 were", reason: "主谓一致：we/they/you 配 were"),
        .init(id: "g-singular-pronoun-were", pattern: "\\b(he|she|it)\\s+were\\b",
              template: "$1 was", reason: "主谓一致：he/she/it 配 was",
              notAfter: ["if", "though", "although", "wish", "wishes", "suppose", "unless", "as"]),

        // ── 人称代词 + have/has ──
        .init(id: "g-plural-pronoun-has", pattern: "\\b(we|they|you)\\s+has\\b",
              template: "$1 have", reason: "主谓一致：we/they/you 配 have"),
        .init(id: "g-singular-pronoun-have", pattern: "\\b(he|she|it)\\s+have\\b",
              template: "$1 has", reason: "主谓一致：he/she/it 配 has",
              notAfter: ["do", "does", "did", "will", "would", "should", "could", "can", "may", "might", "must"]),

        // ── 情态动词后的动词形态（of → have 类）──
        .init(id: "g-could-of", pattern: "\\b(could|should|would|must|might|may)\\s+of\\b",
              template: "$1 have", reason: "拼写/语法：should of → should have"),

        // ── 缩写缺撇号（这些词写法本身不存在，零误报）──
        .init(id: "g-apostrophe-dont", pattern: "\\b(dont|doesnt|didnt|isnt|arent|wasnt|werent|hasnt|havent|couldnt|wouldnt|shouldnt|cant|wont)\\b",
              template: "APOSTROPHE", reason: "拼写：缩写缺撇号（don't / doesn't / can't …）"),

        // ── 重复词（the the / to to）──
        .init(id: "g-doubled-word", pattern: "\\b([A-Za-z]{2,})\\s+\\1\\b",
              template: "$1", reason: "重复词：同一个词连写两次"),

        // ── 业务邮件高频错误（11-19 质量回归抓到的：本地只覆盖 40%）──
        // advise us the schedule → advise us of the schedule
        .init(id: "g-advise-of", pattern: "\\b(advise|inform|notify)\\s+(us|me|them|him|her)\\s+(the|your|our|this|that)\\b",
              template: "$1 $2 of $3", reason: "动词缺介词：advise/inform/notify sb **of** sth"),
        // 说明：单数主语 + have、look forward to + 原形、will + Ving 三种需要变形，
        // 写成下面的代码分支（模板做不了），规则表里不重复登记。
    ]

    private static let compiled: [(GrammarRule, NSRegularExpression)] = rules.compactMap { r in
        guard let re = try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive]) else { return nil }
        return (r, re)
    }

    /// 情态动词 + 过去式 → 原形（should sent → should send）
    /// 单独用代码实现而不是规则表：每个动词的替换值不同，一张表加 25 条 pattern 不如一个字典。
    private static let pastToBase: [String: String] = [
        "sent": "send", "went": "go", "came": "come", "took": "take", "made": "make",
        "did": "do", "saw": "see", "wrote": "write", "spoke": "speak", "found": "find",
        "got": "get", "knew": "know", "thought": "think", "told": "tell", "said": "say",
        "bought": "buy", "brought": "bring", "began": "begin", "became": "become",
        "kept": "keep", "left": "leave", "held": "hold", "met": "meet", "paid": "pay",
        "ran": "run", "sat": "sit", "stood": "stand", "understood": "understand",
        "won": "win", "drove": "drive", "gave": "give", "chose": "choose", "ate": "eat",
    ]

    /// have/has + 原形 → 过去分词（have send → have sent）
    private static let baseToParticiple: [String: String] = [
        "send": "sent", "go": "gone", "do": "done", "see": "seen", "write": "written",
        "speak": "spoken", "break": "broken", "choose": "chosen", "drive": "driven",
        "eat": "eaten", "give": "given", "know": "known", "take": "taken", "be": "been",
        "begin": "begun", "forget": "forgotten", "grow": "grown", "show": "shown",
    ]

    /// be + 原形 → 过去分词（was load → was loaded）：这批是货物/单证动词的规则变化
    private static let beToParticiple: [String: String] = [
        "load": "loaded", "ship": "shipped", "pack": "packed", "book": "booked",
        "deliver": "delivered", "receive": "received", "confirm": "confirmed",
        "inspect": "inspected", "discharge": "discharged", "release": "released",
        "issue": "issued", "dispatch": "dispatched", "arrange": "arranged",
    ]

    private static let haveBaseRE = try! NSRegularExpression(
        pattern: "\\b(have|has|had)\\s+([A-Za-z]+)\\b", options: [.caseInsensitive])
    private static let beBaseRE = try! NSRegularExpression(
        pattern: "\\b(was|were|is|are|been)\\s+([A-Za-z]+)\\b", options: [.caseInsensitive])

    private static let modalIngRE = try! NSRegularExpression(
        pattern: "\\b(will|would|shall|should|can|could|may|might|must)\\s+([A-Za-z]+ing)\\b",
        options: [.caseInsensitive])
    private static let lookForwardRE = try! NSRegularExpression(
        pattern: "\\b(look(?:ing)?\\s+forward\\s+to)\\s+(hear|receive|meet|see|work|talk|discuss)\\b",
        options: [.caseInsensitive])
    private static let singularNounHaveRE = try! NSRegularExpression(
        pattern: "\\b(shipment|cargo|vessel|invoice|payment|order|container|document|report|booking|schedule)\\s+have\\b",
        options: [.caseInsensitive])

    /// Ving → 原形（shipping → ship：去掉 ing，处理双写辅音）
    private static func baseFromIng(_ w: String) -> String {
        let l = w.lowercased()
        guard l.hasSuffix("ing"), l.count > 4 else { return l }
        var stem = String(l.dropLast(3))
        let chars = Array(stem)
        if chars.count >= 2, chars[chars.count - 1] == chars[chars.count - 2],
           "bdgklmnprt".contains(chars[chars.count - 1]) {
            stem = String(stem.dropLast())
        }
        return stem
    }

    /// 原形 → 动名词
    private static let gerund: [String: String] = [
        "hear": "hearing", "receive": "receiving", "meet": "meeting",
        "see": "seeing", "work": "working", "talk": "talking", "discuss": "discussing",
    ]

    private static let modalPastRE = try! NSRegularExpression(
        pattern: "\\b(should|would|could|must|might|may|will|can|shall)\\s+([A-Za-z]+)\\b",
        options: [.caseInsensitive])

    /// 对一句/一段英文出本地语法建议（UTF-16 偏移相对传入文本）
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
                if !rule.notAfter.isEmpty, precededBy(text: text, at: r.location, words: rule.notAfter) { continue }

                let original = ns.substring(with: r)
                var replacement = re.replacementString(for: m, in: text, offset: 0, template: rule.template)
                if replacement == "APOSTROPHE" { replacement = fixApostrophe(original) }
                guard !replacement.isEmpty, replacement != original else { continue }
                out.append(DiffItem(start: r.location, length: r.length,
                                    original: original, replacement: replacement,
                                    type: "grammar", reason: rule.reason))
            }
        }

        // 情态动词 + 过去式
        for m in modalPastRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            guard r.location != NSNotFound, r.length > 0 else { continue }
            if !includeGuarded, guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let rawVerb = ns.substring(with: m.range(at: 2))
            let lower = rawVerb.lowercased()
            guard let base = pastToBase[lower] else { continue }
            // have/has/had 是合法的（should have sent），不在 pastToBase 里；这里再挡一层
            guard lower != "have", lower != "be" else { continue }
            let modal = ns.substring(with: m.range(at: 1))
            let replacement = "\(modal) \(preserveCase(base, like: rawVerb))"
            let original = ns.substring(with: r)
            out.append(DiffItem(start: r.location, length: r.length,
                                original: original, replacement: replacement,
                                type: "grammar",
                                reason: "语法：情态动词后接动词原形（\(lower) → \(base)）"))
        }

        // have/has + 原形 → 过去分词（have send → have sent）
        for m in haveBaseRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            if !includeGuarded, guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let verb = ns.substring(with: m.range(at: 2))
            guard let pp = baseToParticiple[verb.lowercased()] else { continue }
            let aux = ns.substring(with: m.range(at: 1))
            out.append(DiffItem(start: r.location, length: r.length,
                                original: ns.substring(with: r),
                                replacement: "\(aux) \(preserveCase(pp, like: verb))",
                                type: "grammar",
                                reason: "语法：完成时用过去分词（have \(verb.lowercased()) → have \(pp)）"))
        }

        // be + 原形 → 过去分词（was load → was loaded）
        for m in beBaseRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            if !includeGuarded, guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let verb = ns.substring(with: m.range(at: 2))
            guard let pp = beToParticiple[verb.lowercased()] else { continue }
            let be = ns.substring(with: m.range(at: 1))
            out.append(DiffItem(start: r.location, length: r.length,
                                original: ns.substring(with: r),
                                replacement: "\(be) \(preserveCase(pp, like: verb))",
                                type: "grammar",
                                reason: "语法：被动语态用过去分词（was \(verb.lowercased()) → was \(pp)）"))
        }

        // will + Ving → will + 原形（will shipping → will ship）
        for m in modalIngRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            if !includeGuarded, guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let ing = ns.substring(with: m.range(at: 2))
            let modal = ns.substring(with: m.range(at: 1))
            let base = baseFromIng(ing)
            guard base.count >= 2, base != ing.lowercased() else { continue }
            out.append(DiffItem(start: r.location, length: r.length,
                                original: ns.substring(with: r),
                                replacement: "\(modal) \(preserveCase(base, like: ing))",
                                type: "grammar",
                                reason: "语法：情态动词后接动词原形（\(ing.lowercased()) → \(base)）"))
        }

        // look forward to hear → to hearing
        for m in lookForwardRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            if !includeGuarded, guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let lead = ns.substring(with: m.range(at: 1))
            let verb = ns.substring(with: m.range(at: 2))
            guard let g = gerund[verb.lowercased()] else { continue }
            out.append(DiffItem(start: r.location, length: r.length,
                                original: ns.substring(with: r),
                                replacement: "\(lead) \(preserveCase(g, like: verb))",
                                type: "grammar",
                                reason: "语法：look forward to 后接动名词（to \(verb.lowercased()) → to \(g)）"))
        }

        // 单数主语 + have → has
        for m in singularNounHaveRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = m.range
            if !includeGuarded, guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            let noun = ns.substring(with: m.range(at: 1))
            out.append(DiffItem(start: r.location, length: r.length,
                                original: ns.substring(with: r),
                                replacement: "\(noun) has",
                                type: "grammar",
                                reason: "主谓一致：单数主语 \(noun.lowercased()) 配 has"))
        }

        return DiffSanitize.consolidate(out, in: text)
    }

    /// 命中位置前面那个词（用于 notAfter 判定）
    private static func precededBy(text: String, at location: Int, words: [String]) -> Bool {
        let ns = text as NSString
        guard location > 0 else { return false }
        let head = ns.substring(to: location)
        let parts = head.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init)
        guard let prev = parts.last else { return false }
        let clean = prev.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"'()")).lowercased()
        return words.contains(clean)
    }

    private static func fixApostrophe(_ original: String) -> String {
        let lower = original.lowercased()
        // cant / wont 是「can't / won't」；其余一律在 n + t 之间插撇号
        switch lower {
        case "cant": return keepCase("can't", like: original)
        case "wont": return keepCase("won't", like: original)
        default:
            guard let nRange = original.range(of: "n", options: [.backwards, .caseInsensitive]) else { return original }
            var s = original
            s.insert("'", at: nRange.upperBound)
            return s
        }
    }

    private static func keepCase(_ replacement: String, like original: String) -> String {
        guard let f = original.first, f.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    private static func preserveCase(_ base: String, like original: String) -> String {
        guard let f = original.first, f.isUppercase else { return base }
        return base.prefix(1).uppercased() + base.dropFirst()
    }
}
