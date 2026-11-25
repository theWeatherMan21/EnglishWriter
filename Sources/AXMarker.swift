import Foundation
import ApplicationServices
import AppKit

/// AXTextMarker 通道（知澜 11-25 指出的正确读法）：
/// WKWebView 正文的 `kAXValue` 是空的，正文是成百上千个 AXStaticText 叶子。
/// 逐节点遍历 = 每个节点 2–3 次跨进程调用，规格上就不该做（今天所有 0 块 / 0.6s 超时 /
/// frame 读不到的根因）。
/// WebKit 给了一条专用通道：
///   AXTextMarkerRangeForUIElement(webArea)   （属性）
///   AXStringForTextMarkerRange(range)        （一次拿整篇纯文本）
///   AXBoundsForTextMarkerRange(range)        （一次拿一段文字的屏幕矩形）
/// 这些符号不在公开 SDK 里，用 dlsym 取；取不到就明确报“本机没有”，不许假装成功。
enum AXMarker {
    private static let handle = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_NOW)

    typealias StringFn = @convention(c) (CFTypeRef) -> Unmanaged<CFString>?
    typealias BoundsFn = @convention(c) (AXUIElement, CFTypeRef) -> CFTypeRef?

    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        // Chromium 也是这么取（dlsym(RTLD_DEFAULT, …)）：这些符号随他的进程空间已经在
        // 全局符号表里，用具体 framework handle 反而取不到（系统库在 dyld shared cache）。
        if let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) {
            return unsafeBitCast(p, to: T.self)
        }
        guard let h = handle, let p = dlsym(h, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    static var stringForRange: StringFn? { sym("AXStringForTextMarkerRange", as: StringFn.self) }
    static var attributedForRange: StringFn? { sym("AXAttributedStringForTextMarkerRange", as: StringFn.self) }

    /// WebArea → 整篇纯文本（一次调用）
    static func fullText(of webArea: AXUIElement, timeout: Float = 2.0) -> (text: String?, ms: Int, attr: String, err: String) {
        AXUIElementSetMessagingTimeout(webArea, timeout)
        var raw: CFTypeRef?
        var used = "-"
        for name in ["AXTextMarkerRangeForUIElement", "AXTextMarkerRange"] {
            raw = nil
            let e = AXUIElementCopyAttributeValue(webArea, name as CFString, &raw)
            if e == .success, let r = raw, CFGetTypeID(r) != 0 {
                used = name
                break
            }
        }
        guard used != "-", let range = raw else {
            return (nil, 0, used, "取不到 marker range（AXTextMarkerRangeForUIElement 不可用）")
        }
        // 符号不存在（本机实测：AXStringForTextMarkerRange 在 macOS 27 已不是导出符号），
        // 但 WebKit 把它作为「参数化属性」暴露：AXUIElementCopyParameterizedAttributeValue。
        let t0 = Date()
        var out: CFTypeRef?
        let e = AXUIElementCopyParameterizedAttributeValue(webArea, "AXStringForTextMarkerRange" as CFString, range, &out)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        if e == .success, let str = out as? String {
            return (str, ms, used + "+参数化属性", "-")
        }
        var out2: CFTypeRef?
        let e2 = AXUIElementCopyParameterizedAttributeValue(webArea, "AXAttributedStringForTextMarkerRange" as CFString, range, &out2)
        if e2 == .success, let a = out2 as? NSAttributedString {
            return (a.string, ms, used + "+attributed", "-")
        }
        return (nil, ms, used, "参数化属性取字符串失败 err=\(e.rawValue)/\(e2.rawValue)")
    }

    /// 探针：--axmarker-probe [邮箱/窗口名无关，只找 Mail 写窗]
    static func probe(_ args: [String]) -> Int32 {
        print("--- AXTextMarker 通道探针（只读，不建窗/不激活/不敲键）---")
        // 口径与 --probe-mail 一致：锁屏时 AX 树只剩骨架，不能报「没有窗口」误导人
        if ScreenLock.isLocked {
            print("SKIP screen-locked  --axmarker-probe：屏幕已锁，AX 树只剩骨架，本次不判定（不是失败）")
            return 0
        }
        print("符号：AXStringForTextMarkerRange=\(stringForRange != nil ? "有" : "无")"
              + "（本机已实测无此导出符号，改走参数化属性）")
        // Mail 没开窗口时，退到任何有 WebArea 的 App（只读，用来看这套 API 在不在本机）
        var mail = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.mail").first
        if mail == nil || MailProbe.composeBody(pid: mail!.processIdentifier) == nil {
            if let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first,
               AXInline.bestWebBody(pid: chrome.processIdentifier) != nil {
                mail = chrome
                print("（Mail 没有窗口 → 先在 Chrome 的 WebArea 上验 API 是否可用，只读）")
            }
        }
        guard let mail else {
            print("RESULT: SKIP —— Mail 没在运行")
            return 0
        }
        let pid = mail.processIdentifier
        var target: AXUIElement?
        var where_ = "-"
        if appName(pid) == "Mail", let cb = MailProbe.composeBody(pid: pid) {
            target = cb.el; where_ = "compose win=\(cb.title) len=\(cb.len) 块=\(cb.blocks)"
        } else if let bw = AXInline.bestWebBody(pid: pid) {
            target = bw.el; where_ = "bestWebBody len=\(bw.len)"
        }
        guard let body = target else {
            print("RESULT: SKIP —— Mail 里没有可读的 WebArea（没有打开的窗口？）")
            return 0
        }
        print("目标：\(where_)")
        var names: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(body, &names) == .success,
           let list = names as? [String] {
            let mk = list.filter { $0.localizedCaseInsensitiveContains("Marker") }
            print("参数化属性（含 Marker，\(mk.count)/\(list.count)）：\(mk.prefix(12).joined(separator: ", "))")
        }
        let r = fullText(of: body)
        print("attr=\(r.attr) ms=\(r.ms) len=\(r.text?.count ?? -1) err=\(r.err)")
        if let s = r.text, !s.isEmpty {
            let head = s.replacingOccurrences(of: "\n", with: "⏎").prefix(80)
            print("预览：\(head)")
            print("RESULT: OK —— AXTextMarker 通道可用（一次调用拿到 \(s.count) 字）")
            CheckLog.append(.init(kind: "axmarker-read", pid: pid, app: "Mail", role: "AXWebArea",
                                  textLen: s.count, sentenceLen: 0, itemCount: 0, rectCount: 0,
                                  elapsed: "\(r.ms)ms", err: "probe \(where_)", at: Date()))
            return 1
        }
        print("RESULT: FAIL —— 通道存在但没拿到文本")
        return 2
    }
}
