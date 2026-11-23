// M3Flow.swift — M3 链路的核心（命中 → 卡片 → 接受 / 忽略 / 撤销）
//
// 为什么单独抽出来：卡片、下划线、AX 写回都碰不到「测试」——要断言「接受后文本等于期望串、
// 撤销后回到原文、忽略后该条不再返回」，就必须有一个不依赖真窗口的文档抽象。
// 所以这里放三样东西，真机路径和离线自测走的是同一份代码：
//   1. M3Doc：文档读写（真机 = AX / Web 文本块；自测 = 内存 BufferDoc）
//   2. M3Flow：接受（按条 applyEdits）、撤销（快照栈）、忽略（文本 hash）、命中、卡片摆放
//   3. M3UndoStack：接受前的原文快照 + pid + range，内存栈（进程退出即失效，符合规格）
//
// 纪律：这里所有函数都不弹窗、不截屏、不发网络请求——可以放心在 --selftest / CI 里跑。

import AppKit

// MARK: - 文档抽象

/// 一条可以被「按 range 替换」的正文。真机是 AX 元素或 Web 文本块，自测是纯字符串。
protocol M3Doc: AnyObject {
    var pid: pid_t { get }
    /// 当前全文（接受后再读一次，用来验证「真的写进去了」）
    var fullText: String { get }
    /// 只替换一个 range；返回是否成功（失败时不得留下半截状态）
    func replace(range: NSRange, with replacement: String) -> Bool
    /// 整段回写：range 回写失败 / 文本已被改动时，用接受前快照兜底
    func writeFullText(_ text: String) -> Bool
    /// 文本能否读回（Chromium 网页字段的 AXValue 是空的：写成功也读不回，只能信写回返回值）
    var canReadBack: Bool { get }
}

extension M3Doc {
    var canReadBack: Bool { true }
}

/// 离线自测 / 线上驱动用的内存文档：记录每一次写入，方便断言「只动了一条」
final class BufferDoc: M3Doc {
    var pid: pid_t
    private(set) var text: String
    private(set) var writes: [(range: NSRange, text: String)] = []
    private(set) var fullWrites: Int = 0

    init(_ text: String, pid: pid_t = 0) {
        self.text = text
        self.pid = pid
    }

    var fullText: String { text }

    func replace(range: NSRange, with replacement: String) -> Bool {
        let ns = text as NSString
        guard range.location != NSNotFound, range.location >= 0,
              NSMaxRange(range) <= ns.length else { return false }
        text = ns.replacingCharacters(in: range, with: replacement)
        writes.append((range, replacement))
        return true
    }

    func writeFullText(_ text: String) -> Bool {
        self.text = text
        fullWrites += 1
        return true
    }
}

/// 闭包式适配器：AX 元素 / Web 文本块都只要给两个闭包，不用各自实现一套协议
final class ClosureDoc: M3Doc {
    let pid: pid_t
    let canReadBack: Bool
    private let read: () -> String
    private let writeRange: (NSRange, String) -> Bool
    private let writeFull: (String) -> Bool

    init(pid: pid_t, canReadBack: Bool = true,
         read: @escaping () -> String,
         writeRange: @escaping (NSRange, String) -> Bool,
         writeFull: @escaping (String) -> Bool) {
        self.pid = pid
        self.canReadBack = canReadBack
        self.read = read
        self.writeRange = writeRange
        self.writeFull = writeFull
    }

    var fullText: String { read() }
    func replace(range: NSRange, with replacement: String) -> Bool { writeRange(range, replacement) }
    func writeFullText(_ text: String) -> Bool { writeFull(text) }
}

// MARK: - 撤销栈

/// 接受前的一帧：原文快照 + pid + range（规格要求三项都在）+ 当时那个文档句柄（撤销要写回同一处）
struct M3UndoEntry {
    let itemID: Int
    let pid: pid_t
    let range: NSRange          // 被替换的那一段在全文里的位置
    let original: String        // 原来那段文字
    let replacement: String     // 写进去的建议
    let snapshot: String        // 接受前的全文（回写兜底）
    let newText: String         // 接受后的全文（判断文本有没有被用户再改过）
    let doc: M3Doc?             // 同一次写回用的文档句柄（AX 元素 / Web 块 / 内存缓冲）
    let at: Date

