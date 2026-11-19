// ScreenLock.swift — 锁屏检测
//
// 为什么必须有：屏幕锁上之后，别的 App 的 AX 树只剩骨架
// （AXWindows 里是 AXApplication 占位、children 全是菜单栏），探针会得到
// 「没有窗口 / 读不到文本」这种**假失败**，进而污染 KPI 和 CI 结论。
// 11-19 23:00 实测：CGSSessionScreenIsLocked = true 时 TextEdit/Mail/Finder 同时退化。
//
// 规矩：依赖 AX 的探针启动时先问这个，锁屏就打印 SKIP 并以 77 退出（不是 FAIL）。

import Foundation
import CoreGraphics

enum ScreenLock {
    static var isLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if let v = dict["CGSSessionScreenIsLocked"] as? Bool { return v }
        if let n = dict["CGSSessionScreenIsLocked"] as? NSNumber { return n.boolValue }
        return false
    }

    /// 轮询门控（纯函数，可断言）：锁屏 / 登录窗 / 未启用 / 无 pid 时都不轮询，
    /// 免得夜里把 loginwindow 的假 attach 灌进 check-log（11-19 实测 649 条）。
    static func shouldPoll(locked: Bool, enabled: Bool, pid: pid_t, appName: String) -> Bool {
        if locked { return false }
        if !enabled { return false }
        if pid <= 0 { return false }
        if appName == "loginwindow" { return false }
        return true
    }

    /// 挂观察者 / 发 attach-app 的门控（纯函数，可断言）。
    /// 11-19 发现：emit 在 isLocked 判断之前就发出了，夜里仍会写 attach-app loginwindow。
    static func shouldAttach(locked: Bool, appName: String) -> Bool {
        if locked { return false }
        if appName == "loginwindow" { return false }
        return true
    }

    /// 探针入口统一调用：锁屏就返回 true（调用方应打印 SKIP 并 exit(77)）
    static func bailIfLocked(_ probe: String) -> Bool {
        guard isLocked else { return false }
        print("SKIP screen-locked  \(probe)：屏幕已锁，AX 树只剩骨架，本次不判定（不是失败）")
        return true
    }
}
