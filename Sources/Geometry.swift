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

    /// Quartz（左上原点）→ AppKit（左下原点）
    static func toAppKit(_ r: CGRect) -> NSRect {
        NSRect(x: r.minX, y: topOffset - r.maxY, width: r.width, height: r.height)
    }

    /// AppKit（左下原点）→ Quartz（左上原点）
    static func toQuartz(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX, y: topOffset - r.maxY, width: r.width, height: r.height)
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
