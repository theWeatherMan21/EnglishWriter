// ContrastTests.swift — 侧栏 tokens 的对比度回归（WCAG 2.2 AA）
//
// 为什么要断言：颜色是设计里最容易「悄悄变差」的东西——改个灰、调个底，正文就可能掉到 3:1。
// 这里直接读 web/sidebar/tokens.css 的真实十六进制值，算 WCAG 对比度：
//   · 正文/次要文字 on 各自底色 ≥ 4.5:1
//   · 图形/大字号（进度条、色点）≥ 3.0:1
// 任何一档低于阈值就 FAIL，并打印实际比值。

import Foundation

enum ContrastTests {
    private struct RGB { var r: Double; var g: Double; var b: Double }

    private static func parse(_ hex: String) -> RGB? {
        var h = hex.trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return RGB(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    private static func luminance(_ c: RGB) -> Double {
        func f(_ x: Double) -> Double { x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b)
    }

    static func ratio(_ a: String, _ b: String) -> Double? {
        guard let x = parse(a), let y = parse(b) else { return nil }
        let la = luminance(x), lb = luminance(y)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 从 tokens.css 里读真实变量值（找不到就返回 nil，测试会报缺）
    private static func tokens() -> [String: String] {
        let path = FileManager.default.currentDirectoryPath + "/web/sidebar/tokens.css"
        guard let css = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: "--([a-z-]+):\\s*(#[0-9A-Fa-f]{6})")
        for m in re.matches(in: css, range: NSRange(location: 0, length: (css as NSString).length)) {
            let ns = css as NSString
            out[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        return out
    }

    static func run() {
        let t = tokens()
        guard !t.isEmpty else {
            SelfTest.bad("contrast: 读不到 tokens.css", FileManager.default.currentDirectoryPath)
            return
        }
        // (说明, 前景变量, 背景变量, 最低要求)
        let cases: [(String, String, String, Double)] = [
            ("正文 on 面板", "text", "bg", 4.5),
            ("正文 on 卡片", "text", "card-bg", 4.5),
            ("次要文字 on 面板", "text-muted", "bg", 4.5),
            ("次要文字 on 卡片", "text-muted", "card-bg", 4.5),
            ("危险红（删除）on 卡片", "danger", "card-bg", 4.5),
            ("品牌绿（替换/主按钮）on 面板", "brand", "bg", 4.5),
            ("正确绿图标 on 面板", "engagement", "bg", 3.0),
            ("类别色·正确性 on 面板", "correctness", "bg", 3.0),
            ("类别色·清晰度 on 面板", "clarity", "bg", 3.0),
            ("类别色·风格 on 面板", "style", "bg", 3.0),
        ]
        for (name, fg, bg, min) in cases {
            guard let a = t[fg], let b = t[bg] else {
                SelfTest.bad("contrast: \(name)", "tokens 缺 \(fg)/\(bg)"); continue
            }
            guard let r = ratio(a, b) else {
                SelfTest.bad("contrast: \(name)", "颜色解析失败 \(a) / \(b)"); continue
            }
            let ok = r >= min
            let detail = String(format: "%.2f:1（阈值 %.1f）%@ / %@", r, min, a as NSString, b as NSString)
            if ok { SelfTest.ok("contrast: \(name)", detail) }
            else { SelfTest.bad("contrast: \(name)", detail) }
        }
    }
}
