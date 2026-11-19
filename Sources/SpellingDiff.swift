// SpellingDiff.swift — 逐字母差异高亮（侧栏建议行用）
//
// 为什么单独抽出来：`immediatly → immediately` 整词一个颜色，人眼看着几乎一样，
// 会被当成误报。必须把「真正变的那几个字母」标出来（共同前后缀灰显，差异段红删除线 vs 绿加粗）。
//
// 抽成纯函数才能断言：给一对词，返回的富文本里差异段的属性必须真的不同。

import AppKit

enum SpellingDiff {

    struct Parts {
        var prefix = ""
        var oldMid = ""
        var suffix = ""
        var newMid = ""
    }

    /// 共同前缀 / 后缀切分
    static func parts(original: String, replacement: String) -> Parts {
        let a = Array(original), b = Array(replacement)
        var pre = 0
        while pre < min(a.count, b.count), a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < min(a.count - pre, b.count - pre),
              a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        var p = Parts()
        p.prefix = String(a[0..<pre])
        p.oldMid = String(a[pre..<(a.count - suf)])
        p.suffix = String(a[(a.count - suf)...])
        p.newMid = String(b[pre..<(b.count - suf)])
        return p
    }

    static func attributed(original: String, replacement: String) -> NSAttributedString {
        let p = parts(original: original, replacement: replacement)
        let out = NSMutableAttributedString()
        let normal: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        let oldBad: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.systemRed,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]
        let newGood: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.systemGreen,
        ]
        out.append(NSAttributedString(string: p.prefix, attributes: normal))
        out.append(NSAttributedString(string: p.oldMid, attributes: oldBad))
        out.append(NSAttributedString(string: p.suffix + " → " + p.prefix, attributes: normal))
        out.append(NSAttributedString(string: p.newMid, attributes: newGood))
        out.append(NSAttributedString(string: p.suffix, attributes: normal))
        return out
    }
}
