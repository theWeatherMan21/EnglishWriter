// Diff.swift — 逐条 diff 契约（v0.1 的「整段重写」作废）
//
// 引擎必须返回「一条错 = 一条 edit」，每条带 UTF-16 offset / length /
// 原片段 / 建议片段 / 类型 / 一句中文理由。下划线、卡片、接受、忽略全靠这个结构。

import Foundation

// MARK: - 结构

struct DiffItem: Codable, Equatable {
    var start: Int          // UTF-16 offset，相对全文
    var length: Int         // UTF-16 length
    var original: String
    var replacement: String
    var type: String        // spelling / grammar / clarity / style
    var reason: String

    var kind: UnderlineKind { UnderlineKind.from(type) }
    var utf16Range: NSRange { NSRange(location: start, length: length) }

    enum CodingKeys: String, CodingKey {
        case start, length, original, replacement, type, reason
    }

    init(start: Int, length: Int, original: String, replacement: String, type: String, reason: String) {
        self.start = start; self.length = length
        self.original = original; self.replacement = replacement
        self.type = type; self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 0
        length = try c.decodeIfPresent(Int.self, forKey: .length) ?? 0
        original = try c.decodeIfPresent(String.self, forKey: .original) ?? ""
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "grammar"
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        if length == 0 { length = (original as NSString).length }
    }
}

struct DiffPayload: Codable {
    var edits: [DiffItem]
}

// MARK: - 解析（容忍围栏 / 裸数组 / edits|items|suggestions 三种键名）

