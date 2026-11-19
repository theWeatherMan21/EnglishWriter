// AXElementsProbe.swift — 静默探测各 App 的文本框元素名，落 qa/evidence/ax-elements.json
//
// 为什么要有它：适配表里 elementName 必须现场探出来再填，不许猜。
// 这个探针只读 AX 树（不激活、不建窗、不写宿主），把每个 App 里候选文本元素的
// role / identifier / title / description 记下来，供 Integrations.swift 填写。
//
// 用法：./build/英文写作助手 --ax-elements
// 输出：qa/evidence/ax-elements.json
// 未运行的 App 如实记 "not-running"，不假装探到。

import AppKit
import ApplicationServices

enum AXElementsProbe {

    struct Target {
        var name: String
        var bundleIds: [String]
    }

    static let targets: [Target] = [
        Target(name: "Mail", bundleIds: ["com.apple.mail", "com.apple.Mail"]),
        Target(name: "TextEdit", bundleIds: ["com.apple.TextEdit"]),
        Target(name: "Notes", bundleIds: ["com.apple.Notes"]),
        Target(name: "Word", bundleIds: ["com.microsoft.Word"]),
        Target(name: "Outlook", bundleIds: ["com.microsoft.Outlook"]),
        Target(name: "Safari", bundleIds: ["com.apple.Safari"]),
        // 11-19 新增：这几个是卡上点名要覆盖的宿主，必须在真机探到再开
        // 探不到就老实记 not-running，绝不拿 role 兜底假装支持
        Target(name: "Telegram", bundleIds: ["org.telegram.desktop", "com.tdesktop.Telegram"]),
        Target(name: "WPS", bundleIds: ["com.kingsoft.wpsoffice.mac", "com.kingsoft.wpsoffice.mac.wps"]),
        Target(name: "Pages", bundleIds: ["com.apple.iWork.Pages"]),
        Target(name: "Slack", bundleIds: ["com.tinyspeck.slackmacgap"]),
        Target(name: "Chrome", bundleIds: ["com.google.Chrome"]),
    ]

    @MainActor
    static func run(_ argv: [String]) -> Int32 {
        var out: [String: Any] = [:]
        // AXStaticText 不算候选：它永远不是「可输入的正文元素」，
        // 而聊天类 App（Telegram）的聊天记录全是一屏 AXStaticText，
        // 会把 40 条预算吃光，导致真的输入框根本探不到（11-19 实测）。
        let candidates: Set<String> = ["AXTextArea", "AXTextField", "AXWebArea", "AXGroup"]

        for t in targets {
            guard let app = t.bundleIds.lazy.compactMap({ NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }).first else {
                out[t.name] = ["status": "not-running"]
                continue
            }
            let pid = app.processIdentifier
            let appEl = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appEl, 1.0)

            var els: [[String: Any]] = []
            var seen = Set<String>()
            for el in descendants(appEl, depth: 14) {
                let role = str(el, kAXRoleAttribute) ?? ""
                guard candidates.contains(role) else { continue }
                let id = str(el, kAXIdentifierAttribute) ?? ""
                let title = str(el, kAXTitleAttribute) ?? ""
                let desc = str(el, kAXDescriptionAttribute) ?? ""
                let key = "\(role)|\(id)|\(title)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                // 带上「这个元素里到底有多少字 + 位置尺寸」：
                // 只有字数 > 0 且尺寸正常的元素才可能是正文，光看 role 会猜错
                var chars = 0
                if let v = value(el) as? String { chars = (v as NSString).length }
                if chars == 0, let n = value(el) as? NSNumber { chars = n.intValue }
                let fr = frame(el)
                els.append(["role": role, "identifier": id, "title": title, "description": desc,
                            "chars": chars, "frame": [Int(fr.origin.x), Int(fr.origin.y),
                                                      Int(fr.size.width), Int(fr.size.height)]])
                if els.count >= 60 { break }
            }
            out[t.name] = ["status": "probed", "pid": Int(pid), "elements": els,
                           "count": els.count]
        }

        let payload: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "note": "只读探测：不激活、不建窗、不写宿主；空 identifier 表示该元素没有暴露标识",
            "apps": out,
        ]
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("qa/evidence/ax-elements.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
            print("证据：\(url.path)")
        }
        for (k, v) in out.sorted(by: { $0.key < $1.key }) {
            let dict = v as? [String: Any]
            let status = dict?["status"] as? String ?? "?"
            let count = dict?["count"] as? Int ?? 0
            print("  \(k): \(status)\(status == "probed" ? "（\(count) 个候选元素）" : "")")
        }
        return 0
    }

    private static func value(_ el: AXUIElement) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        return v
    }

    /// AX 的 position/size 是 AXValue，要解出 CGPoint/CGSize；解不出就返回零矩形
    private static func frame(_ el: AXUIElement) -> CGRect {
        var pv: CFTypeRef?, sv: CFTypeRef?
        var p = CGPoint.zero, s = CGSize.zero
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
           let v = pv, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgPoint, &p)
        }
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success,
           let v = sv, CFGetTypeID(v) == AXValueGetTypeID() {
            AXValueGetValue(v as! AXValue, .cgSize, &s)
        }
        return CGRect(origin: p, size: s)
    }

    private static func descendants(_ el: AXUIElement, depth: Int) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &raw) == .success,
              let kids = raw as? [AXUIElement] else { return [] }
        var out: [AXUIElement] = []
        for k in kids {
            out.append(k)
            out.append(contentsOf: descendants(k, depth: depth - 1))
        }
        return out
    }

    private static func str(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }
}
