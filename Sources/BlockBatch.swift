// BlockBatch.swift — 「可见块合并成一次请求」的拼接与回映射（纯函数，可离屏断言）
//
// 为什么要有它：11-23 java 爆炸的根因是「一块一个 /v2/check」。
// 改成整篇拼接一次请求后，必须保证两件事，否则下划线会画在错位置：
//   1. 拼接不改变每块在整篇里的偏移（segs 记录起始）
//   2. 引擎回来的 match 按偏移映射回具体块，跨块的一律丢

import Foundation

enum BlockBatch {
    struct Seg: Equatable {
        let blockIndex: Int
        let start: Int      // 该块在拼接文本里的 UTF-16 起始
        let length: Int
    }

    struct Joined {
        let text: String
        let segs: [Seg]
        var isEmpty: Bool { segs.isEmpty }
    }

    /// 把块拼成一篇；超过 charLimit 就停（宁可少查几块，也不让单次请求变慢）
    static func join(_ texts: [String], blockIndexes: [Int], separator: String = "\n\n",
                     charLimit: Int = 8000) -> Joined {
        var out = ""
        var segs: [Seg] = []
        for (i, t) in texts.enumerated() where i < blockIndexes.count {
            let len = (t as NSString).length
            if (out as NSString).length + len > charLimit { break }
            let start = (out as NSString).length
            out += t + separator
            segs.append(Seg(blockIndex: blockIndexes[i], start: start, length: len))
        }
        return Joined(text: out, segs: segs)
    }

    /// 把整篇级 match 映射回块内偏移；跨块 / 落在分隔符上的 match 返回 nil（丢弃）
    static func map(_ items: [DiffItem], in joined: Joined) -> [(item: DiffItem, blockIndex: Int)] {
        var out: [(DiffItem, Int)] = []
        for var it in items {
            guard it.length > 0, it.start >= 0 else { continue }
            guard let seg = joined.segs.last(where: { $0.start <= it.start }) else { continue }
            guard it.start + it.length <= seg.start + seg.length else { continue }
            it.start -= seg.start
            out.append((it, seg.blockIndex))
        }
        return out
    }
}
