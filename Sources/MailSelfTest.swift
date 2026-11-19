// MailSelfTest.swift — Mail 块路径的**离屏**验收（不碰真实 Mail、不建窗、不截屏）
//
// 为什么要它：真实 Mail 里那封邮件可见英文只有签名档，items=0。
// items=0 时 rectsInside=true 毫无意义 —— 空集合当然「都在窗口内」。
// 所以用与 Mail 同构的块序列（多个文本块 + 拼接 + offset 映射），喂一段**已知有错**的英文，
// 验证：建议 >0 → 每条能反查到块 → 每块能算出窗口内矩形 → 同词只报一次 → 上限 20。

import Foundation

enum MailSelfTest {
    /// 与 Mail 阅读视图同构：多个 AXStaticText 块，按文档顺序拼接
    static let blocks: [(text: String, frame: CGRect)] = [
        ("Marketing – Network Management",              CGRect(x: 120, y: 100, width: 420, height: 18)),
        ("There is many reasons for the delay.",         CGRect(x: 120, y: 126, width: 380, height: 18)),
        ("We should sent the report immediatly.",        CGRect(x: 120, y: 152, width: 360, height: 18)),
        ("Best regards,",                                CGRect(x: 120, y: 178, width: 120, height: 18)),
        ("Russo McAllister",                             CGRect(x: 120, y: 204, width: 160, height: 18)),
        ("There is many reasons again.",                 CGRect(x: 120, y: 230, width: 320, height: 18)),
    ]

    static let window = CGRect(x: 100, y: 80, width: 900, height: 600)

    static func run(_ argv: [String]) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)      // 管道下 stdout 默认块缓冲，不刷新等于什么都不打印
        var fails = 0

        func pass(_ name: String, _ detail: String) {
            print("PASS  \(name)  — \(detail)")
        }
        func fail(_ name: String, _ detail: String) {
            print("FAIL  \(name)  — \(detail)"); fails += 1
        }

        // 1) 拼文本 + 记每块的 utf16 起点（和 Mail 那条路一样的口径）
        let ns = NSMutableString()
        var starts: [Int] = []
        for b in blocks {
            starts.append(ns.length)
            if ns.length > 0 { ns.append("\n") ; starts[starts.count - 1] = ns.length }
            ns.append(b.text)
        }
        let joined = ns as String
        print("--- Mail 块路径离屏验收（" + String(blocks.count) + " 块 / " + String(joined.utf16.count) + " 字）---")

        // 2) 走生产同一条检查流水线
        var items = SpellCheck.items(in: joined)
        items += LocalGrammar.apply(to: joined)
        items += StyleRules.apply(to: joined)
        items = DiffSanitize.consolidate(items, in: joined)
        // 生产同一套规则：同词只报一次 + 上限 20（applyWeb 里用的就是这个纯函数）
        items = WebText.ItemFilter.dedupeAndCap(items, item: { $0 }, max: 20)

        if items.isEmpty {
            fail("建议必须 >0", "已知有错的样本却 0 条：链路断了")
            print("=== 汇总：PASS 0 / FAIL \(fails) ===")
            return 1
        }
        pass("建议 >0", "\(items.count) 条")

        // 3) 每条建议必须能反查到块、偏移对得上、矩形在窗口内
        var mapped = 0
        var dedup = Set<String>()
        var dupHit = false
        for it in items {
            let r = it.utf16Range
            guard r.location >= 0, r.length > 0, r.location + r.length <= joined.utf16.count else {
                fail("建议偏移越界", "\(it.original) @\(r.location)+\(r.length)"); continue
            }
            let slice = (joined as NSString).substring(with: r)
            guard slice == it.original else {
                fail("偏移对不上原文", "期望 \(it.original) 实际 \(slice)"); continue
            }
            // 反查块
            var bi = -1
            for (i, s) in starts.enumerated() where r.location >= s && r.location < s + blocks[i].text.utf16.count + 1 { bi = i }
            guard bi >= 0 else { fail("反查不到块", it.original); continue }
            let localLen = blocks[bi].text.utf16.count
            let local = r.location - starts[bi]
            guard local >= 0, local + r.length <= localLen else {
                fail("块内偏移错", "\(it.original) local=\\(local)"); continue
            }
            // 矩形（生产规则：块 frame，再夹进窗口）
            let rects = WebText.rects(forLocal: NSRange(location: local, length: r.length),
                                      blockFrame: blocks[bi].frame, inWindow: window)
            guard !rects.isEmpty else { fail("块算不出矩形", it.original); continue }
            for rc in rects where !window.contains(rc) {
                fail("矩形越出窗口", "\(it.original) \(rc)"); continue
            }
            mapped += 1
            if !dedup.insert(it.original.lowercased()).inserted { dupHit = true }
        }
        if mapped == items.count { pass("每条都能反查块 + 算出窗口内矩形", "\(mapped)/\(items.count)") }
        else { fail("映射不全", "\(mapped)/\(items.count)") }

        if dupHit { fail("同词只报一次", "存在重复原词") } else { pass("同词只报一次", "无重复") }
        if items.count <= 20 { pass("单篇上限 20", "\(items.count) ≤ 20") } else { fail("单篇上限 20", "\(items.count)") }

        // 4) 关键判据：真有错的地方必须命中（不漏）
        let mustCatch = ["There is many reasons", "immediatly"]
        for m in mustCatch {
            if items.contains(where: { $0.original.contains(m) || m.contains($0.original) }) {
                pass("命中已知错误", m)
            } else {
                fail("漏报", m)
            }
        }

        print("=== 汇总：PASS \(max(0, 6 - fails)) / FAIL \(fails) ===")
        return fails == 0 ? 0 : 1
    }
}
