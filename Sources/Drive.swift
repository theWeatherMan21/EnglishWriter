// Drive.swift — 真机驱动：点一下、⌘A、逐字打字（全部走 CGEvent，目标 App 的 pid 收）
//
// 用途：真机验收要在 Mail 里「像人一样」敲一段英文，而不是直接改 AXValue ——
// 直接改值不会触发 App 的真实编辑路径，验不出「键入即检查」这条链。

import AppKit
import ApplicationServices

enum Drive {

    static func activate(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        app.activate(options: [.activateAllWindows])
        usleep(400_000)
    }

    /// 全局坐标（Quartz 左上原点）单击
    @discardableResult
    static func click(at p: CGPoint, to pid: pid_t) -> Bool {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                                 mouseCursorPosition: p, mouseButton: .left),
              let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                               mouseCursorPosition: p, mouseButton: .left) else { return false }
        down.postToPid(pid)
        usleep(40_000)
        up.postToPid(pid)
        usleep(160_000)
        return true
    }

    /// ⌘A 全选（清空正文用）
    static func selectAll(to pid: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x00, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        usleep(120_000)
    }

    /// 逐段打字（unicode 事件，不依赖键位布局）
    static func type(_ text: String, to pid: pid_t, chunk: Int = 12, delayUS: UInt32 = 25_000) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let n = min(chunk, units.count - i)
            let slice = Array(units[i..<(i + n)])
            if let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) {
                down.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: slice)
                down.postToPid(pid)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) {
                up.keyboardSetUnicodeString(stringLength: slice.count, unicodeString: slice)
                up.postToPid(pid)
            }
            i += n
            usleep(delayUS)
        }
    }
}
