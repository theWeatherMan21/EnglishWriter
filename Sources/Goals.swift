// Goals.swift — P4 写作目标（受众 / 正式度 / 意图 / 领域）
//
// 爹地的老规矩：零预设。四项默认全部「未设置」，用户自己选；未设置时评分给中性分、
// 提示词里也不拼任何目标（不许替他假设「客户 / 正式 / 告知」）。
//
// 影响面：
//   · Delivery 分数：与目标正式度的偏差（Scorer 的 formality 参数）
//   · 提示词：设了才拼进去，改建议口径（对客户 vs 对同事，正式 vs 随意）
//   · 不参与语言门控、不影响 correctness/clarity 的计算口径

import Foundation

struct Goals: Codable, Equatable {
    var audience: String?      // 客户 / 同事 / 上级 / 通用
    var formality: Int?        // 0 随意 … 4 正式
    var intent: String?        // 告知 / 请求 / 说服 / 致歉
    var domain: String?        // 商务 / 学术 / 日常

    var isEmpty: Bool {
        audience == nil && formality == nil && intent == nil && domain == nil
    }

    /// 拼进提示词（未设置就一个字都不加）
    var promptSuffix: String {
        guard !isEmpty else { return "" }
        var lines: [String] = []
        if let a = audience { lines.append("Audience: \(a)") }
        if let f = formality { lines.append("Formality target: \(f)/4") }
        if let i = intent { lines.append("Intent: \(i)") }
        if let d = domain { lines.append("Domain: \(d)") }
        return "\n\nWriter's goals (respect these):\n" + lines.joined(separator: "\n")
    }
}

enum GoalsStore {
    private static let key = "goals.v1"

    static func load(_ d: UserDefaults = SettingsStore.store) -> Goals {
        guard let raw = d.data(forKey: key),
              let g = try? JSONDecoder().decode(Goals.self, from: raw) else { return Goals() }
        return g
    }

    static func save(_ g: Goals, _ d: UserDefaults = SettingsStore.store) {
        // 四项全空就直接删键，别留一个「看起来设置过」的空对象
        if g.isEmpty {
            d.removeObject(forKey: key)
            return
        }
        if let data = try? JSONEncoder().encode(g) { d.set(data, forKey: key) }
    }

    static func clear(_ d: UserDefaults = SettingsStore.store) {
        d.removeObject(forKey: key)
    }
}
