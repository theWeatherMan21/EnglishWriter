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
    static func blocks(of body: AXUIElement) -> [Block] {
        var out: [Block] = []
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth > 0 else { return }
            for c in attrChildren(el) {
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

    /// 文本框是不是 WebKit 形态
    static func isWebBody(_ el: AXUIElement) -> Bool {
        (attrString(el, kAXRoleAttribute as String) ?? "") == "AXWebArea"
    }

    /// 在窗口里找正文容器：优先 AXWebArea，其次最大的 AXTextArea
    static func body(in window: AXUIElement) -> AXUIElement? {
        var web: AXUIElement?
        var area: (el: AXUIElement, size: CGFloat)?
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth > 0 else { return }
            for c in attrChildren(el) {
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
    static func lineRects(for ns: NSRange, in block: Block) -> [CGRect] {
        AXInline.lineRects(for: ns, in: block.element)
    }

    /// 块内替换（写回：选中块内 range → 写 AXSelectedText，保留撤销栈）
    static func replace(range: NSRange, with newText: String, in block: Block) -> Bool {
        guard let v = axRangeValue(range.location, range.length) else { return false }
        let selErr = AXUIElementSetAttributeValue(block.element, kAXSelectedTextRangeAttribute as CFString, v)
        guard selErr == .success else { return false }
        let writeErr = AXUIElementSetAttributeValue(block.element, kAXSelectedTextAttribute as CFString, newText as CFTypeRef)
        return writeErr == .success
    }
}