    var describe: String {
        "pid=\(pid) range=\(range.location)+\(range.length) \(original)→\(replacement)"
    }
}

final class M3UndoStack {
    static let shared = M3UndoStack()
    private(set) var entries: [M3UndoEntry] = []
    private let limit = 20

    var count: Int { entries.count }
    var top: M3UndoEntry? { entries.last }
    var canUndo: Bool { !entries.isEmpty }

    func push(_ e: M3UndoEntry) {
        entries.append(e)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    @discardableResult
    func pop() -> M3UndoEntry? { entries.popLast() }

    func clear() { entries.removeAll() }
}

// MARK: - 忽略集合（文本 hash）

enum M3Ignore {
    /// 同一条建议的稳定指纹：原文 + 建议（大小写不敏感，避免 There/There 重复记两条）
    static func hash(original: String, replacement: String) -> String {
        let key = original.lowercased() + "\u{1}" + replacement.lowercased()
        var h: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a 64
        for b in key.utf8 {
            h ^= UInt64(b)
            h = h &* 0x100_0000_01b3
        }
        return String(format: "%016llx", h)
    }

    /// 过滤：命中忽略集合的条目一律不出（不画线、不出卡片）
    static func filter(_ items: [DiffItem], isIgnored: (DiffItem) -> Bool) -> [DiffItem] {
        items.filter { !isIgnored($0) }
    }
}

// MARK: - 一句中文理由

enum ReasonText {
    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
    }

    /// 引擎给的理由可能是英文（LanguageTool 的 message），卡片上必须是中文一句话
    static func zh(type: String, reason: String, original: String, replacement: String) -> String {
        let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasCJK(r) { return oneLine(r) }
        switch type.lowercased() {
        case "spelling": return "拼写错误：应为「\(replacement)」"
        case "grammar":  return "语法不对：「\(original)」改成「\(replacement)」"
        case "clarity":  return "表达啰嗦：压缩成「\(replacement)」更清楚"
        case "style":    return "风格建议：换成「\(replacement)」更自然"
        default:         return "建议把「\(original)」改成「\(replacement)」"
        }
    }

    private static func oneLine(_ s: String) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }
}

// MARK: - 链路

enum M3Flow {

    struct AcceptOutcome {
        var ok: Bool
        var expected: String       // applyEdits(only:) 算出来的期望文本
        var actual: String         // 写入后重新读到的文本
        var detail: String
    }

    /// 读回补齐：宿主异步写回时，前几次读到的可能是旧文本。
    /// 返回最后一次读到的内容（成功就早退，不为省时间而漏判）。
    static func readBack(doc: M3Doc, expected: String, tries: Int = 8, gapUS: useconds_t = 50_000) -> String {
        var last = doc.fullText
        let want = normalize(expected)
        var i = 0
        while i < tries {
            last = doc.fullText
            if normalize(last) == want { return last }
            usleep(gapUS)
            i += 1
        }
        return last
    }

