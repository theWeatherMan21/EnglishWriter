// AXTarget.swift — 焦点输入框定位 / 选区读取 / 文本写回 / 撤销快照
// 沿用 axprobe/axfocus.swift 的四个坑解法：messagingTimeout、向上找可编辑祖先、
// AXSelectedText 三级回退、深度上限。
// 纪律：不许起 Timer、不许装 AXObserver、不许装 CGEventTap —— 只在被调用那一刻读一次 AX。

import AppKit
import ApplicationServices

// MARK: - 权限

enum AXPermission {
    static func granted() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary)
    }

    /// 弹系统授权框（仅用户点按钮时调，不自动弹）
    static func request() -> Bool {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    static func openSettingsPane() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - 快照

struct SelectionSnapshot {
    let pid: pid_t
    let appName: String
    let location: Int      // UTF-16 offset（AX 原生口径）
    let length: Int
    let text: String
    let element: AXUIElement
}

enum AXReadError: Error {
    case noPermission
    case noTargetApp
    case noFocusedElement
    case noSelection
    case emptySelection
    case unreadable

    var message: String {
        switch self {
        case .noPermission:     return "没有辅助功能权限：系统设置 → 隐私与安全性 → 辅助功能 里勾上本 App"
        case .noTargetApp:      return "没找到刚才在用的 App，请在目标窗口的输入框里选好文字再点"
        case .noFocusedElement: return "目标 App 里没有焦点输入框"
        case .noSelection:      return "没读到选区：先在输入框里选中要检查的文字"
        case .emptySelection:   return "选区是空的：先选中要检查的文字"
        case .unreadable:       return "这个输入框的文本读不到（App 未暴露 AX 文本属性）"
        }
    }
}

enum ApplyMethod: String {
    case axAttribute = "AX 直写"
    case pasteboard = "剪贴板粘贴"
    case failed = "失败"
}

struct ApplyResult {
    var ok: Bool
    var method: ApplyMethod
    var detail: String
}

// MARK: - 目标跟踪

final class AXTarget {
    static let shared = AXTarget()

    /// 最后一个「非本 App」的前台进程。面板打开会把前台抢走，所以必须提前记。
    private(set) var lastFrontmostPid: pid_t = 0
    private(set) var lastFrontmostName: String = ""
    private var observing = false

    private let timeout: Float = 1.0

    func startTrackingDoneOrStart() -> Bool {
        if !observing { startTracking() }
        return true
    }

    func startTracking() {
        guard !observing else { return }
        observing = true
        lastFrontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        lastFrontmostName = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            if app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
            self.lastFrontmostPid = app.processIdentifier
            self.lastFrontmostName = app.localizedName ?? ""
        }
    }

    // MARK: 读

    func readSelection() throws -> SelectionSnapshot {
        guard AXPermission.granted() else { throw AXReadError.noPermission }
        guard lastFrontmostPid > 0 else { throw AXReadError.noTargetApp }

        let appEl = AXUIElementCreateApplication(lastFrontmostPid)
        AXUIElementSetMessagingTimeout(appEl, timeout)

        guard let focused = attr(appEl, kAXFocusedUIElementAttribute as String) else {
            throw AXReadError.noFocusedElement
        }
        let el = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(el, timeout)

        let target = findEditableAncestor(el) ?? el
        guard let sel = readSelectionRaw(target) else { throw AXReadError.unreadable }
        if sel.length > 0 && sel.text.isEmpty {
            // 有 range 无文本：用全文子串补出来（Web 输入框常见）
            if let full = attrString(target, kAXValueAttribute as String),
               sel.location >= 0,
               let r = Range(NSRange(location: sel.location, length: sel.length), in: full) {
                let sub = String(full[r])
                return SelectionSnapshot(pid: lastFrontmostPid, appName: lastFrontmostName,
                                         location: sel.location, length: sel.length, text: sub, element: target)
            }
            throw AXReadError.unreadable
        }
        guard sel.length > 0 else { throw AXReadError.emptySelection }
        guard !sel.text.isEmpty else { throw AXReadError.emptySelection }
        return SelectionSnapshot(pid: lastFrontmostPid, appName: lastFrontmostName,
                                 location: sel.location, length: sel.length, text: sel.text, element: target)
    }

    private struct RawSelection { var location: Int; var length: Int; var text: String }

    /// 三级回退：AXSelectedTextRange → AXSelectedText（Web 无 range）
    private func readSelectionRaw(_ el: AXUIElement) -> RawSelection? {
        if let r = attr(el, kAXSelectedTextRangeAttribute as String), CFGetTypeID(r) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(r as! AXValue, .cfRange, &range) {
                let txt = attrString(el, kAXSelectedTextAttribute as String) ?? ""
                return RawSelection(location: range.location, length: range.length, text: txt)
            }
        }
        if let t = attrString(el, kAXSelectedTextAttribute as String), !t.isEmpty {
            if let full = attrString(el, kAXValueAttribute as String), let r = full.range(of: t) {
                let loc = full.utf16.distance(from: full.utf16.startIndex, to: r.lowerBound.samePosition(in: full.utf16)!)
                return RawSelection(location: loc, length: t.utf16.count, text: t)
            }
            return RawSelection(location: 0, length: t.utf16.count, text: t)
        }
        return nil
    }

    // MARK: 写

    /// 先用 AX 直写选中区；改不动则退剪贴板粘贴。返回实际用了哪条路。
    func replaceSelection(in snap: SelectionSnapshot, with newText: String) -> ApplyResult {
        guard AXPermission.granted() else {
            return ApplyResult(ok: false, method: .failed, detail: AXReadError.noPermission.message)
        }
        // 1) AX 直写
        let setErr = AXUIElementSetAttributeValue(snap.element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef)
        if setErr == .success, verifyReplaced(snap, newText) {
            return ApplyResult(ok: true, method: .axAttribute, detail: "AXSelectedText 写入成功")
        }
        // 2) 剪贴板兜底
        let detail = "AX 直写失败(\(setErr.rawValue))，改用剪贴板"
        let pb = pasteboardReplace(snap, newText)
        if pb { return ApplyResult(ok: true, method: .pasteboard, detail: detail) }
        return ApplyResult(ok: false, method: .failed, detail: detail + "；剪贴板粘贴也失败")
    }

    private func verifyReplaced(_ snap: SelectionSnapshot, _ newText: String) -> Bool {
        // 写入后选区可能保持或塌缩，两种都接受：读回选区文本或全文包含新文本
        if let sel = readSelectionRaw(snap.element) {
            if sel.length > 0, sel.text == newText { return true }
            if let full = attrString(snap.element, kAXValueAttribute as String), full.contains(head(newText, 40)) { return true }
        }
        if let full = attrString(snap.element, kAXValueAttribute as String), full.contains(head(newText, 40)) { return true }
        // 无 AXValue 的 Web 输入框：读不到就当成功，交给用户目视确认
        if attrString(snap.element, kAXValueAttribute as String) == nil { return true }
        return false
    }

    private func head(_ s: String, _ n: Int) -> String { String(s.prefix(n)) }

    private func pasteboardReplace(_ snap: SelectionSnapshot, _ newText: String) -> Bool {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(newText, forType: .string)

        // 让目标 App 成为前台（面板是 nonactivating，本 App 并未抢走激活）
        if let app = NSRunningApplication(processIdentifier: snap.pid), !app.isActive {
            app.activate(options: [])
            usleep(60_000)
        }
        // 重新选中原范围，再 ⌘V
        if let v = axRangeValue(snap.location, snap.length) {
            _ = AXUIElementSetAttributeValue(snap.element, kAXSelectedTextRangeAttribute as CFString, v)
        }
        usleep(30_000)
        postCmdV(to: snap.pid)
        usleep(120_000)

        // 还原用户剪贴板
        pb.clearContents()
        if let saved { pb.setString(saved, forType: .string) }
        return true
    }

    private func postCmdV(to pid: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    // MARK: 撤销

    /// 把 newText 换回 original：重选同一段再写回
    func undoReplace(snapshot: SelectionSnapshot, newText: String) -> ApplyResult {
        let appEl = AXUIElementCreateApplication(snapshot.pid)
        AXUIElementSetMessagingTimeout(appEl, timeout)
        var el = snapshot.element
        if let focused = attr(appEl, kAXFocusedUIElementAttribute as String) {
            let f = focused as! AXUIElement
            if let ancestor = findEditableAncestor(f) { el = ancestor }
        }
        let loc = snapshot.location
        let len = newText.utf16.count
        if let v = axRangeValue(loc, len) {
            _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, v)
        }
        let err = AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, snapshot.text as CFTypeRef)
        if err == .success {
            return ApplyResult(ok: true, method: .axAttribute, detail: "已还原")
        }
        let snap2 = SelectionSnapshot(pid: snapshot.pid, appName: snapshot.appName,
                                      location: loc, length: len, text: newText, element: el)
        let pb = pasteboardReplace(snap2, snapshot.text)
        return ApplyResult(ok: pb, method: pb ? .pasteboard : .failed, detail: pb ? "已用剪贴板还原" : "还原失败")
    }
}