enum DiffParse {
    static func parse(_ content: String) -> [DiffItem]? {
        var s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
            if let fence = s.range(of: "```", options: .backwards) { s = String(s[..<fence.lowerBound]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = s.data(using: .utf8) else { return nil }

        if let p = try? JSONDecoder().decode(DiffPayload.self, from: data) { return p.edits }
        if let arr = try? JSONDecoder().decode([DiffItem].self, from: data) { return arr }
        // 键名不一致时按通用 JSON 走一遍
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in ["edits", "items", "suggestions", "corrections", "alerts"] {
            if let arr = obj[key] as? [[String: Any]] {
                return arr.compactMap { dict -> DiffItem? in
                    guard let d = try? JSONSerialization.data(withJSONObject: dict),
                          let item = try? JSONDecoder().decode(DiffItem.self, from: d) else { return nil }
                    return item
                }
            }
        }
        return nil
    }
}

// MARK: - 清洗：越界丢弃、原文不符时在全文里重新定位、重叠只留第一条

enum DiffSanitize {
    static func clean(_ items: [DiffItem], in text: String) -> [DiffItem] {
        let ns = text as NSString
        var out: [DiffItem] = []
        for var it in items {
            if it.length <= 0 { it.length = (it.original as NSString).length }
            guard it.length > 0 else { continue }
            if it.start >= 0, it.start + it.length <= ns.length,
               ns.substring(with: NSRange(location: it.start, length: it.length)) == it.original {
                out.append(it); continue
            }
            // 偏移对不上（模型数错字）：按原文片段重新定位
            guard !it.original.isEmpty else { continue }
            let r = ns.range(of: it.original)
            if r.location != NSNotFound {
                it.start = r.location
                it.length = r.length
                out.append(it)
            }
            // 找不到就丢：宁可少一条线，也不画在错位置
        }
        out.sort { $0.start < $1.start }
        return consolidate(out, in: text)
    }

    // MARK: 三类合并去重（M3.3）
    //
    // 一次检查里同一段文本经常被三类引擎同时命中（LT 给 spelling，模型给 grammar，
    // 风格规则又给 style）。散着全画上会叠成一条粗线、卡片也打架，所以统一在这里收口：
    //   1) 完全重复（start+length+replacement 全同）直接去掉
    //   2) 任何重叠只留一条：拼写 > 语法 > 清晰度 > 风格；同级取更长的，再同级取更早的
    //   3) 只是首尾相接（end == next.start）不算重叠，两条都留
    //   4) 越界（start+length > 全文长度）丢弃 —— 少一条线也不许画在错位置
    // 输出恒按 start 升序、两两不重叠。

    static func severity(_ k: UnderlineKind) -> Int {
        switch k {
        case .spelling: return 4
        case .grammar:  return 3
        case .clarity:  return 2
        case .style:    return 1
        }
    }

    static func consolidate(_ items: [DiffItem], in text: String) -> [DiffItem] {
        let len = (text as NSString).length
        var byKey: [String: Int] = [:]
        var pool: [DiffItem] = []
        for it in items {
            guard it.length > 0, it.start >= 0, it.start + it.length <= len else { continue }
            let key = "\(it.start):\(it.length):\(it.replacement)"
            if let i = byKey[key] {
                // 同段同建议只留一条，但类型要取更严重的那个：
                // 否则「先来的 grammar」会把后来的 spelling 吃掉（合并·重叠留高严重度 就是栽在这）
                if severity(it.kind) > severity(pool[i].kind) { pool[i] = it }
                continue
            }
            byKey[key] = pool.count
            pool.append(it)
        }
        // 严重度高者先占位，保证重叠时留下的是拼写/语法，而不是风格建议
        pool.sort { a, b in
            if severity(a.kind) != severity(b.kind) { return severity(a.kind) > severity(b.kind) }
            if a.length != b.length { return a.length > b.length }
            return a.start < b.start
        }
        var accepted: [DiffItem] = []
        for it in pool {
            let lo = it.start, hi = it.start + it.length
            let clash = accepted.contains { $0.start < hi && lo < $0.start + $0.length }
            if clash { continue }
            accepted.append(it)
        }
        return accepted.sorted { $0.start < $1.start }
    }
}

// MARK: - 提示词 v2（逐条 diff）

func systemPromptV2() -> String {
    let terms = glossaryTerms.sorted().joined(separator: " ")
    return """
    You are a grammar checker like Grammarly, running for a Chinese shipping-logistics professional.
    Return ONLY a JSON object, no markdown fence, no prose:
    {"edits":[{"start":<UTF-16 offset>,"length":<UTF-16 length>,"original":"<exact substring>","replacement":"<corrected substring>","type":"spelling|grammar|clarity|style","reason":"<一句话中文理由>"}]}

    Rules:
    1. One edit per distinct error. Do not rewrite whole sentences; do not merge two unrelated errors into one edit.
    2. start/length are UTF-16 offsets measured in the ORIGINAL text. original must be the exact substring at that range.
    3. Fix real spelling, grammar, article/preposition/agreement errors. No rephrasing, no shortening, no translation.
    4. Industry terms must stay byte-for-byte unchanged: \(terms)
    5. If a sentence has no error, output no edit for it.
    6. No error at all -> {"edits":[]}.
    """
}

// MARK: - 调用（OpenAI 兼容 /chat/completions）

struct InlineOutcome {
    var items: [DiffItem]
    var endpoint: String
    var model: String
    var elapsed: Double
}

enum InlineEngine {
    static func review(text: String, config: LLMConfig,
                       timeout: TimeInterval = 15,
                       session: URLSession = .shared) async throws -> InlineOutcome {
        guard config.isComplete, let url = config.endpoint else { throw ReviewFailure.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(config.apiKey.trimmed)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": config.model.trimmed,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPromptV2()],
                ["role": "user", "content": "Text (UTF-16 offsets counted from 0):\n\"\"\"\n\(text)\n\"\"\""],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let t0 = Date()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw ReviewFailure.timeout
        } catch {
            throw ReviewFailure.network((error as NSError).localizedDescription)
        }
        let elapsed = Date().timeIntervalSince(t0)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard code == 200 else { throw ReviewFailure.http(code, raw) }

        var content = ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let choices = obj["choices"] as? [[String: Any]],
           let msg = choices.first?["message"] as? [String: Any],
           let c = msg["content"] as? String { content = c }
        guard let items = DiffParse.parse(content) else { throw ReviewFailure.badJSON(content) }
        return InlineOutcome(items: DiffSanitize.clean(items, in: text),
                             endpoint: url.absoluteString,
                             model: config.model,
                             elapsed: elapsed)
    }
}

// MARK: - 应用（接受一条 / 全部）

/// 按逐条 diff 应用到原文（从后往前改写，偏移不会串）
func applyEdits(_ items: [DiffItem], to text: String, only itemID: Int? = nil) -> String {
    Audit.write("applyEdits")        // 只读自证：这条纯函数也算写回入口，调用即计数
    let ns = NSMutableString(string: text)
    let targets = items.enumerated()
        .filter { itemID == nil || $0.offset == itemID }
        .map { $0.element }
        .sorted { $0.start > $1.start }
    for it in targets {
        guard it.start >= 0, it.start + it.length <= ns.length else { continue }
        ns.replaceCharacters(in: NSRange(location: it.start, length: it.length), with: it.replacement)
    }
    return ns as String
}

// MARK: - Mock 数据集（M1 渲染器自测用，不依赖网络与授权）

enum MockDiff {
    static let paragraph = """
    There is many reasons why we should sent the booking confirmation to the customer immediatly. \
    Our sales team have received three new enquiry last week, and they was not able to reply on time. \
    The vessel is expected to depart on 20th Nov, please confirm the FCL booking with the shipper.
    """

    /// 明确错误的片段 → 建议（偏移按全文实时计算，不硬编码）
    static let edits: [(wrong: String, right: String, type: String, reason: String)] = [
        ("There is many", "There are many", "grammar", "复数主语 reasons 要用 are"),
        ("should sent", "should send", "grammar", "情态动词 should 后面接动词原形"),
        ("immediatly", "immediately", "spelling", "拼写错误：immediately"),
        ("three new enquiry", "three new enquiries", "grammar", "three 后面用复数 enquiries"),
        ("they was", "they were", "grammar", "主语 they 配 were"),
    ]

    static func items(for text: String) -> [DiffItem] {
        let ns = text as NSString
        var out: [DiffItem] = []
        for e in edits {
            let r = ns.range(of: e.wrong)
            guard r.location != NSNotFound else { continue }
            out.append(DiffItem(start: r.location, length: r.length,
                                original: e.wrong, replacement: e.right,
                                type: e.type, reason: e.reason))
        }
        return out
    }
}