    /// 比较文本前先抹掉「肉眼看不见」的差异：NBSP、行尾空白、全角空格
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{00A0}", with: " ")
         .replacingOccurrences(of: "\u{3000}", with: " ")
         .split(separator: "\n", omittingEmptySubsequences: false)
         .map { $0.replacingOccurrences(of: " +$", with: "", options: .regularExpression) }
         .joined(separator: "\n")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 接受一条：**只**替换这一条的 range（同一段其它建议不动），接受前把全文快照压栈
    static func accept(items: [DiffItem], only id: Int, in doc: M3Doc, stack: M3UndoStack) -> AcceptOutcome {
        let before = doc.fullText
        guard id >= 0, id < items.count else {
            return AcceptOutcome(ok: false, expected: before, actual: before, detail: "itemID \(id) 越界（共 \(items.count) 条）")
        }
        let it = items[id]
        let expected = applyEdits(items, to: before, only: id)

        let ns = before as NSString
        guard it.start >= 0, it.length > 0, it.start + it.length <= ns.length else {
            return AcceptOutcome(ok: false, expected: expected, actual: before, detail: "range \(it.start)+\(it.length) 越界")
        }
        guard ns.substring(with: it.utf16Range) == it.original else {
            return AcceptOutcome(ok: false, expected: expected, actual: before,
                                 detail: "range 处的文本是「\(ns.substring(with: it.utf16Range))」，与 original「\(it.original)」不符（文档已变，不写）")
        }

        // 先压栈再写：写完失败要立刻弹掉，绝不留一个回不去的撤销
        let entry = M3UndoEntry(itemID: id, pid: doc.pid, range: it.utf16Range,
                                original: it.original, replacement: it.replacement,
                                snapshot: before, newText: expected, doc: doc, at: Date())
        stack.push(entry)
        let wrote = doc.replace(range: it.utf16Range, with: it.replacement)
        // 读回校验：Mail / Word 这类宿主写回是异步的，立刻读会读到旧文本，
        // 于是「写了但判定失败再回滚」—— 用户看到的就是「点了接受没反应」。
        // 所以最多等 400ms 复读，并且比较前做空白归一（NBSP / 行尾空格）。
        let after = doc.canReadBack ? readBack(doc: doc, expected: expected) : doc.fullText
        // 读不回正文的输入框（Chromium）：只信写回返回值，不比文本
        let matches = doc.canReadBack ? (Self.normalize(after) == Self.normalize(expected)) : true
        if !wrote || !matches {
            stack.pop()
            return AcceptOutcome(ok: false, expected: expected, actual: after,
                                 detail: wrote ? "写回后文本与期望不一致" : "文档拒绝写入（该输入框不接受 AX 写入）")
        }
        return AcceptOutcome(ok: true, expected: expected, actual: after,
                             detail: "已接受：\(it.original) → \(it.replacement)")
    }

    /// 撤销栈顶那条：文本没被再改过就按 range 回写；否则用接受前快照整段回写
    /// 写回的是**接受当时那个文档句柄**（同一 pid、同一块），不猜当前焦点。
    static func undo(stack: M3UndoStack) -> (ok: Bool, detail: String) {
        guard let e = stack.top else { return (false, "撤销栈是空的（本次运行还没接受过任何建议）") }
        guard let doc = e.doc else { return (false, "撤销帧里没有文档句柄") }
        var ok = false
        if !doc.canReadBack || doc.fullText == e.newText {
            ok = doc.replace(range: NSRange(location: e.range.location, length: (e.replacement as NSString).length),
                             with: e.original)
        }
        if doc.canReadBack, doc.fullText != e.snapshot {
            // range 回写失败，或用户在中间又改过：用接受前快照整体回写
            _ = doc.writeFullText(e.snapshot)
        }
        let restored = doc.canReadBack ? (doc.fullText == e.snapshot) : ok
        if restored {
            stack.pop()
            return (true, "已撤销：\(e.replacement) → \(e.original)（range \(e.range.location)+\(e.range.length) pid=\(e.pid)）")
        }
        return (false, "撤销失败：回写后文本仍与快照不一致")
    }

    /// 兼容入口：显式给文档（自测/驱动用）
    static func undo(in doc: M3Doc, stack: M3UndoStack) -> (ok: Bool, detail: String) {
        undo(stack: stack)
    }

    /// 命中：覆盖窗口 ignoresMouseEvents，所以只能拿全局鼠标点做矩形命中（±3 / ±6 容错）
    static func hit(_ specs: [UnderlineSpec], at p: CGPoint, dx: CGFloat = 3, dy: CGFloat = 6) -> UnderlineSpec? {
        specs.first { $0.rect.insetBy(dx: -dx, dy: -dy).contains(p) }
    }

    /// 卡片摆放（Quartz 左上原点）：统一走 CardPlacement.resolve（下方放不下翻上方、左右夹进屏幕）。
    /// 这里只把左上角换算成整块 rect，供离线断言与 CardWeb 共用同一份规则。
    static func placement(anchor: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = 4) -> CGRect {
        let p = CardPlacement.resolve(anchor: anchor, cardSize: size, screenVisible: visible, gap: gap)
        return CGRect(x: p.x, y: p.y, width: size.width, height: size.height)
    }
}
