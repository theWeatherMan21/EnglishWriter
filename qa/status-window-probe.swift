// status-window-probe.swift — 菜单栏图标到底在不在屏上（只读，不开窗）
// 用法：swiftc -O -o /tmp/statusprobe status-window-probe.swift -framework AppKit && /tmp/statusprobe <pid>
import AppKit

let args = CommandLine.arguments
guard args.count > 1, let pid = Int32(args[1]) else {
    print("用法：statusprobe <pid>"); exit(2)
}
guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
    print("拿不到窗口列表"); exit(1)
}
var found = 0
for w in list {
    guard let owner = w[kCGWindowOwnerPID as String] as? Int32, owner == pid else { continue }
    let layer = w[kCGWindowLayer as String] as? Int ?? -999
    let name = w[kCGWindowName as String] as? String ?? ""
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let x = b["X"] as? Double ?? 0, y = b["Y"] as? Double ?? 0
    let wd = b["Width"] as? Double ?? 0, ht = b["Height"] as? Double ?? 0
    let onScreen = w[kCGWindowIsOnscreen as String] as? Bool ?? false
    // layer 25 = NSStatusWindowLevel，菜单栏项就是这一层
    print("窗口：layer=\(layer) onscreen=\(onScreen) frame=(\(Int(x)),\(Int(y)),\(Int(wd))x\(Int(ht)))")
    if layer == 25 || (ht > 0 && ht < 40 && y < 40) {
        found += 1
        print("菜单栏窗口：layer=\(layer) onscreen=\(onScreen) frame=(\(Int(x)),\(Int(y)),\(Int(wd))x\(Int(ht))) name=\(name)")
    }
}
if found == 0 {
    print("没有找到菜单栏图标窗口（pid=\(pid)）→ 要么没创建 statusItem，要么被系统藏进溢出区")
    exit(1)
}
print("找到 \(found) 个菜单栏窗口")
