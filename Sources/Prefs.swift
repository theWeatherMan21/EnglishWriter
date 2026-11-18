// Prefs.swift — 引擎地址 / 方言 / App 排除（连同三件套一起构成设置面板的可保存状态）
//
// 三条纪律：
//   1. 零预设：llm 三件套（baseURL / apiKey / model）不写任何默认值，没填就是空。
//   2. 引擎地址留空 = 用本机默认（127.0.0.1:8081），但「配置里」不落这个默认值，
//      用户随时能填成别人的 LanguageTool。
//   3. App 排除：填 bundle id 或应用名都认（小写比对），命中的 App 一个请求都不发。
//
// 存哪：显式 suite = com.wanyi.englishwriter —— 这样不论从 .app 跑还是从命令行裸二进制跑，
// 读写的都是同一个域，验收可以用 `defaults read com.wanyi.englishwriter` 直接核。

import Foundation

enum EnginePrefs {
    static let defaultLTBase = "http://127.0.0.1:8081"
    static let defaultLanguage = "en-GB"

    /// 界面下拉里给的方言（LanguageTool 的 language 参数）
    static let languages: [(code: String, label: String)] = [
        ("en-GB", "英式 en-GB"),
        ("en-US", "美式 en-US"),
        ("en-AU", "澳洲 en-AU"),
        ("en-CA", "加拿大 en-CA"),
        ("en-NZ", "新西兰 en-NZ"),
    ]

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 本地 LanguageTool 开关（默认关）
    //
    // 理由（2026-11-18 实测）：LT 是 JVM，Xmx 从 1g 砍到 256m，RSS 仍 368MB；
    // 关掉它就只剩 App 本体 61MB，拼写走 NSSpellChecker、清晰度/风格走本地规则、语法走模型接口。
    static func ltEnabled(_ d: UserDefaults = SettingsStore.store) -> Bool {
        d.bool(forKey: SettingsStore.kLTEnabled)
    }

    static func setLTEnabled(_ on: Bool, _ d: UserDefaults = SettingsStore.store) {
        d.set(on, forKey: SettingsStore.kLTEnabled)
    }

    // MARK: 本地引擎地址

    static func ltBaseURL(_ d: UserDefaults = SettingsStore.store) -> String {
        let v = trimmed(d.string(forKey: SettingsStore.kLTBase) ?? "")
        return v.isEmpty ? defaultLTBase : v
    }

    static func setLTBaseURL(_ v: String, _ d: UserDefaults = SettingsStore.store) {
        d.set(trimmed(v), forKey: SettingsStore.kLTBase)
    }

    // MARK: 方言

    static func language(_ d: UserDefaults = SettingsStore.store) -> String {
        let v = trimmed(d.string(forKey: SettingsStore.kLTLanguage) ?? "")
        if v.isEmpty { return defaultLanguage }
        return languages.contains { $0.code == v } ? v : v      // 允许手填非列表值
    }

    static func setLanguage(_ v: String, _ d: UserDefaults = SettingsStore.store) {
        let t = trimmed(v)
        d.set(t.isEmpty ? defaultLanguage : t, forKey: SettingsStore.kLTLanguage)
    }

    // MARK: App 排除

    static func excludedApps(_ d: UserDefaults = SettingsStore.store) -> [String] {
        (d.array(forKey: SettingsStore.kExcludedApps) as? [String]) ?? []
    }

    static func setExcludedApps(_ list: [String], _ d: UserDefaults = SettingsStore.store) {
        var out: [String] = []
        for raw in list {
            let t = trimmed(raw)
            guard !t.isEmpty else { continue }
            guard !out.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { continue }
            out.append(t)
        }
        d.set(out, forKey: SettingsStore.kExcludedApps)
    }

    @discardableResult
    static func addExcludedApp(_ v: String, _ d: UserDefaults = SettingsStore.store) -> Bool {
        let t = trimmed(v)
        guard !t.isEmpty else { return false }
        var list = excludedApps(d)
        guard !list.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return false }
        list.append(t)
        setExcludedApps(list, d)
        return true
    }

    static func removeExcludedApp(_ v: String, _ d: UserDefaults = SettingsStore.store) {
        setExcludedApps(excludedApps(d).filter { $0.caseInsensitiveCompare(v) != .orderedSame }, d)
    }

    /// 命中的 App：一个请求都不发（bundle id 或应用名任一匹配即排除）
    static func isExcluded(bundleId: String?, appName: String?, _ d: UserDefaults = SettingsStore.store) -> Bool {
        let list = excludedApps(d)
        guard !list.isEmpty else { return false }
        if let b = bundleId?.lowercased(), !b.isEmpty, list.contains(where: { $0.lowercased() == b }) { return true }
        if let n = appName?.lowercased(), !n.isEmpty, list.contains(where: { $0.lowercased() == n }) { return true }
        return false
    }
}
