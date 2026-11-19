// KeyWinProbe.swift — 验证「key window 里第一个可编辑元素」这条确定性回退路径
//
// 为什么需要：--axcheck 走的是「显式给元素」，测不到「没有焦点元素」时的回退。
// 这条探针直接对真实 App 的 key window 取第一个可编辑元素，只读、不激活、不敲键、不截屏。

import AppKit

enum KeyWinProbe {
    static func run(_ argv: [String]) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        guard let i = argv.firstIndex(of: "--keywin"), i + 1 < argv.count,
              let pid = pid_t(argv[i + 1]) else {
            print("用法：--keywin <pid>")
            return 1
        }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
        print("--- key window 可编辑元素探针（只读）--- App=\(name) pid=\(pid)")
        print("AXIsProcessTrusted = \(AXIsProcessTrusted())")
        let appEl = AXUIElementCreateApplication(pid)
        let wins = (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
        print("AXWindows = \(wins.count)")
        for w in wins {
            let r = attrString(w, kAXRoleAttribute as String) ?? "?"
            let t = attrString(w, kAXTitleAttribute as String) ?? ""
            let kids = (attr(w, kAXChildrenAttribute as String) as? [AXUIElement])?.count ?? 0
            print("  win role=\(r) title=\(t) children=\(kids)")
        }
        let foc = attr(appEl, kAXFocusedWindowAttribute as String) != nil
        let main = attr(appEl, kAXMainWindowAttribute as String) != nil
        print("focusedWindow=\(foc) mainWindow=\(main)")
        if let w = wins.first {
            var q: [(AXUIElement, Int)] = [(w, 0)]
            var n = 0
            while !q.isEmpty, n < 40 {
                let (cur, d) = q.removeFirst(); n += 1
                let r = attrString(cur, kAXRoleAttribute as String) ?? "?"
                let sub = attrString(cur, kAXSubroleAttribute as String) ?? ""
                print(String(repeating: "  ", count: d) + "\(r) \(sub)")
                for k in (attr(cur, kAXChildrenAttribute as String) as? [AXUIElement]) ?? [] where d < 4 {
                    q.append((k, d + 1))
                }
            }
        }
        guard let el = AXInline.keyWindowEditable(pid: pid) else {
            print("RESULT: none（key window 里没有可编辑元素，或没有 key window）")
            return 3
        }
        let role = (attrString(el, kAXRoleAttribute as String) ?? "?")
        let editable = AXInline.isEditable(el)
        print("RESULT: found role=\(role) editable=\(editable)")
        return editable ? 0 : 4
    }
}
