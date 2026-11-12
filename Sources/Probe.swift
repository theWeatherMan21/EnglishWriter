// Probe.swift — 前置探针（知澜 D1/D2）：验 Mail 的 AX 可读/可写 + 非激活面板是否保住前台
// 结果写固定路径 JSON，供验收逐字复核。

import AppKit
import ApplicationServices

struct ProbeReport: Codable {
    var timestamp: String
    var permission: Bool
    var frontmostBeforePanel: String
    var targetApp: String
    var targetPid: Int32
    var focusedRole: String
    var axValueLength: Int
    var selectedTextReadable: Bool
    var selectedTextLength: Int
    var selectedTextSettable: Bool
    var panelOpened: Bool
    var targetStillFrontmostAfterPanel: Bool
    var selectionStillReadableAfterPanel: Bool
    var clipboardTestSentence: String
    var notes: [String]
}

enum Probe {
    static var outputPath: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/EnglishWriter"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/probe-result.json"
    }

    @MainActor
    static func run(model: AppModel) -> ProbeReport {
        var notes: [String] = []
        let permission = AXPermission.granted()
        let frontmostBefore = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        let target = AXTarget.shared
        target.startTrackingDoneOrStart()

        var report = ProbeReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            permission: permission,
            frontmostBeforePanel: frontmostBefore,
            targetApp: target.lastFrontmostName,
            targetPid: target.lastFrontmostPid,
            focusedRole: "-",
            axValueLength: -1,
            selectedTextReadable: false,
            selectedTextLength: 0,
            selectedTextSettable: false,
            panelOpened: false,
            targetStillFrontmostAfterPanel: false,
            selectionStillReadableAfterPanel: false,
            clipboardTestSentence: clipboardTest,
            notes: notes
        )

        guard permission else {
            notes.append("未授权：系统设置 → 隐私与安全性 → 辅助功能 → 勾「英文写作助手」，再跑一次探针")
            write(report)
            return report
        }
        guard target.lastFrontmostPid > 0 else {
            notes.append("没有目标 App：先在 Mail 输入框里选中一段话，再点「跑探针」")
            write(report)
            return report
        }

        // P1：读层
        let appEl = AXUIElementCreateApplication(target.lastFrontmostPid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        if let focusedRef = attr(appEl, kAXFocusedUIElementAttribute as String) {
            let el = focusedRef as! AXUIElement
            AXUIElementSetMessagingTimeout(el, 1.0)
            let editable = findEditableAncestor(el) ?? el
            report.focusedRole = attrString(editable, kAXRoleAttribute as String) ?? "?"
            report.axValueLength = (attrString(editable, kAXValueAttribute as String) ?? "").utf16.count
            if let sel = attrString(editable, kAXSelectedTextAttribute as String) {
                report.selectedTextReadable = true
                report.selectedTextLength = sel.utf16.count
            }
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(editable, kAXSelectedTextAttribute as CFString, &settable) == .success {
                report.selectedTextSettable = settable.boolValue
            }
            notes.append("P1 读层：role=\(report.focusedRole) AXValue=\(report.axValueLength)字 选区可读=\(report.selectedTextReadable) 可写=\(report.selectedTextSettable)")
        } else {
            notes.append("P1 读层：目标 App 没有焦点元素（先把光标放进 Mail 正文再跑）")
        }

        // P2：非激活面板
        model.showPanel(phase: .info("探针：这块面板打开后，Mail 应该仍然是前台 App"))
        report.panelOpened = true
        usleep(400_000)
        let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        report.targetStillFrontmostAfterPanel = (after == target.lastFrontmostName)
        notes.append("P2 面板：打开前前台=\(frontmostBefore)，打开后前台=\(after)，目标=\(target.lastFrontmostName)")
        if let snap = try? target.readSelection() {
            report.selectionStillReadableAfterPanel = !snap.text.isEmpty
            notes.append("P2 选区：面板打开后仍读到 \(snap.text.count) 字")
        } else {
            notes.append("P2 选区：面板打开后读不到选区")
        }
        model.closePanel()

        // P3：剪贴板路径（不需要 AX，给爹地在 Mail 里手按一次 ⌘V）
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(clipboardTest, forType: .string)
        notes.append("P3 已把测试句放进剪贴板：去 Mail 正文按一次 ⌘V，看输入法候选框有没有闪断（录屏）")

        write(report)
        return report
    }

    static let clipboardTest = "Please kindly confirm the BL draft before the ETD, our FCL cargo is ready."

    static func write(_ r: ProbeReport) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(r) {
            try? d.write(to: URL(fileURLWithPath: outputPath))
        }
    }

    static func summary(_ r: ProbeReport) -> String {
        var out = ["探针结果已写到：\(outputPath)", ""]
        out.append("辅助功能权限：\(r.permission ? "已授权" : "未授权")")
        out.append("目标 App：\(r.targetApp) (pid \(r.targetPid))")
        out.append("P1 role=\(r.focusedRole) 文本=\(r.axValueLength)字 选区可读=\(r.selectedTextReadable) 可写=\(r.selectedTextSettable)")
        out.append("P2 面板打开后目标仍是前台=\(r.targetStillFrontmostAfterPanel) 选区仍可读=\(r.selectionStillReadableAfterPanel)")
        out.append("")
        out.append(contentsOf: r.notes)
        return out.joined(separator: "\n")
    }
}
