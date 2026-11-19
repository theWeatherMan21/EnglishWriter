// SidebarPlacement.swift — 侧栏摆位（纯函数，自测直接断言）
//
// 口径（知澜 11-19 P1 规格）：「跟浮动球保持同一侧」。
//   · 球在屏幕右半 → 栏贴在球的**左边**（往屏内展开，不压到球）
//   · 球在屏幕左半 → 栏贴在球的**右边**
//   · 竖直方向以球的顶边为基准（栏顶≈球顶），再夹进屏可见区
//   · 没有球（菜单打开 / 快照）→ 贴屏右边缘，竖直居中，留 24pt
//
// 为什么单独抽出来：摆位是「看起来像不像 Grammarly」的一半，必须能用断言锁住，
// 不能靠上屏截图肉眼比。坐标一律 AppKit（左下原点），与 NSPanel.frame 同口径。

import AppKit

enum SidebarPlacement {

    static let gap: CGFloat = 10
    static let margin: CGFloat = 8

    /// - Parameters:
    ///   - ball: 浮动球的窗口矩形（AppKit 坐标）；nil = 没有球
    ///   - size: 侧栏目标尺寸
    ///   - screenVisible: 目标屏的 visibleFrame（AppKit 坐标）
    /// - Returns: 侧栏窗口原点（左下角）
    static func resolve(ball: NSRect?, size: NSSize, screenVisible: NSRect,
                        gap: CGFloat = gap) -> NSPoint {
        guard let b = ball else {
            return NSPoint(x: screenVisible.maxX - size.width - 24,
                           y: screenVisible.midY - size.height / 2)
        }

        // 横：跟球同一侧，往屏内展开
        var x: CGFloat
        if b.midX >= screenVisible.midX {
            x = b.minX - gap - size.width     // 球在右半屏 → 栏在球左侧
        } else {
            x = b.maxX + gap                  // 球在左半屏 → 栏在球右侧
        }

        // 竖：栏顶对齐球顶（往下长），再夹进屏
        var y = b.maxY - size.height

        x = min(max(x, screenVisible.minX + margin), screenVisible.maxX - size.width - margin)
        y = min(max(y, screenVisible.minY + margin), screenVisible.maxY - size.height - margin)
        return NSPoint(x: x, y: y)
    }

    /// 断言用：栏是否完全落在可见区内（屏幕比栏还小时只要求左上不越界）
    static func inside(origin: NSPoint, size: NSSize, screenVisible: NSRect,
                       margin: CGFloat = margin) -> Bool {
        guard screenVisible.width >= size.width + margin * 2,
              screenVisible.height >= size.height + margin * 2 else {
            return origin.x >= screenVisible.minX - 0.5 && origin.y >= screenVisible.minY - 0.5
        }
        return origin.x >= screenVisible.minX + margin - 0.5
            && origin.y >= screenVisible.minY + margin - 0.5
            && origin.x + size.width <= screenVisible.maxX - margin + 0.5
            && origin.y + size.height <= screenVisible.maxY - margin + 0.5
    }
}
