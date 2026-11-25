import AppKit
import ApplicationServices

/// 窗口级 AX 查询缓存（2 秒）。
///
/// 背景（知澜 11-25 实测）：Mail 忙的时候，kAXWindows / kAXMainWindow / kAXFocusedWindow
/// 单个就要 400ms，而我们每轮要问 3 次 → 每 10 秒出现两次 1.4 秒的主线程堵死，
/// 爹地点 menubar / 悬浮球正好撞上就卡死。
/// 窗口集合本身是低频变化的（开/关窗），2 秒缓存对体验无损，对 AX 压力是十倍级的下降。
enum WindowCache {
    static let ttl: TimeInterval = 2.0

    private struct Entry {
        let pid: pid_t
        let at: Date
        let focused: AXUIElement?
        let main: AXUIElement?
        let all: [AXUIElement]
    }
    private static var entry: Entry?
    private static var hits = 0
    private static var misses = 0

    static func snapshot(pid: pid_t) -> (focused: AXUIElement?, main: AXUIElement?, all: [AXUIElement]) {
        if let e = entry, e.pid == pid, Date().timeIntervalSince(e.at) < ttl {
            hits += 1
            return (e.focused, e.main, e.all)
        }
        misses += 1
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)
        let focused = element(appEl, kAXFocusedWindowAttribute as String)
        let main = element(appEl, kAXMainWindowAttribute as String)
        let all = windows(appEl)
        entry = Entry(pid: pid, at: Date(), focused: focused, main: main, all: all)
        return (focused, main, all)
    }

    /// 主动失效（开/关窗、切宿主时调一次，避免新窗口要等 2 秒才被看见）
    static func invalidate() { entry = nil }

    static func stats() -> String { "hit=\(hits) miss=\(misses)" }

    private static func element(_ appEl: AXUIElement, _ key: String) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, key as CFString, &raw) == .success,
              let v = raw, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    /// CFArray 必须手工下标：Mail 忙时 `as? [AXUIElement]` 直接失败（11-25 实测读 0 个）
    private static func windows(_ appEl: AXUIElement) -> [AXUIElement] {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &raw) == .success,
              let arr = raw, CFGetTypeID(arr) == CFArrayGetTypeID() else { return [] }
        let cf = arr as! CFArray
        let wins = (0..<CFArrayGetCount(cf)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(cf, $0), to: AXUIElement.self)
        }
        let real = wins.filter { roleIs($0, "AXWindow") }
        return real.isEmpty ? wins : real
    }

    private static func roleIs(_ el: AXUIElement, _ want: String) -> Bool {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &raw) == .success,
              let s = raw as? String else { return false }
        return s == want
    }
}
