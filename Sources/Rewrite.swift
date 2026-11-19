// Rewrite.swift — 改写建议（Grammarly 的 rewrite）：选中一段 → 2–3 个版本
//
// 设计口径（知澜 11-18 定，逐条钉死）：
//   1. 每条候选必须是**逐条 diff**，不是整段替换 —— 这样才能复用下划线／卡片／接受／撤销那一套
//   2. 候选各带 label：更简洁 / 更正式 / 更清晰（模型给了别的 label 就原样保留，但不许为空）
//   3. 回滚走已有 undo 快照路径（InlineController.accept/undoLastAccept），不另造一套
//   4. 模型没配时入口直接隐藏（Rewrite.isAvailable），不给点了没反应的按钮
//
// 本文件只做「请求体 / 解析 / 校验 / 应用」四件事，不碰网络，便于用桩响应断言。

import Foundation

struct RewriteCandidate: Equatable {
    var label: String                // 更简洁 / 更正式 / 更清晰 / 模型自定
    var items: [DiffItem]            // 相对「选中段落」的逐条 diff
    var note: String = ""            // 模型给的补充说明（可空）

    /// 应用后的文本（相对段落）
    func appliedText(to segment: String) -> String { applyEdits(items, to: segment) }

    /// 候选是否真的改变了文本（没改变就不该出现在卡片里）
    func isMeaningful(for segment: String) -> Bool { appliedText(to: segment) != segment }
}

enum Rewrite {

    static let defaultLabels = ["更简洁", "更正式", "更清晰"]

    /// 语气档（Grammarly 的 tone）：本质是同一管道的另一组 label
    enum Tone: String, CaseIterable {
        case formal = "更正式"
        case concise = "更简洁"
        case direct = "更直接"
    }
    static let toneLabels = Tone.allCases.map(\.rawValue)

    /// 入口是否可用：模型三件套齐全才显示
    static func isAvailable(_ cfg: LLMConfig = SettingsStore.load()) -> Bool { cfg.isComplete }

    // MARK: 请求体

    static func systemPrompt(labels: [String] = defaultLabels) -> String {
        let terms = glossaryTerms.sorted().joined(separator: " ")
        return """
        You rewrite ONE selected passage for a Chinese shipping-logistics professional.
        Return ONLY JSON, no fence, no prose:
        {"candidates":[{"label":"<\(labels.joined(separator: "|"))>","note":"<一句话中文说明>",
          "text":"<改写后的完整段落>"}]}

        Rules:
        1. Produce exactly \(labels.count) candidates, one per label, in this order: \(labels.joined(separator: ", ")).
        2. "text" MUST be the COMPLETE rewritten passage (the whole input), not a fragment.
           Do NOT output offsets or spans — the app computes the diff itself.
        3. Keep meaning, facts, numbers and industry terms unchanged: \(terms)
        4. Do not translate. Do not add sentences. Only rewrite what the label asks for.
        5. Every candidate must be a grammatical sentence: never delete words, never repeat a word
           (no "the the"), no double spaces.
        6. Keep "note" under 20 Chinese characters.
        7. Each label must give a DIFFERENT wording from the others.
        """
    }

    static func userMessage(_ segment: String) -> String {
        "Passage (UTF-16 offsets counted from 0):\n\"\"\"\n\(segment)\n\"\"\""
    }

