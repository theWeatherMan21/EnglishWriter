// Tokens.swift — 设计令牌：全局唯一来源（间距 / 字号 / 圆角 / 颜色 / 阴影）
//
// 为什么要有这个文件：之前每个控件各写各的尺寸，结果就是爹地说的「毛坯」——
// 十几个互不相干的数字拼在一起。这里定死一套，Swift 和 CSS 都从它取值。
//
// 口径（知澜 11-19 定）：
//   间距 4 / 8 / 12 / 16 / 24 / 32
//   字号 11 辅助 · 12 次要 · 13 正文 · 15 标题 · 20 大数 · 28 总分
//   字重 400 / 500 / 600
//   圆角 6 控件 · 10 卡片 · 14 面板
//   颜色 Grammarly 实值：主色 #027E6F / 正确性 #EE1437 / 清晰度 #4A6EDE / 表达 #7E57C2 / 吸引力 #2E7D32
//                       背景 #FFFFFF #FAFAFA / 边框 #E5E7EB / 文字 #1F2328 #6B7280

import AppKit

enum Tokens {

    // MARK: 间距（4 的倍数）
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32

    // MARK: 字号
    static let fCaption: CGFloat = 11
    static let fSecondary: CGFloat = 12
    static let fBody: CGFloat = 13
    static let fTitle: CGFloat = 15
    static let fBig: CGFloat = 20
    static let fScore: CGFloat = 28

    // MARK: 圆角
    static let rControl: CGFloat = 6
    static let rCard: CGFloat = 10
    static let rPanel: CGFloat = 14

    // MARK: 颜色
    static let brand = NSColor(hex: 0x027E6F)
    static let correctness = NSColor(hex: 0xEE1437)
    static let clarity = NSColor(hex: 0x4A6EDE)
    static let style = NSColor(hex: 0x7E57C2)
    static let engagement = NSColor(hex: 0x2E7D32)
    static let bg = NSColor(hex: 0xFFFFFF)
    static let bgSubtle = NSColor(hex: 0xFAFAFA)
    static let border = NSColor(hex: 0xE5E7EB)
    static let text = NSColor(hex: 0x1F2328)
    static let textMuted = NSColor(hex: 0x6B7280)

    /// 给 WebView 用的 CSS 变量（一处改，两边生效）
    static var cssVariables: String {
        """
        :root {
          --s1: 4px; --s2: 8px; --s3: 12px; --s4: 16px; --s6: 24px; --s8: 32px;
          --f-caption: 11px; --f-secondary: 12px; --f-body: 13px; --f-title: 15px;
          --f-big: 20px; --f-score: 28px;
          --r-control: 6px; --r-card: 10px; --r-panel: 14px;
          --brand: #027E6F; --correctness: #EE1437; --clarity: #4A6EDE;
          --style: #7E57C2; --engagement: #2E7D32;
          --bg: #FFFFFF; --bg-subtle: #FAFAFA; --border: #E5E7EB;
          --text: #1F2328; --text-muted: #6B7280;
          --shadow-card: 0 1px 2px rgba(0,0,0,.06);
          --shadow-popover: 0 4px 16px rgba(0,0,0,.12);
          --shadow-panel: 0 8px 32px rgba(0,0,0,.16);
        }
        """
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                  green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                  blue: CGFloat(hex & 0xFF) / 255.0,
                  alpha: 1)
    }
}
