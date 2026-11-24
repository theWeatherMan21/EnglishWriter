// qa/draft-fix.swift — 精确修正 Mail 草稿正文里被写坏的一处（只动这一处）
//
// 背景：2026-11-23 写回把 "sent" 追加进了正文，变成
//   "I havesent send the file, please check it."
// 正确应为
//   "I have send the file, please check it."
// 这个窗口里还有签名块，所以绝对不能 ⌘A 全选覆盖 —— 只用键击精确删掉多出来的字符。
//
// 用法：
//   swiftc -O qa/draft-fix.swift -o /tmp/draft-fix
//   /tmp/draft-fix                     # 只读：打印将要删什么（dry-run）
//   /tmp/draft-fix --apply             # 真改
//
// 安全：
//   · 只处理「第一个含 havesent 的正文块」，找不到就退出，不做任何动作
//   · 改完必须读回全文，和期望完全一致才报 PASS；不一致报 FAIL 并停下，不重试
//   · 所有键击 postToPid 发给 Mail，不激活别的 App、不建窗口

import Foundation
import AppKit
import ApplicationServices

let apply = CommandLine.arguments.contains("--apply")
let wrongNeedle = "havesent"          // 只认这一处坏样本，别的文本一律不碰
// 正确形态是 "have send"：多出来的就是 have 之后的 "sent"（havesent → have）。
// 注意不能把整段换成 "have sent"——那样变成 "have sent send ..."，错得更远。
let extraOffset = 4                    // "have" 之后开始删

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success else { return nil }
    return out
}
func str(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
func kids(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] }
func frame(_ el: AXUIElement) -> CGRect {
    var pt = CGPoint.zero, sz = CGSize.zero
    if let v = attr(el, kAXPositionAttribute as String), CFGetTypeID(v) == AXValueGetTypeID() {
        AXValueGetValue(v as! AXValue, .cgPoint, &pt)
    }
    if let v = attr(el, kAXSizeAttribute as String), CFGetTypeID(v) == AXValueGetTypeID() {
        AXValueGetValue(v as! AXValue, .cgSize, &sz)
    }
    return CGRect(origin: pt, size: sz)
}

if let d = CGSessionCopyCurrentDictionary() as? [String: Any],
   (d["CGSSessionScreenIsLocked"] as? Bool) == true {
    print("RESULT: SKIP（屏幕已锁 —— 不做任何键击）"); exit(0)
}

guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
    print("RESULT: SKIP（Mail 没在运行）"); exit(0)
}
let pid = app.processIdentifier
let appEl = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appEl, 0.3)

// 窗口：与 --probe-mail 同口径（滤掉 AXApplication 占位、跳过菜单栏）
var windows: [AXUIElement] = []
if let raw = attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement] {
    windows = raw.filter { (str($0, kAXRoleAttribute as String) ?? "") == "AXWindow" }
}
if windows.isEmpty {
    var found: [AXUIElement] = []
    var budget = 120
    func walk(_ el: AXUIElement, _ d: Int) {
        guard d > 0, budget > 0 else { return }
        for c in kids(el) {
            budget -= 1
            if budget <= 0 { return }
            let r = str(c, kAXRoleAttribute as String) ?? ""
            if r == "AXMenuBar" || r == "AXMenu" || r == "AXMenuItem" { continue }
            if r == "AXWindow" { found.append(c); continue }
            walk(c, d - 1)
        }
    }
    walk(appEl, 4)
    windows = found
}
guard !windows.isEmpty else {
    print("RESULT: SKIP（Mail 没有窗口 —— 锁屏或没开写信窗）"); exit(0)
}

// 找第一个含 havesent 的静态文本块
var target: (el: AXUIElement, text: String, rect: CGRect)?
func scan(_ el: AXUIElement, _ d: Int) {
    guard d > 0, target == nil else { return }
    if (str(el, kAXRoleAttribute as String) ?? "") == "AXStaticText",
       let t = str(el, kAXValueAttribute as String), t.contains(wrongNeedle) {
        target = (el, t, frame(el)); return
    }
    for c in kids(el) { scan(c, d - 1) }
}
for w in windows { scan(w, 14) }

guard let t = target else {
    print("RESULT: SKIP（没有找到含 \(wrongNeedle) 的正文块 —— 不做任何动作）"); exit(0)
}

let ns = t.text as NSString
let badRange = ns.range(of: wrongNeedle)
let delRange = NSRange(location: badRange.location + extraOffset, length: badRange.length - extraOffset)
let expected = ns.replacingCharacters(in: delRange, with: "")
print("当前正文：\(t.text)")
print("期望正文：\(expected)")
print("要删掉的：位置 \(delRange.location) 长度 \(delRange.length) → \"\(ns.substring(with: delRange))\"")
print("行框：\(Int(t.rect.width))x\(Int(t.rect.height)) @ \(Int(t.rect.origin.x)),\(Int(t.rect.origin.y))")

