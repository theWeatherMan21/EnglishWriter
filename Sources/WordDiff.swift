// WordDiff.swift — 把「改写后的整句」反推成逐条 edit
//
// 为什么需要：模型给 span（start/length/original/replacement）时经常边界错位，
// 拼出来是 "provideus" 或 "usus" 这种碎片（11-19 实测，3 轮里 1 轮出现）。
// 改成让模型只给「改写后的整句」，edit 由本地算——原文字串天然合法，不会再错位。

import Foundation

enum WordDiff {
    /// 词级 LCS，返回把 original 变成 rewritten 的最小 edit 集合（相对 original 的 UTF-16 偏移）
    static func edits(original: String, rewritten: String) -> [DiffItem] {
        if original == rewritten { return [] }
        let a = tokens(original), b = tokens(rewritten)
        let n = a.count, m = b.count
        guard n > 0, m > 0 else { return [] }

        // LCS 表
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i].text == b[j].text ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        // 走一遍，收集「原文字区间 → 新文本」的替换块
        var out: [DiffItem] = []
        var i = 0, j = 0
        var pendingOld = "", pendingNew = ""
        var pendingStart = -1, pendingLen = 0

        func flush() {
            guard pendingStart >= 0, pendingLen > 0 else { pendingOld = ""; pendingNew = ""; pendingStart = -1; pendingLen = 0; return }
            out.append(DiffItem(start: pendingStart, length: pendingLen,
                                original: pendingOld, replacement: pendingNew,
                                type: "style", reason: "改写"))
            pendingOld = ""; pendingNew = ""; pendingStart = -1; pendingLen = 0
        }

        while i < n && j < m {
            if a[i].text == b[j].text {
                flush()
                i += 1; j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                if pendingStart < 0 { pendingStart = a[i].range.location }
                pendingOld += a[i].text
                pendingLen += a[i].range.length
                i += 1
            } else {
                // 纯插入（b 多出一个词）：不许产生 length=0 的 edit（会被下游丢掉），
                // 改成「把下一个原词替换成 新词+该原词」
                if pendingStart < 0 {
                    if i < n {
                        pendingStart = a[i].range.location
                        pendingLen = a[i].range.length
                        pendingOld = a[i].text
                        i += 1
                    } else {
                        // 末尾追加：附着到最后一个原词上
                        if let last = a.last {
                            pendingStart = last.range.location
                            pendingLen = last.range.length
                            pendingOld = last.text
                            pendingNew = last.text
                        }
                    }
                }
                pendingNew += b[j].text
                j += 1
            }
        }
        while i < n {
            if pendingStart < 0 { pendingStart = a[i].range.location }
            pendingOld += a[i].text; pendingLen += a[i].range.length; i += 1
        }
        while j < m { pendingNew += b[j].text; j += 1 }
        flush()

        // 去掉「改了等于没改」的块（尾随空格差异等）
        return out.filter { $0.original != $0.replacement }
    }

    private struct Token { var text: String; var range: NSRange }

    /// 切成「词 + 其后空白」，保留原始 UTF-16 偏移，保证拼回去仍是原文
    private static func tokens(_ s: String) -> [Token] {
        let ns = s as NSString
        var out: [Token] = []
        var i = 0
        while i < ns.length {
            let start = i
            // 一个词：连续非空白
            while i < ns.length, !isSpace(ns.character(at: i)) { i += 1 }
            // 其后空白也算进这个词，避免拼接时吞空格
            while i < ns.length, isSpace(ns.character(at: i)) { i += 1 }
            out.append(Token(text: ns.substring(with: NSRange(location: start, length: i - start)),
                             range: NSRange(location: start, length: i - start)))
        }
        return out
    }

    private static func isSpace(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 10 || c == 13
    }
}
