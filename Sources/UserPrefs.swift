// UserPrefs.swift — 个人词典 + 忽略规则（M3 的「接受了/别再报」记忆）
//
// 两条都存 UserDefaults，跨重启有效：
//   · 个人词典：用户加的词，引擎再怎么报都丢掉（拼写误报的主出口）
//   · 忽略规则：某条「原词→建议」用户点了忽略，以后同一对不再提示
// 零预设默认值：没有内置词表，全靠用户自己加。

import Foundation

enum DictStore {
    private static let key = "dict.words"
    /// 与设置同一个域（com.wanyi.englishwriter）：命令行裸二进制与 .app 读写一致
    private static var d: UserDefaults { SettingsStore.store }

    static var words: [String] {
        get { (d.array(forKey: key) as? [String]) ?? [] }
        set { d.set(newValue, forKey: key) }
    }

    static func add(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        var list = words
        guard !list.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        list.append(w)
        words = list
    }

    static func remove(_ word: String) {
        words = words.filter { $0.caseInsensitiveCompare(word) != .orderedSame }
    }

    /// 单个 token 是否在词典里（忽略大小写）
    static func contains(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        return words.contains { $0.caseInsensitiveCompare(t) == .orderedSame }
    }

    /// 文本里含词典词（短语也算）
    static func hit(in text: String) -> Bool {
        let lowered = text.lowercased()
        return words.contains { !$0.isEmpty && lowered.contains($0.lowercased()) }
    }
}

final class IgnoreStore {
    static let shared = IgnoreStore()
    private static let key = "ignore.rules"
    private var rules: [(original: String, replacement: String)] = []
    private var loaded = false

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let raw = (SettingsStore.store.array(forKey: Self.key) as? [[String]]) ?? []
        rules = raw.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
    }

    private func persist() {
        SettingsStore.store.set(rules.map { [$0.original, $0.replacement] }, forKey: Self.key)
    }

    func isIgnored(original: String, replacement: String) -> Bool {
        loadIfNeeded()
        return rules.contains { $0.original == original && $0.replacement == replacement }
    }

    @discardableResult
    func ignore(original: String, replacement: String) -> Bool {
        loadIfNeeded()
        guard !isIgnored(original: original, replacement: replacement) else { return false }
        rules.append((original: original, replacement: replacement))
        persist()
        return true
    }

    var count: Int { loadIfNeeded(); return rules.count }

    /// 自测用：改了域里的原始值之后让内存缓存重新读一次
    func reloadForTesting() { loaded = false; loadIfNeeded() }

    func clear() {
        loadIfNeeded()
        rules = []
        persist()
    }
}
