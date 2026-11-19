// CardPlacement.swift — 卡片边界规避（纯函数，可断言）
//
// 问题：卡片默认贴在词的正下方，靠近屏幕底/右边缘时会被裁掉一半。
// 规则（Grammarly 同款）：下方放不下就翻到词上方；右侧放不下就左移；左侧放不下就右移；
// 多屏时按锚点所在的那块屏幕算，不是永远用主屏。

import Foundation

enum CardPlacement {

    /// - Parameters:
    ///   - anchor: 词在 Quartz 坐标系里的矩形（左上原点）
    ///   - cardSize: 卡片尺寸
    ///   - screenVisible: 该屏的可见区域（Quartz，已扣掉菜单栏/Dock）
    /// - Returns: 卡片左上角在 Quartz 坐标系中的位置
    static func resolve(anchor: CGRect,
                        cardSize: CGSize,
                        screenVisible: CGRect,
                        gap: CGFloat = 6) -> CGPoint {
        var x = anchor.minX
        var y = anchor.maxY + gap                 // 默认贴词下方

        // 下方放不下 → 翻到词上方
        if y + cardSize.height > screenVisible.maxY {
            y = anchor.minY - gap - cardSize.height
        }
        // 翻上去也放不下（词本身就在屏幕顶）→ 贴住可见区顶部
        if y < screenVisible.minY {
            y = screenVisible.minY
        }
        // 右侧放不下 → 左移
        if x + cardSize.width > screenVisible.maxX {
            x = screenVisible.maxX - cardSize.width
        }
        // 左侧放不下 → 右移
        if x < screenVisible.minX {
            x = screenVisible.minX
        }
        return CGPoint(x: x, y: y)
    }
}