// MARK: - 低层读属性

func axRangeValue(_ location: Int, _ length: Int) -> AXValue? {
    var r = CFRange(location: location, length: length)
    return AXValueCreate(.cfRange, &r)
}

func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
    var out: CFTypeRef?
    guard AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success else { return nil }
    return out
}

func attrString(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }

func attrChildren(_ el: AXUIElement) -> [AXUIElement] {
    (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
}

let editableRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXStaticText"]

func looksEditable(_ el: AXUIElement) -> Bool {
    let r = attrString(el, kAXRoleAttribute as String) ?? ""
    if editableRoles.contains(r) { return true }
    var settable = DarwinBoolean(false)
    if attr(el, kAXValueAttribute as String) != nil,
       AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success,
       settable.boolValue { return true }
    return false
}

/// Web 内容里焦点常落在内层 span → 向上最多 8 层找可编辑祖先
func findEditableAncestor(_ el: AXUIElement, maxDepth: Int = 8) -> AXUIElement? {
    var cur: AXUIElement? = el
    var depth = 0
    while let c = cur, depth < maxDepth {
        if looksEditable(c) { return c }
        guard let parent = attr(c, kAXParentAttribute as String) else { break }
        cur = (parent as! AXUIElement)
        depth += 1
    }
    return nil
}
