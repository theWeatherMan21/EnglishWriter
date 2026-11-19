// UserPrefs.swift — 个人词典 + 忽略规则（「接受了 / 别再报」的记忆层）
//
// 三条持久化分工（全部在 com.wanyi.englishwriter 域，验收可直接 defaults read）：
//   · 个人词典  dict.words     [String]     用户加的词，引擎再怎么报都丢掉
//   · 永久忽略  ignore.rules   [[String]]   [[原词, 建议]]，同一对以后不再提示
//   · 本次忽略  ——            只在内存      本次运行内不再提示，退出即失效、绝不落盘
//
// 零预设默认值：没有内置词表，全靠用户自己加。
// 过滤统一入口是 PersonalFilter（两条引擎通道共用），这里只负责存与查。

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

    /// 永久规则（落盘）
    private static let key = "ignore.rules"
    /// 本次规则（只在内存；token 分隔符用不可打印字符，避免和原词里的冒号/箭头撞车）
    private static let sep = "\u{1}"

    private var rules: [(original: String, replacement: String)] = []
    private var session: Set<String> = []
    /// M3 规格：忽略集合按「文本 hash」存 —— 同一句里同一处建议再次出现时直接过滤掉。
    /// 键 = M3Ignore.hash(original:replacement)，与上面的规则表并存（老规则照样认）。
    private static let hashKey = "ignore.hashes"
    private var hashes: Set<String> = []
    private var loaded = false

    static func token(original: String, replacement: String) -> String {
        original + sep + replacement
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let raw = (SettingsStore.store.array(forKey: Self.key) as? [[String]]) ?? []
        rules = raw.compactMap { pair in
            guard pair.count == 2 else { return nil }
            return (pair[0], pair[1])
        }
        hashes = Set((SettingsStore.store.array(forKey: Self.hashKey) as? [String]) ?? [])
    }

    private func persist() {
        SettingsStore.store.set(rules.map { [$0.original, $0.replacement] }, forKey: Self.key)
        SettingsStore.store.set(Array(hashes).sorted(), forKey: Self.hashKey)
    }

    /// 永久规则 ∪ 本次规则 ∪ 文本 hash 集合：任一条命中都算忽略
    func isIgnored(original: String, replacement: String) -> Bool {
        loadIfNeeded()
        if hashes.contains(M3Ignore.hash(original: original, replacement: replacement)) { return true }
        if session.contains(Self.token(original: original, replacement: replacement)) { return true }
        return rules.contains { $0.original == original && $0.replacement == replacement }
    }

    func isIgnored(hash: String) -> Bool { loadIfNeeded(); return hashes.contains(hash) }

    /// 「本次忽略」：只进内存，绝不落盘（App 重启后重新会提示）
    @discardableResult
    func ignoreSession(original: String, replacement: String) -> Bool {
        loadIfNeeded()
        let t = Self.token(original: original, replacement: replacement)
        guard !session.contains(t) else { return false }
        session.insert(t)
        return true
    }

    /// 「不再提示」：落盘，跨重启有效（同时记文本 hash，供后续检查结果过滤）
    @discardableResult
    func ignore(original: String, replacement: String) -> Bool {
        loadIfNeeded()
        guard !isIgnored(original: original, replacement: replacement) else { return false }
        rules.append((original: original, replacement: replacement))
        hashes.insert(M3Ignore.hash(original: original, replacement: replacement))
        persist()
        return true
    }

    /// 永久规则条数（设置面板显示）
    var count: Int { loadIfNeeded(); return rules.count }
    /// 本次忽略条数（设置面板显示）
    var sessionCount: Int { loadIfNeeded(); return session.count }

    /// 自测用：改了域里的原始值之后让内存缓存重新读一次
    func reloadForTesting() { loaded = false; loadIfNeeded() }

    /// 只清本次（不动落盘规则）
    func clearSession() { session.removeAll() }

    /// 清永久规则
    func clear() {
        loadIfNeeded()
        rules = []
        hashes = []
        persist()
    }
}
