// Audit.swift — 只读模式的副作用计数器（--passive --selfcheck 的仪器自证）
//
// 为什么需要它：--passive 声称「不写回、不上屏、不存正文」。这句话不能靠读代码自述，
// 也不能靠写日志的人自己说「我没写」——所以在所有「能把内容写进别人 App」和
// 「能让窗口真正上屏」的唯一入口处打点，自检时断言计数为 0。
//
// 计数语义是「调用次数」，不是「成功次数」：调用即记，失败也记。宁可多算，不许漏算。

import AppKit

enum Audit {
    /// 写回类调用：AXSelectedText 写 / 剪贴板 / applyEdits / WebText.replace
    private(set) static var writeCalls: [String: Int] = [:]
    /// 剪贴板写入（单独列，便于定位是哪条路漏了）
    private(set) static var pasteboardWrites = 0
    /// 自建窗口对象（UnderlineOverlay / CardPanel / HoverCardPanel / 设置窗 / Demo 窗）
    private(set) static var windowsCreated = 0
    /// 让窗口真正上屏的次数（orderFrontRegardless / makeKeyAndOrderFront）
    private(set) static var windowShows = 0

    static func write(_ name: String) { writeCalls[name, default: 0] += 1 }
    static func pasteboard() { pasteboardWrites += 1 }
    static func window() { windowsCreated += 1 }
    static func show() { windowShows += 1 }

    static var writeTotal: Int { writeCalls.values.reduce(0, +) }

    static func reset() {
        writeCalls = [:]
        pasteboardWrites = 0
        windowsCreated = 0
        windowShows = 0
    }

    static var snapshot: [String: Any] {
        [
            "writeCalls": writeCalls,
            "writeTotal": writeTotal,
            "pasteboardWrites": pasteboardWrites,
            "windowsCreated": windowsCreated,
            "windowShows": windowShows,
        ]
    }
}
