// Geometry.swift — 坐标口径唯一入口
//
// 内部一律用「全局屏幕坐标、左上原点」（AX / Quartz 口径）；
// 只有建 NSWindow / NSView 时才转 AppKit（左下原点）。
// 主屏高度取 NSScreen.screens.first（Quartz 全局原点就在主屏左上角）。

import AppKit

enum ScreenGeom {
    /// Quartz 全局原点到 AppKit 全局原点的 y 偏移（= 主屏顶到主屏底）
    static var topOffset: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    /// Quartz（左上原点）→ AppKit（左下原点）。topOffset 可显式传入，便于离屏断言多屏/Retina 情形
    static func toAppKit(_ r: CGRect, topOffset off: CGFloat? = nil) -> NSRect {
        let o = off ?? topOffset
        return NSRect(x: r.minX, y: o - r.maxY, width: r.width, height: r.height)
    }

    /// AppKit（左下原点）→ Quartz（左上原点）
    static func toQuartz(_ r: NSRect, topOffset off: CGFloat? = nil) -> CGRect {
        let o = off ?? topOffset
        return CGRect(x: r.minX, y: o - r.maxY, width: r.width, height: r.height)
    }

    /// 点也用同一套口径（点击命中只关心点，宽高恒 0）
    static func pointToQuartz(_ p: CGPoint, topOffset off: CGFloat? = nil) -> CGPoint {
        let o = off ?? topOffset
        return CGPoint(x: p.x, y: o - p.y)
    }

    /// 覆盖窗口只覆盖一条屏幕时用它定位
    static func screen(containingQuartz rect: CGRect) -> NSScreen? {
        let appKit = toAppKit(rect)
        return NSScreen.screens.first { $0.frame.intersects(appKit) } ?? NSScreen.main
    }

    /// 把一条屏幕矩形夹进它所在屏幕的可见区，避免窗口飘到屏幕外
    static func clampToScreen(_ rect: CGRect) -> CGRect {
        guard let s = screen(containingQuartz: rect) else { return rect }
        let vis = toAppKit(s.visibleFrame)
        let minX = toQuartz(NSRect(x: vis.minX, y: vis.minY, width: 8, height: 8)).minX
        let maxX = vis.maxX
        let minY = vis.minY
        let maxY = topOffset - vis.minY
        var r = rect
        r.origin.x = min(max(r.minX, minX), max(minX, maxX - r.width))
        r.origin.y = min(max(r.minY, minY), max(minY, maxY - r.height))
        return r
    }

    /// 屏幕矩形并集（画多行下划线时给一个覆盖窗口）
    static func union(_ rects: [CGRect]) -> CGRect {
        guard var out = rects.first else { return .zero }
        for r in rects.dropFirst() { out = out.union(r) }
        return out
    }
}

extension ScreenGeom {
    /// 当前最前面那层**正常窗口**的宿主 App（跳过我们自己的窗口与高于 normal 的浮层）。
    /// 为什么不用 NSWorkspace.frontmostApplication：我们的 overlay / 卡片会成为 key，
    /// 回调里读它常常拿到旧值或我们自己（11-19 实测：点 TextEdit 的线却报 front=WeChat）。
    static func frontmostWindowPID(excluding selfPid: pid_t = getpid()) -> pid_t {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        }
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != selfPid else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }                 // 只认 normal 层，跳过菜单栏/浮层
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0.01 else { continue }
            return pid
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }
}
