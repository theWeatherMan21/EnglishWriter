// WebText.swift — WebKit 正文适配层（Mail / Slack / 网页输入框）
//
// 事实（2026-11-16 本机实测，Mail 写信窗口）：
//   正文 = AXWebArea，AXValue 读不到、AXNumberOfCharacters 不暴露、AXSelectedTextRange 不暴露；
//   但正文按「段落/行」拆成一串 AXStaticText 叶子，每个叶子 AXValue 是它自己的文本，
//   且在叶子上调 AXBoundsForRange 能拿到真实矩形。
// 所以 Web 正文的检查单位是「文本块」而不是「整篇」：每个块单独送引擎、偏移在块内，画线也在块内。

import AppKit
import ApplicationServices

enum WebText {

    struct Block {
        var element: AXUIElement
        var text: String
    }

    /// body 下按文档顺序的所有非空文本块
    ///
    /// 加了节点预算与截止时间：Mail 一个窗口能挂 2000+ 个 AX 节点，每个节点都是一次跨进程 IPC。
    /// 无界遍历（11-23 之前）在 Mail 卡顿时会把常驻检查拖住，连累宿主。
    /// 按文档顺序取，预算用完就停 —— 拿到的是「靠前的块」，也就是用户正在看的那一段。
    static func blocks(of body: AXUIElement, nodeBudget: Int = 1500,
                       deadline: TimeInterval = 0.6) -> [Block] {
        var out: [Block] = []
        var budget = nodeBudget
        let until = Date().addingTimeInterval(deadline)
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth > 0, budget > 0 else { return }
            if Date() > until { budget = 0; return }
            for c in attrChildren(el) {
                budget -= 1
                if budget <= 0 { return }
                let role = attrString(c, kAXRoleAttribute as String) ?? ""
                if role == "AXStaticText" {
                    let t = attrString(c, kAXValueAttribute as String) ?? ""
                    if !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(Block(element: c, text: t))
                    }
                }
                walk(c, depth: depth - 1)
            }
        }
        walk(body, depth: 8)
        return out
    }

    /// 现读一个块元素当前的文本（不要用构造时抓的快照：Mail 写回后快照是旧的）
    static func liveText(of el: AXUIElement) -> String? {
        if let v = attrString(el, kAXValueAttribute as String) { return v }
        return nil
    }

    /// 文本框是不是 WebKit 形态
    static func isWebBody(_ el: AXUIElement) -> Bool {
        (attrString(el, kAXRoleAttribute as String) ?? "") == "AXWebArea"
    }

    /// 元素所在的窗口矩形（视口）。WebArea 的 AXFrame 常是整个文档高度，
    /// 拿它当窗口会把屏外块全算成可见 —— 必须往上找到 AXWindow 本身。
    static func windowFrame(of el: AXUIElement) -> CGRect {
        var cur: AXUIElement? = el
        var hops = 0
        while let c = cur, hops < 10 {
            if (attrString(c, kAXRoleAttribute as String) ?? "") == "AXWindow" { return frame(c) }
            guard let raw = attr(c, kAXParentAttribute as String) else { break }
            let cf = raw as CFTypeRef
            guard CFGetTypeID(cf) == AXUIElementGetTypeID() else { break }
            cur = (cf as! AXUIElement)
            hops += 1
        }
        return frame(el)
    }

    /// 是不是「能打字」的网页节点：有 AXEditable，或有 AXSelectedTextRange（能插光标）
    static func isEditableNode(_ el: AXUIElement) -> Bool {
        if AXInline.isEditable(el) { return true }
        var raw: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, "AXSelectedTextRange" as CFString, &raw) == .success, raw != nil {
            return true
        }
        return false
    }

    /// 在 AXWebArea 子树里找出**真正在写的正文容器**（最大面积的那个可编辑节点）。
    ///
    /// 为什么必须有这一层（11-23 真机事故）：Mail 窗口整块是一个 AXWebArea，
    /// 左栏 Inbox/Drafts、邮件列表、正文全是它的子孙。直接按 body 取块，线会画满整个窗口，
    /// 写回的偏移也是「整篇（含左栏）」口径 —— 于是「整体残留」+「点接受没反应」同一个根因。
    static func editableRegion(of body: AXUIElement) -> AXUIElement? {
        var best: AXUIElement?
        var bestArea: CGFloat = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth > 0 else { return }
            if isEditableNode(el) {
                let f = frame(el)
                let area = max(0, f.width) * max(0, f.height)
                if area >= bestArea { bestArea = area; best = el }
                return      // 最外层可编辑节点就是正文容器，不再往下钻
            }
            for c in attrChildren(el) { walk(c, depth: depth - 1) }
        }
        walk(body, depth: 10)
        return best
    }

    /// 纯函数：按「正文区」筛块。
    ///   · 有 editableFrame：只保留中心点落在正文区内（±2pt 容差）的块
    ///   · 没找到正文区：退化为「丢掉窗口左侧 20%」——那里是导航栏，不可能是正文
    /// 返回 (保留的索引, 丢掉的个数)
    static func filterOutsideNavigation(frames: [CGRect], window: CGRect,
                                        editableFrame: CGRect?) -> (keep: [Int], dropped: Int) {
        guard window.width > 0, window.height > 0 else { return (Array(frames.indices), 0) }
        var keep: [Int] = []
        var dropped = 0
        for (i, f) in frames.enumerated() {
            let c = CGPoint(x: f.midX, y: f.midY)
            if let e = editableFrame, e.width > 0, e.height > 0 {
                let ok = c.x >= e.minX - 2 && c.x <= e.maxX + 2 && c.y >= e.minY - 2 && c.y <= e.maxY + 2
                if ok { keep.append(i) } else { dropped += 1 }
                continue
            }
            let navEdge = window.minX + window.width * 0.2
            if c.x >= navEdge { keep.append(i) } else { dropped += 1 }
        }
        return (keep, dropped)
    }

    /// 只保留「屏幕上看得见」的文本块（Grammarly 口径）。
    ///
    /// 为什么必须过滤（2026-11-23 实测事故）：AXWebArea 代表整个文档，
    /// 一个网页读出来 1477 块；旧代码把每一块单独送 /v2/check，
    /// 再叠上每秒一次的全量轮询 → 数千并发请求把 JVM 打到 370% CPU、单请求 15.8s。
    /// 屏外块用户看不见，检查它没有任何价值，只会烧 CPU。
    static func visibleBlocks(of body: AXUIElement, inWindow window: CGRect? = nil) -> [Block] {
        let all = blocks(of: body)
        let win = window ?? windowFrame(of: body)
        guard win.width > 0, win.height > 0 else { return all }
        let padded = win.insetBy(dx: -2, dy: -2)
        return all.filter { b in
            let own = frame(b.element)
            if own.width > 0, own.height > 0 { return padded.intersects(own) }
            // AXFrame 全 0（WebKit 常见）→ 退回 AXBoundsForRange 判一次
            let ns = NSRange(location: 0, length: (b.text as NSString).length)
            return lineRects(for: ns, in: b).contains { padded.intersects($0) }
        }
    }

    /// 在窗口里找正文容器：优先 AXWebArea，其次最大的 AXTextArea
    static func body(in window: AXUIElement) -> AXUIElement? {
        var web: AXUIElement?
        var area: (el: AXUIElement, size: CGFloat)?
        // 有界：Mail 窗口 2000+ 节点，每个 attrChildren 都是一次 IPC。
        // 无界递归在 Mail 不响应时会把调用方卡死（11-23 实测探针 >25s 不返回）。
        var budget = 600
        let until = Date().addingTimeInterval(0.8)
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth > 0, budget > 0 else { return }
            if Date() > until { budget = 0; return }
            for c in attrChildren(el) {
                budget -= 1
                if budget <= 0 { return }
                let r0 = attrString(c, kAXRoleAttribute as String) ?? ""
                if r0 == "AXMenuBar" || r0 == "AXMenu" || r0 == "AXMenuItem" { continue }
                let role = attrString(c, kAXRoleAttribute as String) ?? ""
                let f = frame(c)
                if role == "AXWebArea", web == nil { web = c }
                if role == "AXTextArea" {
                    let s = f.width * f.height
                    if area == nil || s > area!.size { area = (c, s) }
                }
                walk(c, depth: depth - 1)
            }
        }
        walk(window, depth: 8)
        if let w = web { return w }
        return area?.el
    }

    static func frame(_ el: AXUIElement) -> CGRect {
        var rect = CGRect.zero
        if let pv = attr(el, kAXPositionAttribute as String), CFGetTypeID(pv) == AXValueGetTypeID() {
            var p = CGPoint.zero
            if AXValueGetValue(pv as! AXValue, .cgPoint, &p) { rect.origin = p }
        }
        if let sv = attr(el, kAXSizeAttribute as String), CFGetTypeID(sv) == AXValueGetTypeID() {
            var s = CGSize.zero
            if AXValueGetValue(sv as! AXValue, .cgSize, &s) { rect.size = s }
        }
        return rect
    }

    /// 块内 range → 屏幕矩形（块自己的 AXBoundsForRange）
    /// 同词去重 + 单篇上限（生产与离屏验收共用同一套规则）
    enum ItemFilter {
        /// 去重键默认「原文小写」；调用方可传入「块 + 原文」，
        /// 否则同一句里同样的错误在不同段落只会报第一处（跨块误杀）。
        static func dedupeAndCap<T>(_ xs: [T], item: (T) -> DiffItem, max: Int,
                                    key: ((T) -> String)? = nil) -> [T] {
            var seen = Set<String>()
            var out: [T] = []
            for x in xs {
                let k = key?(x) ?? item(x).original.lowercased()
                guard !seen.contains(k) else { continue }
                seen.insert(k)
                if out.count >= max { break }
                out.append(x)
            }
            return out
        }
    }

    /// 纯函数版：把块内范围落到矩形（不碰 AX）。
    /// 生产里 AXBoundsForRange 给不出矩形时走的就是这条（块自身 frame，再夹进窗口）。
    static func rects(forLocal ns: NSRange, blockFrame: CGRect, inWindow window: CGRect) -> [CGRect] {
        guard ns.length > 0, blockFrame.width > 0, blockFrame.height > 0 else { return [] }
        guard window.intersects(blockFrame) else { return [] }
        let clipped = blockFrame.intersection(window)
        return clipped.isEmpty ? [] : [clipped]
    }

    static func lineRects(for ns: NSRange, in block: Block) -> [CGRect] {
        let rects = AXInline.lineRects(for: ns, in: block.element).filter { !$0.isEmpty }
        if !rects.isEmpty { return rects }
        // 兜底：AXBoundsForRange 给不出矩形时（WebKit 常见），退回元素自身的 AXFrame；
        // 再读不到就往上找一层非零尺寸的祖先。没有这一步，Mail 里就是「有建议、rect=0」。
        let own = frame(block.element)
        if own.width > 0, own.height > 0 { return [own] }
        var cur: AXUIElement? = block.element
        for _ in 0..<4 {
            guard let c = cur else { break }
            var raw: CFTypeRef?
            guard AXUIElementCopyAttributeValue(c, kAXParentAttribute as CFString, &raw) == .success,
                  let parent = raw, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            let p = parent as! AXUIElement
            let f = frame(p)
            if f.width > 0, f.height > 0, f.width < 4000, f.height < 3000 { return [f] }
            cur = p
        }
        return []
    }

    /// 替换计划（纯函数，不碰 AX）：越界/空替换一律拒绝，返回替换后的块文本。
    /// 抽出来的理由：写回逻辑的正确性必须能在没有真宿主的情况下断言（WebKit 宿主取证要真人）。
    static func planReplace(in text: String, range: NSRange, with newText: String) -> String? {
        let ns = text as NSString
        guard range.location >= 0, range.length >= 0 else { return nil }
        guard range.location + range.length <= ns.length else { return nil }
        guard !newText.isEmpty else { return nil }
        return ns.replacingCharacters(in: range, with: newText)
    }

    /// 块内替换（写回：选中块内 range → 写 AXSelectedText，保留撤销栈）
    static func replace(range: NSRange, with newText: String, in block: Block) -> Bool {
        Audit.write("WebText.replace")   // 只读自证：往 WebKit 正文写，一次都算
        // 先过纯函数这关：越界/空替换直接不写，避免把块写成破坏状态
        guard planReplace(in: block.text, range: range, with: newText) != nil else { return false }
        guard let v = axRangeValue(range.location, range.length) else { return false }
        let selErr = AXUIElementSetAttributeValue(block.element, kAXSelectedTextRangeAttribute as CFString, v)
        guard selErr == .success else { return false }
        let writeErr = AXUIElementSetAttributeValue(block.element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef)
        return writeErr == .success
    }
}
