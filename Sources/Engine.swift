// Engine.swift — 纯逻辑层：语言门控、术语硬闸、LLM 契约、失败态文案
// 这一层不碰 AX、不碰 UI，可被 selftest 直接驱动。

import Foundation

// MARK: - 配置

struct LLMConfig: Codable, Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    static let empty = LLMConfig(baseURL: "", apiKey: "", model: "")

    var isComplete: Bool {
        !baseURL.trimmed.isEmpty && !apiKey.trimmed.isEmpty && !model.trimmed.isEmpty
    }

    /// base URL 允许写 `https://host/v1` 或 `https://host/v1/chat/completions`
    var endpoint: URL? {
        var b = baseURL.trimmed
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/chat/completions") { b.removeLast("/chat/completions".count) }
        let full = b + "/chat/completions"
        guard b.lowercased().hasPrefix("http") else { return nil }
        return URL(string: full)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - 语言门控

/// 非空白字符里 CJK 码点所占比例
func cjkRatio(_ s: String) -> Double {
    var total = 0
    var cjk = 0
    for u in s.unicodeScalars {
        if CharacterSet.whitespacesAndNewlines.contains(u) { continue }
        total += 1
        if isCJK(u) { cjk += 1 }
    }
    return total == 0 ? 0 : Double(cjk) / Double(total)
}

func isCJK(_ u: Unicode.Scalar) -> Bool {
    switch u.value {
    case 0x3000...0x303F:   return true   // CJK 标点
    case 0x3040...0x30FF:   return true   // 日文假名
    case 0x3400...0x4DBF:   return true   // 扩展 A
    case 0x4E00...0x9FFF:   return true   // 基本汉字
    case 0xAC00...0xD7AF:   return true   // 韩文
    case 0xF900...0xFAFF:   return true   // 兼容汉字
    case 0xFF00...0xFFEF:   return true   // 全角
    case 0x20000...0x2FA1F: return true   // 扩展 B+
    default:                return false
    }
}

let cjkGateThreshold = 0.40

/// 门控：中文占比超阈值就不介入（不取全文、不发请求）
func shouldSkipAsChinese(_ s: String) -> Bool { cjkRatio(s) > cjkGateThreshold }

// MARK: - 术语硬闸

/// 词表：出现即原样保留，任何建议都不许改动它们本身
let glossaryTerms: Set<String> = [
    "fcl", "lcl", "bl", "b/l", "etd", "eta", "ata", "atd",
    "so", "si", "vgm", "cy", "cfs", "thc", "pod", "pol",
    "hbl", "mbl", "d/o", "c/o", "imo", "hs", "dg", "teu", "feu",
    "dap", "cif", "fob", "cfr", "ddp", "exw", "msds", "po", "pi", "ci", "pl",
]

/// 切成 token：字母数字与 `/` 保留（B/L、D/O 不被打散），其余作分隔符
func tokenize(_ s: String) -> [String] {
    var out: [String] = []
    var cur = ""
    for ch in s {
        if ch.isLetter || ch.isNumber || ch == "/" {
            cur.append(ch)
        } else if !cur.isEmpty {
            out.append(cur); cur = ""
        }
    }
    if !cur.isEmpty { out.append(cur) }
    return out
}

/// 抽出文本里被当作「术语」出现的 token，**保留原样大小写**（DoD 要求 byte-for-byte 保留）
func glossaryOccurrences(_ s: String) -> [String] {
    tokenize(s).compactMap { t in
        let lower = t.lowercased()
        guard glossaryTerms.contains(lower) else { return nil }
        if lower.count <= 2 && t == lower { return nil }   // 小写短词 → 不认（so/po 这类普通词）
        return t                                          // ★ 原样返回，不做 lowercased
    }
}

enum GateResult: Equatable {
    case pass
    case drop(String)   // 丢弃原因（写进诊断日志）
}

/// 术语硬闸：
/// ① 无改动 = 原文与建议只差空白 → 丢弃
/// ② 术语 token 的原样形态（含大小写）任何一处变化 → 丢弃
func glossaryGate(original: String, suggestion: String) -> GateResult {
    if collapseWhitespace(original) == collapseWhitespace(suggestion) {
        return .drop("模型没改动任何内容")
    }
    let a = glossaryOccurrences(original).sorted()
    let b = glossaryOccurrences(suggestion).sorted()
    if a != b {
        let changed = Set(a).symmetricDifference(Set(b)).sorted().joined(separator: ",")
        return .drop("术语被改动：\(changed.isEmpty ? a.joined(separator: ",") : changed)")
    }
    return .pass
}

/// 去掉所有空白后比较（大小写敏感）
func collapseWhitespace(_ s: String) -> String {
    String(s.filter { !$0.isWhitespace })
}

// MARK: - 提示词

func systemPrompt() -> String {
    let terms = glossaryTerms.sorted().joined(separator: " ")
    return """
    You are a proofreading engine for a Chinese shipping-logistics professional writing English emails.
    Return ONLY a JSON object, no markdown fence, no prose:
    {"original":"<the exact input text, unchanged>","suggestion":"<the corrected full text>","reason":"<one short sentence in Chinese explaining the main fix>"}

    Rules:
    1. Fix only real grammar, spelling and article/preposition errors. Do not rephrase for style, do not shorten, do not translate.
    2. Industry terms must be preserved byte-for-byte, never expanded or corrected: \(terms)
    3. Keep the original line breaks, greeting and sign-off.
    4. If the text has no error, return suggestion identical to original.
    """
}

func userPrompt(_ text: String) -> String {
    "Text to proofread:\n\"\"\"\n\(text)\n\"\"\""
}

// MARK: - 失败态

enum ReviewFailure: Error {
    case tooLong(Int)
    case notConfigured
    case http(Int, String)
    case badJSON(String)
    case timeout
    case network(String)

    /// 用户可见文案（每种失败一行，不吞错）
    var userMessage: String {
        switch self {
        case .tooLong(let n):
            return "选中太长（\(n) > 2000 字符），请分段"
        case .notConfigured:
            return "还没填 API 配置：设置 → base URL / key / model 三项"
        case .http(let code, let body):
            let head = body.replacingOccurrences(of: "\n", with: " ").prefix(120)
            return "接口返回 HTTP \(code)：\(head)"
        case .badJSON(let raw):
            let head = raw.replacingOccurrences(of: "\n", with: " ").prefix(120)
            return "模型没按 JSON 回，原文未改动（\(head)）"
        case .timeout:
            return "15 秒没回话，检查网络或 base URL"
        case .network(let detail):
            return "连不上：\(detail)"
        }
    }

    var retryable: Bool {
        switch self {
        case .timeout, .network, .http: return true
        default: return false
        }
    }
}

let maxInputCharacters = 2000
let requestTimeout: TimeInterval = 15

// MARK: - 响应解析

/// 容忍 ```json 围栏、前后杂字符
func parseSuggestionPayload(_ content: String) -> Suggestion? {
    var s = content.trimmed
    if s.hasPrefix("```") {
        if let firstNewline = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: firstNewline)...])
        }
        if let fence = s.range(of: "```", options: .backwards) { s = String(s[..<fence.lowerBound]) }
        s = s.trimmed
    }
    guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}") else { return nil }
    let json = String(s[start...end])
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Suggestion.self, from: data)
}

