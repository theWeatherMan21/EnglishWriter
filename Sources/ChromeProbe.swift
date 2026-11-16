// ChromeProbe.swift — Chromium 文本面能力探测（只探能力，不改任何东西）
//
// 为什么要它：爹地原话「text 跟 chrome 一样」，Chrome 是主场景。但我们不能假设
// Chromium 的 AXTextArea 跟 AppKit 的 NSTextView 一样给 value / selectedTextRange /
// boundsForRange —— 必须实测：读得到吗、写得进吗、能不能算出每行的矩形。
//
// 做法：起一个**独立 user-data-dir** 的 Chrome，只打开我们自己写的临时 HTML
// （textarea / input / contenteditable 三种面），把 AX 能力一项项打出来，然后只杀我们起的那个实例。
// 绝不碰爹地正在用的 Chrome。
//
// 用法：open -a 英文写作助手 --args --axprobe-chrome <outDir> [--hold 0]
// 产物：<outDir>/chrome-probe.json（+ 屏幕上看一眼即可，不截屏）

import AppKit
import ApplicationServices

enum ChromeProbe {

    struct Area: Codable {
        var role = ""
        var depth = 0
        var valueLen = 0
        var sample = ""
        var valueSettable = false
        var hasSelectedRange = false
        var boundsOK = false
        var boundsRect: [Int] = []
        var writeBackOK = false        // AXValue 直写
        var selWriteOK = false         // 选区 + AXSelectedText 写（我们接受建议走的就是这条路）
        var inWeb = false              // 是否在 AXWebArea 子树里（= 网页内容，不是 Chrome 自己的地址栏）
        var clipWriteOK = false        // 剪贴板 ⌘V 兜底能不能写进去
    }

    struct Report: Codable {
        var ok = false
        var verdict = ""
        var timestamp = ""
        var chrome = ""
        var pid: Int32 = 0
        var webAreaFound = false
        var blockCount = 0
        var areas: [Area] = []
        var notes: [String] = []
    }

    static let html = """
    <!doctype html><html><head><meta charset="utf-8"><title>EW Chrome Probe</title></head>
    <body style="font:16px -apple-system;margin:24px">
      <h3>EnglishWriter Chromium 文本面探测</h3>
      <p>1) textarea</p>
      <textarea id="ta" rows="3" cols="90">There is many reasons why we should sent it immediatly.</textarea>
      <p>2) input</p>
      <input id="in" size="90" value="He go to school every days.">
      <p>3) contenteditable</p>
      <div id="ce" contenteditable="true" style="border:1px solid #ccc;padding:8px">They was very happy about the news last week.</div>
    </body></html>
    """

    @MainActor
    static func run(_ argv: [String]) async {
        var st = Report()
        st.timestamp = ISO8601DateFormatter().string(from: Date())
        var outDir = NSHomeDirectory() + "/dev/EnglishWriter/out"
        if let i = argv.firstIndex(of: "--axprobe-chrome"), i + 1 < argv.count { outDir = argv[i + 1] }
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let work = NSTemporaryDirectory() + "ew-chromeprobe-\(getpid())"
        let profile = work + "/profile"
        let page = work + "/probe.html"
        try? FileManager.default.createDirectory(atPath: profile, withIntermediateDirectories: true)
        try? html.write(toFile: page, atomically: true, encoding: .utf8)

        func finish(_ code: Int32) -> Never {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(st) {
                try? d.write(to: URL(fileURLWithPath: outDir + "/chrome-probe.json"))
            }
            print("[chrome-probe] \(st.ok ? "OK" : "FAIL") verdict=\(st.verdict) areas=\(st.areas.count) blocks=\(st.blockCount)")
            try? FileManager.default.removeItem(atPath: work)
            exit(code)
        }

        guard AXPermission.granted() else { st.verdict = "无辅助功能权限"; finish(3) }
        guard FileManager.default.isExecutableFile(atPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome") else {
            st.verdict = "本机没装 Google Chrome"; finish(4)
        }

        // 只起我们自己的实例：独立 user-data-dir，绝不碰爹地正在用的 Chrome
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        p.arguments = ["--user-data-dir=\(profile)", "--no-first-run", "--no-default-browser-check",
                       "--disable-features=Translate", "--window-size=1000,700",
                       // 探针专用：让 Chromium 一上来就把 web 内容挂进 AX 树（真实使用时由 AT 客户端触发，冷启时快时慢）
                       "--force-renderer-accessibility",
                       "file://" + page]
        do { try p.run() } catch {
            st.verdict = "Chrome 起不来：\(error)"; finish(5)
        }
        let pid = p.processIdentifier
        st.pid = pid
        st.chrome = "Google Chrome（独立 profile）"

        // 等窗口
        var sawWindow = false
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if windowCount(pid) > 0 { sawWindow = true; break }
        }
        guard sawWindow else {
            st.verdict = "Chrome 起了但没有窗口"
            kill(pid, SIGKILL)
            finish(6)
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)     // 等页面渲染完

