// M3MonitorProbe.swift — M3 悬停监听的**真实事件**取证（--m3-monitors）
//
// 为什么单独一个文件：--m3-drive 证明的是「命中判定 → 卡片 → 接受 → 撤销」这段逻辑，
// 它用固定几何，跑不证明「全局监听能收到真鼠标」。这一条必须真发一个系统级鼠标事件来验：
//   · 本进程挂 NSEvent.addGlobalMonitorForEvents(.mouseMoved) + 产品自己的 HoverCoordinator.start()
//   · 合成一次 8pt 鼠标移动（CGEvent → cghidEventTap），看回调是否真的被调用
//   · 光标立刻 warp 回原位；不建窗口、不截屏、不写回任何 App（静默红线）
//
// 结果同时打到 stdout 和 EW_M3_LOG（默认 $TMPDIR/ew-m3-monitors.log），因为用 `open -a` 起时没有 stdout。

import AppKit

enum M3MonitorProbe {

    /// - Returns: 0 = 产品两个监听都挂上且真收到事件；1 = 没做到（原因写进日志）
    static func run() -> Int32 {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        var lines: [String] = []
        let logPath = ProcessInfo.processInfo.environment["EW_M3_LOG"]
            ?? (NSTemporaryDirectory() + "ew-m3-monitors.log")
        func emit(_ s: String) {
            print(s)
            lines.append(s)
        }

        var received: (x: CGFloat, y: CGFloat)?
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { e in
            let q = ScreenGeom.toQuartz(NSRect(origin: e.locationInWindow, size: .zero)).origin
            received = (q.x, q.y)
        }

        MainActor.assumeIsolated { HoverCoordinator.shared.start() }
        let productHover = MainActor.assumeIsolated { HoverCoordinator.shared.hoverMonitorActive }
        let productClick = MainActor.assumeIsolated { HoverCoordinator.shared.clickMonitorActive }
        let trusted = AXPermission.granted()
        let canPost = CGPreflightPostEventAccess()
        emit("monitor product hover=\(productHover) click=\(productClick) axTrusted=\(trusted) canPostEvent=\(canPost)")

        let hereAppKit = NSEvent.mouseLocation
        let hereQ = ScreenGeom.toQuartz(NSRect(origin: hereAppKit, size: .zero)).origin
        let target = CGPoint(x: hereQ.x + 8, y: hereQ.y)
        func postMove(_ dx: CGFloat) {
            let p = CGPoint(x: target.x + dx, y: target.y)
            guard let ev = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                                   mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
            ev.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            ev.post(tap: .cghidEventTap)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { postMove(0) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { postMove(8) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) {
            CGWarpMouseCursorPosition(hereQ)                       // 还原光标
            MainActor.assumeIsolated { HoverCoordinator.shared.stop() }
            if let m = received {
                emit("EVENT mouseMoved received at (\(Int(m.x)),\(Int(m.y)))（合成点 \(Int(target.x)),\(Int(target.y))；光标可能被人手同时移动）")
            } else {
                emit("EVENT mouseMoved 未收到（本进程无输入监控授权，或系统丢弃合成事件）")
            }
            AppLog.info("m3", "monitors probe productHover=\(productHover) productClick=\(productClick) rawEvent=\(received != nil) axTrusted=\(trusted) canPost=\(canPost)")
            let ok = productHover && productClick && received != nil
            emit(ok ? "=== M3 监听取证：PASS ===" : "=== M3 监听取证：FAIL ===")
            try? (lines.joined(separator: "\n") + "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
        app.run()
        return received != nil && productHover && productClick ? 0 : 1
    }
}