    /// 组请求体（OpenAI 兼容）
    static func requestBody(segment: String, config: LLMConfig,
                            labels: [String] = defaultLabels) -> [String: Any] {
        var body: [String: Any] = [
            "model": config.model.trimmingCharacters(in: .whitespacesAndNewlines),
            "temperature": 0.3,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt(labels: labels)],
                ["role": "user", "content": userMessage(segment)],
            ],
        ]
        if CategoryPrefs.fastMode() {
            body["reasoning_effort"] = "none"   // 实测 18.3s → ~2s，候选质量不掉
        }
        if config.baseURL.lowercased().contains("opencode") { body["max_tokens"] = 2000 }   // 3 条候选足够；4000 让单次调用慢 ~40%
        return body
    }

    // MARK: 解析

    struct Payload: Decodable {
        struct C: Decodable {
            var label: String?
            var note: String?
            var edits: [DiffItem]?
            var text: String?          // 容错：模型有时直接给整段
        }
        var candidates: [C]?
    }

    /// 解析模型返回 → 候选列表。任何一条候选只要不满足约束就整条丢掉（宁可少一个版本，不许给坏的）
    static func parse(_ content: String, segment: String) -> [RewriteCandidate] {
        var s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]) }
            if let fence = s.range(of: "```", options: .backwards) { s = String(s[..<fence.lowerBound]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var raw: [Payload.C] = []
        if let data = s.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           let list = payload.candidates {
            raw = list
        } else {
            // 整段解码失败（最常见：max_tokens 截断）→ 逐个对象抢救
            raw = salvageCandidates(from: s)
        }
        guard !raw.isEmpty else { return [] }

        var out: [RewriteCandidate] = []
        for (i, c) in raw.enumerated() {
            // 只接受逐条 diff：整段文本整段替换的候选一律丢（违反口径 1）
            // 首选：模型只给整句 → 本地算 diff（原文字串天然合法，不会出现越界/碎片）
            if let raw = c.text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                // 先修一类可自动纠正的碎句：advise/inform/notify us the X → … us of the X
                // （模型常把 "advise us the schedule" 原样留下或改成缺介词的形式）
                let text = raw.replacingOccurrences(
                    of: #"\b(advise|inform|notify)\s+(us|me|them|him|her)\s+(the|your|our|this|that)\b"#,
                    with: "$1 $2 of $3", options: [.regularExpression, .caseInsensitive])
                let items = WordDiff.edits(original: segment, rewritten: text)
                guard !items.isEmpty else { continue }
                let label = (c.label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (i < defaultLabels.count ? defaultLabels[i] : "版本 \(i + 1)")
                out.append(RewriteCandidate(label: label, items: items, note: c.note ?? ""))
                continue
            }
            guard var edits = c.edits, !edits.isEmpty else { continue }
            // 边界空格清理：模型把 "kindly advise us the" 改成 " advise us of the" 时，
            // 接上去会变成双空格（11-19 实测 6 条候选全因此被拒）。这里直接修，不丢候选。
            // 只在与原文相邻已有空格的边界上裁空格；否则会把 "advise us"→"provide us" 粘成 "provideus"
            let seg = segment as NSString
            for i in edits.indices {
                var rep = edits[i].replacement
                let start = edits[i].start, len = edits[i].length
                let prevIsSpace = start == 0 || seg.character(at: start - 1) == 32
                let nextIsSpace = start + len >= seg.length || seg.character(at: start + len) == 32
                if prevIsSpace, rep.hasPrefix(" ") { rep.removeFirst() }
                if nextIsSpace, rep.hasSuffix(" ") { rep.removeLast() }
                edits[i].replacement = rep
            }
            edits.removeAll { $0.replacement == $0.original }
            // 硬校验（知澜 11-19 提的）：original 必须是原文对应位置的精确子串，
            // 否则会拼出 "send usus the…" 这种碎片（模型给的 span 边界错了）。
            let segNS = segment as NSString
            var relocated: [DiffItem] = []
            for var e in edits {
                guard e.length > 0 else { continue }
                if e.start + e.length <= segNS.length {
                    let slice = segNS.substring(with: NSRange(location: e.start, length: e.length))
                    if slice == e.original || slice.lowercased() == e.original.lowercased() {
                        relocated.append(e); continue
                    }
                }
                // 边界错了就按原文重新定位（±60 字符内找 original），找不到才丢
                let window0 = max(0, e.start - 60), window1 = min(segNS.length, e.start + e.length + 60)
                let found = segNS.range(of: e.original,
                                        options: [.caseInsensitive],
                                        range: NSRange(location: window0, length: window1 - window0))
                if found.location != NSNotFound {
                    e.start = found.location
                    e.length = found.length
                    relocated.append(e)
                }
            }
            edits = relocated
            let cleaned = DiffSanitize.clean(edits, in: segment)
            guard !cleaned.isEmpty else { continue }
            let label = (c.label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? (i < defaultLabels.count ? defaultLabels[i] : "版本 \(i + 1)")
            let cand = RewriteCandidate(label: label, items: cleaned, note: c.note ?? "")
            // 口径 1 的反面：整段一条替换的候选一律丢（那就不是逐条 diff 了）
            let wholeSpan = cleaned.count == 1
                && cleaned[0].start == 0
                && cleaned[0].length == (segment as NSString).length
            guard !wholeSpan else { continue }
            guard cand.isMeaningful(for: segment) else { continue }   // 没改动的不算候选
            out.append(cand)
        }
        // 集中修一次：无论候选来自 text 还是 edits，都把「advise us the」补成「advise us of the」，
        // 再用 WordDiff 重建 edits（原文字串天然合法）
        out = out.map { c in
            let applied = c.appliedText(to: segment)
            let fixed = applied.replacingOccurrences(
                of: #"\b(advise|inform|notify)\s+(us|me|them|him|her)\s+(the|your|our|this|that)\b"#,
                with: "$1 $2 of $3", options: [.regularExpression, .caseInsensitive])
            guard fixed != applied else { return c }
            let items = WordDiff.edits(original: segment, rewritten: fixed)
            return items.isEmpty ? c : RewriteCandidate(label: c.label, items: items, note: c.note)
        }

        // 同一 appliedText 只留第一条（去重下沉到 parse，调用方不用再各自处理）
        var seenOut = Set<String>()
        return out.filter { seenOut.insert($0.appliedText(to: segment)).inserted }
    }


    // MARK: 调用（只在这里碰网络；解析/校验全在纯函数里，便于断言）

    static func suggestDetailed(segment: String, config: LLMConfig,
                                labels: [String] = defaultLabels,
                                timeout: TimeInterval = 20,
                                session: URLSession = .shared) async throws -> (raw: String, candidates: [RewriteCandidate]) {
        guard config.isComplete, let url = config.endpoint else { throw ReviewFailure.notConfigured }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                     forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in EnginePrefs.extraModelHeaders(baseURL: config.baseURL) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: requestBody(segment: segment, config: config, labels: labels))
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw ReviewFailure.timeout
        } catch {
            throw ReviewFailure.network((error as NSError).localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ReviewFailure.http(code, String(data: data, encoding: .utf8) ?? "") }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let raw = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        return (raw, parse(raw, segment: segment))
    }

    /// 候选质量硬门槛（11-19 实测抓到的坏例子：删词后「send   vessel schedule ASAP」、
    /// 加「the the」、四个标签给出同一句）。不合格的直接丢，宁可少给也不给坏句。
    static func acceptCandidate(_ c: RewriteCandidate, segment: String) -> Bool {
        let out = c.appliedText(to: segment)
        guard !out.isEmpty else { return false }
        if out == segment { return false }
        if out.contains("  ") { return false }                      // 双空格
        if out.range(of: #"\b(\w+) \1\b"#, options: .regularExpression) != nil { return false }  // 重复词
        let ratio = Double(out.count) / Double(max(1, segment.count))
        if ratio < 0.6 || ratio > 1.8 { return false }              // 删太多 / 加太多
        // 缺动词的碎句：实测出现「Please let us the vessel schedule…」（let us 后面没动词）
        if out.range(of: #"\b(let|allow|ask|tell|advise|inform|notify)\s+us\s+(the|a|an|your|our)\b"#,
                     options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return true
    }

    static func suggest(segment: String, config: LLMConfig,
                        labels: [String] = defaultLabels,
                        timeout: TimeInterval = 20,
                        session: URLSession = .shared) async throws -> [RewriteCandidate] {
        guard config.isComplete, let url = config.endpoint else { throw ReviewFailure.notConfigured }

        // 一次请求 + 解析 + 硬过滤。过滤后为空时再试一次（模型偶发写坏整批）
        func attempt(_ extraRule: String, _ useLabels: [String]) async throws -> [RewriteCandidate] {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("Bearer \(config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                         forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            for (k, v) in EnginePrefs.extraModelHeaders(baseURL: config.baseURL) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            var body = requestBody(segment: segment, config: config, labels: useLabels)
            if !extraRule.isEmpty,
               var msgs = body["messages"] as? [[String: String]], !msgs.isEmpty {
                msgs[0]["content"] = (msgs[0]["content"] ?? "") + "\n" + extraRule
                body["messages"] = msgs
            }
            req.httpBody = try JSONSerialization.data(withJSONObject: body)

            let data: Data, resp: URLResponse
            do {
                (data, resp) = try await session.data(for: req)
            } catch let e as URLError where e.code == .timedOut {
                throw ReviewFailure.timeout
            } catch {
                throw ReviewFailure.network((error as NSError).localizedDescription)
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                throw ReviewFailure.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let content = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            let raw = parse(content, segment: segment)
            var seen = Set<String>()
            let kept = raw.filter { c in
                guard acceptCandidate(c, segment: segment) else { return false }
                return seen.insert(c.appliedText(to: segment)).inserted
            }
            if kept.isEmpty, ProcessInfo.processInfo.environment["EW_REWRITE_DEBUG"] == "1" {
                for c in raw {
                    let out = c.appliedText(to: segment)
                    var why = "ok?"
                    if out.isEmpty { why = "空" }
                    else if out == segment { why = "与原文相同" }
                    else if out.contains("  ") { why = "双空格" }
                    else if out.range(of: #"\b(\w+) \1\b"#, options: .regularExpression) != nil { why = "重复词" }
                    else {
                        let r = Double(out.count) / Double(max(1, segment.count))
                        if r < 0.6 || r > 1.8 { why = String(format: "长度比 %.2f", r) }
                    }
                    FileHandle.standardError.write("[rewrite-reject \(c.label)] \(why)：\(out)\n".data(using: .utf8)!)
                }
            }
            return kept
        }

        let first = try await attempt("", labels)
        if !first.isEmpty { return first }
        // 整批都被过滤掉了：只补一条（单 label，输出小、快），带着更严的追加规则
        let retry = try await attempt("Rewrite again. IMPORTANT: the previous attempt deleted words or introduced new errors. Keep every piece of information and produce one complete grammatical sentence.",
                                      [labels.first ?? "更清晰"])
        if !retry.isEmpty { return retry }
        return first
    }

    /// 从残缺 JSON 里逐个抽出形如 {"label":...,"edits":[...]} 的对象（大括号配平，容忍被截断的尾巴）
    static func salvageCandidates(from s: String) -> [Payload.C] {
        var out: [Payload.C] = []
        let chars = Array(s)
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else { i += 1; continue }
            var depth = 0
            var j = i
            var end: Int? = nil
            while j < chars.count {
                if chars[j] == "{" { depth += 1 }
                if chars[j] == "}" {
                    depth -= 1
                    if depth == 0 { end = j; break }
                }
                j += 1
            }
            if let e = end {
                let frag = String(chars[i...e])
                if frag.contains("\"edits\""), let d = frag.data(using: .utf8),
                   let c = try? JSONDecoder().decode(Payload.C.self, from: d) {
                    out.append(c)
                }
                i = e + 1
            } else {
                break   // 截断在对象中间：放弃这一段
            }
        }
        return out
    }

    // MARK: 应用 / 回滚

    /// 应用顺序：把候选逐条 diff 按 start 从后往前写。
    /// 理由：先改前面的会让后面的偏移整体位移；倒序写就不会互相踩。
    static func applyOrder(_ items: [DiffItem]) -> [Int] {
        items.enumerated().sorted { $0.element.start > $1.element.start }.map { $0.offset }
    }

    /// 应用一个候选：灌进 controller → 按倒序接受 → 留一个整段撤销快照
    /// 回滚沿用已有的 undoLastAccept 路径（不另造一套）
    @MainActor
    @discardableResult
    static func apply(_ candidate: RewriteCandidate, segment: String, segStart: Int,
                      via ctrl: InlineController) -> Int {
        guard let el = ctrl.currentElement else { return 0 }
        let before = AXInline.fullText(of: el) ?? segment

        ctrl.adoptForRewrite(candidate.items)
        var applied = 0
        for id in applyOrder(candidate.items) where ctrl.accept(itemID: id) { applied += 1 }
        guard applied > 0 else { return 0 }

        let after = AXInline.fullText(of: el) ?? ""
        // 整段撤销：replacement = 现在文本里的这一段，original = 写之前的这一段
        let newSegLen = (after as NSString).length - ((before as NSString).length - (segment as NSString).length)
        if newSegLen > 0 {
            let nowSegment = ((after as NSString).substring(with: NSRange(location: segStart, length: newSegLen)))
            ctrl.setUndoSnapshot(DiffItem(start: segStart, length: newSegLen,
                                          original: segment, replacement: nowSegment,
                                          type: "style", reason: "改写建议回滚"),
                                 snapshot: before,
                                 element: el)
        }
        return applied
    }
}
