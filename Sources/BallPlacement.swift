// BallPlacement.swift — 浮动球位置（纯函数，可断言）
//
// 爹地原话：球要「按在随输入框光标移动，而不是整个屏幕乱飞」。
// 旧实现三处硬伤：只按主屏高度换算 / 贴文本框右边缘出屏不管 / anchor 用 513 块并集（每次都在变）。
//
// 规则：
//   · 贴文本框**右下角内侧**，内缩 8pt（Grammarly 的位置）
//   · 用 anchor 所在那块屏，不是永远主屏
//   · 最后 clamp 进可见区（留 4pt 边）

import Foundation

enum BallPlacement {
    static let size: CGFloat = 22
    static let inset: CGFloat = 8
    static let margin: CGFloat = 4

    /// - Returns: 球左上角在 Quartz 坐标系（左上原点）里的位置
    static func resolve(anchor: CGRect, screenVisible: CGRect, size: CGFloat = size) -> CGPoint {
        // 右下角内侧
        var x = anchor.maxX - size - inset
        var y = anchor.maxY - size - inset

        // 夹进可见区
        let minX = screenVisible.minX + margin
        let maxX = screenVisible.maxX - size - margin
        let minY = screenVisible.minY + margin
        let maxY = screenVisible.maxY - size - margin
        x = min(max(x, minX), max(maxX, minX))
        y = min(max(y, minY), max(maxY, minY))
        return CGPoint(x: x, y: y)
    }
}
