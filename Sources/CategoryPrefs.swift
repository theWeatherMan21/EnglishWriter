// CategoryPrefs.swift — 类别开关 + 敏感度 + 结果过滤（纯函数，可断言）
//
// Grammarly 的设置里有「哪几类要报」和「报得多凶」。这里落地成两个可持久化的偏好：
//   enabledTypes：spelling / grammar / clarity / style 四类各自开关（默认全开）
//   sensitivity：轻度 / 标准 / 激进
//     轻度 = 只报拼写+语法，风格类一律不出（最安静）
//     标准 = 四类都报（默认）
//     激进 = 四类都报，且允许「同段多条」（不做激进降噪，交由 consolidate 收敛）
//
// 过滤本身是纯函数：给定 items 与偏好，输出应显示的 items —— 这样能穷举断言，
// 不依赖任何宿主。

import Foundation

enum Sensitivity: String, CaseIterable {
    case light = "轻度"
    case standard = "标准"
    case aggressive = "激进"

    var note: String {
        switch self {
        case .light: return "只报拼写与语法，最安静"
        case .standard: return "四类都报（默认）"
        case .aggressive: return "四类都报，且不压制同段多条"
        }
    }

    /// 轻度时强制关闭的类型
    var suppressedTypes: Set<String> {
        switch self {
        case .light: return ["clarity", "style"]
        case .standard, .aggressive: return []
        }
    }
}

enum CategoryPrefs {

    static let allTypes = ["spelling", "grammar", "clarity", "style"]
    private static let kTypes = "check.enabledTypes"
    private static let kSensitivity = "check.sensitivity"
    private static let kFastMode = "check.fastMode"

    static func enabledTypes(_ d: UserDefaults = SettingsStore.store) -> Set<String> {
        guard let arr = d.array(forKey: kTypes) as? [String], !arr.isEmpty else { return Set(allTypes) }
        return Set(arr).intersection(allTypes)
    }

    static func setEnabledTypes(_ s: Set<String>, _ d: UserDefaults = SettingsStore.store) {
        d.set(Array(s.intersection(allTypes)).sorted(), forKey: kTypes)
    }

    static func isEnabled(_ type: String, _ d: UserDefaults = SettingsStore.store) -> Bool {
        enabledTypes(d).contains(type)
    }

    static func sensitivity(_ d: UserDefaults = SettingsStore.store) -> Sensitivity {
        guard let raw = d.string(forKey: kSensitivity), let s = Sensitivity(rawValue: raw) else { return .standard }
        return s
    }

    static func setSensitivity(_ s: Sensitivity, _ d: UserDefaults = SettingsStore.store) {
        d.set(s.rawValue, forKey: kSensitivity)
    }

    // MARK: 快速模式（关推理链）
    //
    // 实测（11-18，deepseek-flash）：同一句同一 prompt，带推理链改写 18.3s；
    // 加 reasoning_effort:"none" 后 1–2s，三候选/逐条 edit/术语零触碰都不掉。
    // 默认开；复杂长句若效果掉了，用户可一键关掉回到带推理。
    static func fastMode(_ d: UserDefaults = SettingsStore.store) -> Bool {
        if d.object(forKey: kFastMode) == nil { return true }
        return d.bool(forKey: kFastMode)
    }

    static func setFastMode(_ on: Bool, _ d: UserDefaults = SettingsStore.store) {
        d.set(on, forKey: kFastMode)
    }

    // MARK: 过滤（纯函数）

    /// 真正要显示的条目：先按类别开关，再按敏感度压制；不含任何 IO
    static func filter(_ items: [DiffItem], enabled: Set<String>, sensitivity: Sensitivity) -> [DiffItem] {
        let blocked = sensitivity.suppressedTypes
        return items.filter { it in
            let t = it.kind.rawValue
            guard enabled.contains(t) else { return false }
            guard !blocked.contains(t) else { return false }
            return true
        }
    }

    /// 生产入口：读偏好后过滤
    static func filterForDisplay(_ items: [DiffItem], _ d: UserDefaults = SettingsStore.store) -> [DiffItem] {
        filter(items, enabled: enabledTypes(d), sensitivity: sensitivity(d))
    }
}