struct Suggestion: Codable, Equatable {
    var original: String
    var suggestion: String
    var reason: String
}

// MARK: - 调用

struct ReviewOutcome {
    var suggestion: Suggestion
    var endpoint: String
    var model: String
    var elapsed: Double
}

enum Engine {
    /// 一次整段重写。抛 ReviewFailure，调用方直接展示 userMessage。
    static func review(text: String, config: LLMConfig, timeout: TimeInterval = requestTimeout,
                       session: URLSession = .shared) async throws -> ReviewOutcome {
        let n = text.count
        guard n <= maxInputCharacters else { throw ReviewFailure.tooLong(n) }
        guard config.isComplete, let url = config.endpoint else { throw ReviewFailure.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(config.apiKey.trimmed)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": config.model.trimmed,
            "temperature": 0,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": userPrompt(text)],
            ],
        ]
        // 快速模式：关推理链。11-19 实测同一句 12 句文本，带推理 19.2s（推理吃满 1200 token、输出被截断），
        // 不传则 74s；传 reasoning_effort:none 后 10.6s、推理 token=0。
        let fast = CategoryPrefs.fastMode()
        if fast { body["reasoning_effort"] = "none" }
        if config.baseURL.lowercased().contains("opencode") { body["max_tokens"] = 4000 }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        // 请求体摘要进日志：下次一眼看出到底是「没传 reasoning_effort」还是「传了没生效」
        let sentences = Scorer.splitSentences(text).count
        RequestLog.append(model: config.model.trimmed,
                          reasoning: fast ? "none" : "(默认·带推理)",
                          maxTokens: (body["max_tokens"] as? Int) ?? 0,
                          sentences: sentences, chars: n)

        let t0 = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw ReviewFailure.timeout
        } catch {
            throw ReviewFailure.network((error as NSError).localizedDescription)
        }

        let elapsed = Date().timeIntervalSince(t0)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        let raw = String(data: data, encoding: .utf8) ?? ""
        guard code == 200 else { throw ReviewFailure.http(code, raw) }

        let content: String = {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let msg = choices.first?["message"] as? [String: Any],
               let c = msg["content"] as? String {
                return c
            }
            return ""
        }()
        guard let parsed = parseSuggestionPayload(content) else { throw ReviewFailure.badJSON(content) }

        return ReviewOutcome(suggestion: parsed, endpoint: url.absoluteString, model: config.model, elapsed: elapsed)
    }

    /// 同步回调版本：给 selftest 里「阻塞等结果」的场景用
    static func reviewT(text: String, config: LLMConfig, timeout: TimeInterval,
                        completion: @escaping (Result<ReviewOutcome, Error>) -> Void) {
        Task.detached {
            do {
                let r = try await review(text: text, config: config, timeout: timeout)
                completion(.success(r))
            } catch {
                completion(.failure(error))
            }
        }
    }
}
