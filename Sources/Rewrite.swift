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
          "edits":[{"start":<UTF-16 offset in the PASSAGE>,"length":<UTF-16 length>,
                   "original":"<exact substring>","replacement":"<new substring>",
                   "type":"spelling|grammar|clarity|style","reason":"<中文理由>"}]}]}

        Rules:
        1. Produce exactly \(labels.count) candidates, one per label, in this order: \(labels.joined(separator: ", ")).
        2. Every candidate MUST be expressed as per-span edits against the ORIGINAL passage.
           Never return the whole passage as one edit.
        3. Keep meaning, facts, numbers and industry terms unchanged: \(terms)
        4. Do not translate. Do not add sentences. Only rewrite what the label asks for.
        5. start/length are UTF-16 offsets in the ORIGINAL passage (counted from 0).
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
        if config.baseURL.lowercased().contains("opencode") { body["max_tokens"] = 1500 }
        return body
    }

    // MARK: 解析

    private struct Payload: Decodable {
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
        guard let data = s.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let raw = payload.candidates else { return [] }

        var out: [RewriteCandidate] = []
        for (i, c) in raw.enumerated() {
            // 只接受逐条 diff：整段文本整段替换的候选一律丢（违反口径 1）
            guard let edits = c.edits, !edits.isEmpty else { continue }
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
        return out
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

    static func suggest(segment: String, config: LLMConfig,
                        labels: [String] = defaultLabels,
                        timeout: TimeInterval = 20,
                        session: URLSession = .shared) async throws -> [RewriteCandidate] {
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
        guard code == 200 else {
            throw ReviewFailure.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
        return parse(content, segment: segment)
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
                                 element: el)
        }
        return applied
    }
}