        // Chromium 默认懒开无障碍树：不置这两个属性，他给的 AX 树里只有地址栏，永远看不到 AXWebArea。
        // 这是 Chromium 侧的既有行为（Electron 用 AXManualAccessibility），不是我们的权限问题。
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 2.0)
        let eui = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        let mani = AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        st.notes.append("AXEnhancedUserInterface=\(eui.rawValue) AXManualAccessibility=\(mani.rawValue)")
        // Chromium 挂 web 内容进 AX 树是异步的、且时快时慢：轮询最多 12s，别一次取样就下结论
        var webAreaMaybe: AXUIElement? = nil
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            _ = AXUIElementSetAttributeValue(appEl, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            if let w = windows(pid).first,
               let found = descendants(w, depth: 10).first(where: { (attrString($0, kAXRoleAttribute as String) ?? "") == "AXWebArea" }) {
                webAreaMaybe = found
                break
            }
        }
        if webAreaMaybe == nil { st.notes.append("轮询 12s 仍未出现 AXWebArea") }

        let win = windows(pid).first
        st.notes.append("窗口标题=「\(win.flatMap { attrString($0, kAXTitleAttribute as String) } ?? "")」")

        // 找 WebArea 与文字面
        var webArea: AXUIElement? = webAreaMaybe
        var areas: [AXUIElement] = []
        if let w = win {
            for el in descendants(w, depth: 10) {
                let role = attrString(el, kAXRoleAttribute as String) ?? ""
                if role == "AXWebArea", webArea == nil { webArea = el }
                if role == "AXTextArea" || role == "AXTextField" {
                    areas.append(el)
                }
            }
        }
        st.webAreaFound = webArea != nil
        st.blockCount = webArea.map { WebText.blocks(of: $0).count } ?? 0

        let webDesc = webArea.map { descendants($0, depth: 12) } ?? []
        for el in areas.prefix(10) {
            var a = Area()
            a.inWeb = webDesc.contains { CFEqual($0, el) }
            a.role = attrString(el, kAXRoleAttribute as String) ?? "?"
            let v = attrString(el, kAXValueAttribute as String) ?? ""
            a.valueLen = (v as NSString).length
            a.sample = String(v.prefix(48))
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success {
                a.valueSettable = settable.boolValue
            }
            a.hasSelectedRange = (attr(el, kAXSelectedTextRangeAttribute as String) != nil)

            // boundsForRange：矩形是行内下划线的命门
            var out: CFTypeRef?
            let err = AXUIElementCopyParameterizedAttributeValue(
                el, "AXBoundsForRange" as CFString,
                axRangeValue(0, min(5, max(1, a.valueLen))) ?? axRangeValue(0, 1)!,
                &out)
            if err == .success, let o = out, CFGetTypeID(o) == AXValueGetTypeID() {
                var r = CGRect.zero
                if AXValueGetValue(o as! AXValue, .cgRect, &r), r.width > 0, r.height > 0 {
                    a.boundsOK = true
                    a.boundsRect = [Int(r.minX.rounded()), Int(r.minY.rounded()),
                                    Int(r.width.rounded()), Int(r.height.rounded())]
                }
            }
            // 能不能写回（只写我们自己的探测页）：AXValue 直写
            if a.valueSettable, a.valueLen > 0 {
                let probe = "EW-WRITE-OK"
                if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, probe as CFTypeRef) == .success,
                   (attrString(el, kAXValueAttribute as String) ?? "").contains("EW-WRITE-OK") {
                    a.writeBackOK = true
                }
            }
            // 能不能写回：选中一段 + 写 AXSelectedText（accept() 真实走的路）
            if a.valueLen >= 4, let r = axRangeValue(0, 4) {
                _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, r)
                if AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute as CFString, "TSTX" as CFTypeRef) == .success,
                   (attrString(el, kAXValueAttribute as String) ?? "").hasPrefix("TSTX") {
                    a.selWriteOK = true
                }
            }
            // 兜底：选区 + 剪贴板 ⌘V（Chromium 里 AX 写不进时的唯一出路）
            if a.inWeb, a.valueLen >= 6, let r = axRangeValue(0, 6) {
                NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateAllWindows])
                usleep(900_000)
                _ = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, r)
                _ = AXUIElementPerformAction(el, kAXPressAction as CFString)
                if pasteViaClipboard("EWPASTE", to: pid) {
                    usleep(500_000)
                    if (attrString(el, kAXValueAttribute as String) ?? "").hasPrefix("EWPASTE") {
                        a.clipWriteOK = true
                    }
                }
            }
            st.areas.append(a)
        }

        // 结论口径：能不能直接照 AppKit 那套跑；不能就写清缺哪一层
        let web = st.areas.filter { $0.inWeb }
        let readable = web.contains { $0.valueLen > 0 }
        let writable = web.contains { $0.writeBackOK }
        let selWritable = web.contains { $0.selWriteOK }
        let bounded = web.contains { $0.boundsOK }
        let coNotBounded = web.contains { $0.valueLen > 0 && !$0.boundsOK }
        let clipWritable = web.contains { $0.clipWriteOK }
        if !st.webAreaFound {
            st.verdict = "没找到 AXWebArea（Chromium 可能未开辅助功能支持，或页面未渲染完）"
        } else if readable && writable && bounded {
            st.verdict = "原生可用：AXValue 读写 + AXBoundsForRange 出矩形，AppKit 那套可直接跑"
        } else if readable && !writable && !selWritable {
            st.verdict = clipWritable
                ? "只读(AX)：网页字段 AXValue/AXSelectedText 写不进，但剪贴板 ⌘V 兜底**已验证可写**"
                : "只读：网页字段 AXValue/AXSelectedText/剪贴板 ⌘V 全部写不进 → 只能改走 CDP"
            if coNotBounded { st.verdict += "；且部分字段（contenteditable）AXBoundsForRange 拿不到矩形" }
        } else if readable && !bounded {
            st.verdict = "能读能写、但 AXBoundsForRange 给不全 → 下划线需按 WebText 文本块兜底"
        } else if readable && writable {
        } else if readable {
            st.verdict = "只能读：写回要走剪贴板/合成键击兜底（当前未实现）"
        } else {
            st.verdict = "读不到正文：Chromium 文本面不可用，需要换路径（CDP / 输入法钩子）"
        }
        st.ok = readable && st.blockCount > 0
        if !st.notes.isEmpty { st.verdict += "｜" + st.notes.joined(separator: "；") }

        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 600_000_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        finish(st.ok ? 0 : 1)
    }

    // MARK: 小工具（与 AXCheck 同口径，不复用其 private）

    private static func windows(_ pid: pid_t) -> [AXUIElement] {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.5)
        return (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func windowCount(_ pid: pid_t) -> Int { windows(pid).count }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v
    }

    private static func attrString(_ el: AXUIElement, _ name: String) -> String? {
        attr(el, name) as? String
    }

    private static func descendants(_ el: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var out: [AXUIElement] = []
        for c in (attr(el, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] {
            out.append(c)
            out.append(contentsOf: descendants(c, depth: depth - 1))
        }
        return out
    }

    /// 剪贴板 ⌘V（探针用；写进去就还原爹地的剪贴板）
    private static func pasteViaClipboard(_ text: String, to pid: pid_t) -> Bool {
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        // 先发给指定 pid，再补一发全局 HID（有些 WebKit/Chromium 只认全局事件）
        down.postToPid(pid)
        up.postToPid(pid)
        usleep(120_000)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(700_000)
        if let s = saved { pb.clearContents(); pb.setString(s, forType: .string) }
        return true
    }

    private static func axRangeValue(_ loc: Int, _ len: Int) -> CFTypeRef? {
        var r = CFRange(location: loc, length: len)
        return AXValueCreate(.cfRange, &r)
    }
}