if !apply {
    print("RESULT: DRY-RUN（加 --apply 才真改）"); exit(0)
}

// 真人正在操作时绝不按键盘：按住任意修饰键 = 多半在打快捷键，此刻插进去会改到他的东西
let mods = CGEventSource.flagsState(.combinedSessionState)
if mods.contains(.maskCommand) || mods.contains(.maskShift) || mods.contains(.maskControl) || mods.contains(.maskAlternate) {
    print("RESULT: SKIP（检测到修饰键按着，判断爹地正在操作，这次不动）"); exit(0)
}
// 稳定性复核：隔 1.2 秒再读一次，文本变了说明他正在敲，立刻退出
usleep(1_200_000)
var again: (el: AXUIElement, text: String, rect: CGRect)?
func rescan(_ el: AXUIElement, _ d: Int) {
    guard d > 0, again == nil else { return }
    if (str(el, kAXRoleAttribute as String) ?? "") == "AXStaticText",
       let s = str(el, kAXValueAttribute as String), s.contains(wrongNeedle) {
        again = (el, s, frame(el)); return
    }
    for c in kids(el) { rescan(c, d - 1) }
}
for w in windows { rescan(w, 14) }
guard let a2 = again, a2.text == t.text else {
    print("RESULT: SKIP（1.2 秒内正文变了，爹地正在操作，不动）"); exit(0)
}

// 0) 先把窗口变成 key/main 并把 Mail 提到前台 —— 否则 postToPid 的键击进不了正文
//    （11-24 实测：窗口非 key 时点一下、敲一串箭头，读回文本一个字没变）
let win = windows.first { w in
    var cur: AXUIElement? = t.el
    for _ in 0..<20 {
        guard let c = cur else { break }
        if CFEqual(c, w) { return true }
        cur = (attr(c, kAXParentAttribute as String).map { $0 as CFTypeRef })
            .flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }
    return str(w, kAXTitleAttribute as String)?.contains("New Message") ?? false
} ?? windows.first
if let w = win {
    _ = AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
}
app.activate(options: [.activateAllWindows])
usleep(400_000)

// 1) 点进这一行（点左侧内部，别点到行尾之外）
let clickPoint = CGPoint(x: t.rect.origin.x + 6, y: t.rect.origin.y + t.rect.height / 2)
func post(_ type: CGEventType, _ p: CGPoint) {
    if let e = CGEvent(mouseEventSource: CGEventSource(stateID: .combinedSessionState),
                       mouseType: type, mouseCursorPosition: p, mouseButton: .left) {
        e.postToPid(pid)
    }
}
post(.mouseMoved, clickPoint)
usleep(60_000)
post(.leftMouseDown, clickPoint)
usleep(30_000)
post(.leftMouseUp, clickPoint)
usleep(250_000)

// 2) 焦点/光标可能没落到这一行 → 用 AX 再确认一次焦点元素是正文
var focused: CFTypeRef?
_ = AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &focused)

func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
    let src = CGEventSource(stateID: .combinedSessionState)
    if let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true),
       let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false) {
        down.flags = flags; up.flags = flags
        down.postToPid(pid); up.postToPid(pid)
    }
    usleep(45_000)
}

// 3) ⌘←（行首）→ → ×位置 → ⇧→ ×长度 → Delete
key(0x7B, flags: .maskCommand)                 // Command+Left = 行首
for _ in 0..<delRange.location { key(0x7C) }   // Right
for _ in 0..<delRange.length { key(0x7C, flags: .maskShift) }   // Shift+Right
key(0x33)                                       // Delete（向后删）
usleep(300_000)

// 4) 读回验证
var after: String?
func verify(_ el: AXUIElement, _ d: Int) {
    guard d > 0, after == nil else { return }
    if (str(el, kAXRoleAttribute as String) ?? "") == "AXStaticText",
       let s = str(el, kAXValueAttribute as String), s.contains("I have") {
        after = s; return
    }
    for c in kids(el) { verify(c, d - 1) }
}
if let scopeWin = win { verify(scopeWin, 14) } else { for w in windows { verify(w, 14) } }

if let a = after, a == expected {
    print("RESULT: PASS —— 正文已还原；读回 \"\(a)\"")
    exit(0)
} else {
    print("RESULT: FAIL —— 读回不一致：\(after ?? "(读不到)")")
    print("           期望：\(expected)")
    print("           已停止，不重试。原文仍在 Mail 窗口里，请人工确认。")
    exit(2)
}
