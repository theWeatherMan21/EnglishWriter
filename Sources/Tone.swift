// Tone.swift — P3 语气检测（模型优先，本地关键词兜底）
//
// Grammarly 的 tone detector 是它招牌之一：告诉你「这段话听起来是自信 / 友好 / 强硬 / 急切」。
//
// 口径：
//   · 触发条件：文本 ≥150 字符（太短判不准，Grammarly 也是这个门槛）
//   · 输出：primary + secondary 两个标签
//   · 数据来源：模型能出就出；失败/未配置 → 本地关键词表兜底
//   · 失败不影响其余功能（不改分、不改建议、不弹错）
//
// 标签集（与 Grammarly 对齐）：自信 / 友好 / 正式 / 强硬 / 急切 / 致歉 / 中性

import Foundation

struct ToneResult {
    var primary: String
    var secondary: String
    var source: String      // model / local
}

enum Tone {

    static let labels = ["自信", "友好", "正式", "强硬", "急切", "致歉", "中性"]
    static let minChars = 150

    // 本地关键词（兜底用，命中计分最高者为主语气）
    private static let table: [String: [String]] = [
        "正式": ["kindly", "hereby", "furthermore", "therefore", "please find", "regards", "accordingly", "pursuant"],
        "友好": ["thanks", "thank you", "appreciate", "happy to", "glad", " cheers", "best regards"],
        "强硬": ["must", "immediately", "strictly", "failure", "penalty", "required", "no later than", "unacceptable"],
        "急切": ["urgent", "asap", "right away", "deadline", "today", "immediately", "awaiting", "promptly"],
        "致歉": ["sorry", "apolog", "regret", "inconvenience", "my mistake"],
        "自信": ["we will", "we can", "confirmed", "guarantee", "certain", "definitely", "ensure"],
    ]

    /// 纯本地判定（可单元测试，无网络）
    static func detectLocal(_ text: String) -> ToneResult {
        let t = text.lowercased()
        var scores: [String: Int] = [:]
        for (label, keys) in table {
            let n = keys.reduce(0) { $0 + (t.contains($1) ? 1 : 0) }
            if n > 0 { scores[label] = n }
        }
        let sorted = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        if sorted.isEmpty { return ToneResult(primary: "中性", secondary: "—", source: "local") }
        return ToneResult(primary: sorted[0].key,
                          secondary: sorted.count > 1 ? sorted[1].key : "中性",
                          source: "local")
    }

    /// 对外：模型优先，失败回落本地
    static func detect(_ text: String, config: LLMConfig, timeout: TimeInterval = 30) async -> ToneResult? {
        guard (text as NSString).length >= minChars else { return nil }
        let local = detectLocal(text)
        guard config.isComplete, let url = config.endpoint else { return local }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(config.apiKey.trimmed)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in EnginePrefs.extraModelHeaders(baseURL: config.baseURL) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let ask = """
        Classify the tone of this business email. Answer ONLY JSON:
        {"primary":"<one of 自信/友好/正式/强硬/急切/致歉/中性>","secondary":"<same set or 中性>"}

        Text:
        \"\"\"
        \(text)
        \"\"\"
        """
        var body: [String: Any] = [
            "model": config.model.trimmed,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [["role": "user", "content": ask]],
        ]
        if CategoryPrefs.fastMode() { body["reasoning_effort"] = "none" }
        if config.baseURL.lowercased().contains("opencode") { body["max_tokens"] = 500 }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              var content = msg["content"] as? String else {
            return local
        }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}") {
            content = String(content[start...end])
        }
        guard let d = content.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let p = parsed["primary"] as? String, labels.contains(p) else {
            return local
        }
        let s = (parsed["secondary"] as? String).flatMap { labels.contains($0) ? $0 : nil } ?? "中性"
        return ToneResult(primary: p, secondary: s, source: "model")
    }
}
