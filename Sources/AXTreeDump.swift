// AXTreeDump.swift — --axdump-mail：只读 dump Mail 写信窗的 AX 树
//
// 为什么要有这个：11-23 真机日志 `web-write host=无 map=nil`，
// 说明从块元素往父链 12 层都没找到可编辑容器。到底是「有可编辑节点但我们没认出来」
// 还是「Mail 整篇对 AX 不开放写」，只能靠把树打出来看。
// 只读：不建窗口、不点、不写、不弹窗；每节点打印 role/subrole/可编辑标记/文本长度/层级。

import Foundation
import AppKit
import ApplicationServices


/// 锁屏时 AX 树只剩骨架（windows 都是 AXApplication 占位），
/// 一切「找不到容器」的结论都不成立。先判锁屏，别把环境问题当产品缺陷。
func screenLocked() -> Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) ?? false
}

enum AXTreeDump {
    static func run() -> Int32 {
        if screenLocked() {
            print("RESULT: SKIP（屏幕已锁 —— AX 树只剩骨架，dump 无意义）")
            return 0
        }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.mail" }) else {
            print("RESULT: SKIP（Mail 没在运行）")
            return 0
        }
        let pid = app.processIdentifier
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.4)

        // 窗口查找必须和 --probe-mail 同口径（MailProbe.windows 会滤掉 AXApplication 占位、
        // 跳过菜单栏、带预算）。11-23 之前这里自己读 kAXWindowsAttribute，两边一个能看见一个看不见。
        let wins = MailProbe.windows(pid)
        guard !wins.isEmpty else {
            print("RESULT: SKIP（Mail 没有窗口 —— 打开一封写信窗口再跑）")
            return 0
        }

        print("== Mail AX 树（只读）== 窗口 \(wins.count) 个")
        var nodes = 0
        var editable = 0
        let until = Date().addingTimeInterval(6.0)

        func dump(_ el: AXUIElement, depth: Int, maxDepth: Int) {
            guard depth <= maxDepth, nodes < 4000, Date() < until else { return }
            nodes += 1
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? "?"
            var subRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &subRef)
            let sub = (subRef as? String) ?? ""

            var editRef: CFTypeRef?
            let editOK = AXUIElementCopyAttributeValue(el, "AXEditable" as CFString, &editRef) == .success
            let isEditable = (editRef as? Bool) ?? false

            var valRef: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef)
            let valLen = (valRef as? String)?.count ?? 0

            var selRangeOK = false
            var selRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, "AXSelectedTextRange" as CFString, &selRef) == .success, selRef != nil {
                selRangeOK = true
            }
            if isEditable || selRangeOK { editable += 1 }

            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var pt = CGPoint.zero
            var sz = CGSize.zero
            if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
               let pv = posRef, CFGetTypeID(pv) == AXValueGetTypeID() {
                AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
            }
            if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success,
               let sv = sizeRef, CFGetTypeID(sv) == AXValueGetTypeID() {
                AXValueGetValue(sv as! AXValue, .cgSize, &sz)
            }
            let fr = CGRect(origin: pt, size: sz)
            let pad = String(repeating: " ", count: min(depth, 24))
            var settable = ""
            if let one = axRangeValue(0, 1) {
                let e = AXUIElementSetAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, one)
                if e == .success {
                    if let back = axSelection(el), back.length == 1 { settable = " selSet=ok" } else { settable = " selSet=谎" }
                }
            }
            print("\(pad)\(role)\(sub.isEmpty ? "" : "(\(sub))") edit=\(isEditable ? "1" : "0") selRange=\(selRangeOK ? "1" : "0") valLen=\(valLen)\(settable) frame=\(Int(fr.width))x\(Int(fr.height))@\(Int(fr.origin.x)),\(Int(fr.origin.y))")

            var kidsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kidsRef) == .success,
                  let kids = kidsRef as? [AXUIElement] else { return }
            for k in kids.prefix(200) { dump(k, depth: depth + 1, maxDepth: maxDepth) }
        }

        for w in wins { dump(w, depth: 0, maxDepth: 16) }
        print("---- 节点 \(nodes) 个 · 可编辑/可选区 \(editable) 个")
        if editable == 0 {
            print("RESULT: 无可编辑容器 —— Mail 正文对 AX 不开放写入，只能走键盘路径")
            return 2
        }
        print("RESULT: 找到可编辑节点 —— 按 valLen 最大、selRange=1 的那个当写入口")
        return 0
    }
}
