// Demo.swift — M1 渲染器自测台（不依赖辅助功能授权、不依赖网络）
//
// 用途：用一个真实 NSTextView 承载一段含 5 处错误的英文，
//      用 MockDiff 的逐条 diff 走「字符 range → 视觉行矩形 → 覆盖窗口画线」全链路。
// 证据：控制台打印每条错误的屏幕矩形；--shot 输出截图文件。
//
// 这条链路和真实 AX 路径共用同一个渲染器（UnderlineOverlay / UnderlineCanvas），
// 差别只在矩形来源：这里来自 NSLayoutManager，线上来自 AXBoundsForRange。

import AppKit

@MainActor
final class DemoController: NSObject, NSWindowDelegate {
    private var window: NSWindow!
    private var textView: NSTextView!
    private let overlay = UnderlineOverlay()
    private var items: [DiffItem] = []
    private var exitAfterShot = false
    private var shotPath: String?

    struct DemoOptions {
        var shotPath: String?
        var selfCheckOnly = false
        var snapshotPath: String?      // 离线合成快照（不依赖解锁/屏幕）
        var axSelfCheck = false        // AX 矩形 vs 排版矩形交叉校验
        var width: CGFloat = 760
        var fontSize: CGFloat = 14
    }

    func run(_ opts: DemoOptions) -> Int32 {
        shotPath = opts.shotPath
        exitAfterShot = opts.shotPath != nil
        buildWindow(opts)

        let text = MockDiff.paragraph
        textView.string = text
        let all = MockDiff.items(for: text)
        items = all

        // 强制布局，保证 layoutManager 有字形几何
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        window.displayIfNeeded()

        let specs = computeSpecs()
        overlay.render(specs)

        print("── M1 渲染自测 ──────────────────────────")
        print("文本长度(UTF-16) = \((text as NSString).length) 条数 = \(items.count)")
        for (i, it) in items.enumerated() {
            print(String(format: "edit#%d %-8s 「%@」→「%@」 @%d+%d",
                         i, (it.kind.rawValue as NSString).utf8String!, it.original,
                         it.replacement, it.start, it.length))
        }
        print("── 屏幕矩形（全局坐标，左上原点）──")
        for s in specs {
            print(String(format: "  [%@] id=%d x=%.1f y=%.1f w=%.1f h=%.1f",
                         s.kind.rawValue, s.itemID, s.rect.minX, s.rect.minY,
                         s.rect.width, s.rect.height))
        }
        var ok = selfCheck(specs)
        print("── 断言：每条错误至少 1 个矩形、矩形在窗口内、同一错误内矩形按 x 递增 ──")
        print(ok ? "RESULT: PASS" : "RESULT: FAIL")

        if opts.axSelfCheck {
            ok = axCrossCheck(layoutSpecs: specs) && ok
        }

        if let path = opts.snapshotPath {
            let saved = exportSnapshot(to: path)
            print(saved ? "SNAPSHOT: \(path)" : "SNAPSHOT: FAILED")
            ok = saved && ok
        }

        if opts.selfCheckOnly { return ok ? 0 : 1 }
        if opts.snapshotPath != nil { return ok ? 0 : 1 }
        if opts.axSelfCheck && opts.shotPath == nil { return ok ? 0 : 1 }

        if let path = shotPath {
            let winRect = ScreenGeom.toQuartz(window.frame)
            // 本机 screencapture -R 不可用（could not create image from rect）：
            // 先全屏抓，再用 sips 裁窗口区域。裁切基于点=像素（Retina 缩放在 sips 前先归一）。
            let tmp = NSTemporaryDirectory() + "ew-demo-full.png"
            let cmd = """
            caffeinate -u -t 2; sleep 0.4; screencapture -x \(tmp) && \
            sips -c \(Int(winRect.height)) \(Int(winRect.width)) \
                 --cropOffset \(Int(winRect.minY)) \(Int(winRect.minX)) \
                 \(tmp) --out \(path) >/dev/null && rm -f \(tmp)
            """
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                _ = self.shell(cmd)
                print("SHOT: \(path)")
                print("SHOT_REGION: x=\(Int(winRect.minX)) y=\(Int(winRect.minY)) w=\(Int(winRect.width)) h=\(Int(winRect.height))")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }
            }
        }
        return ok ? 0 : 1
    }

    // MARK: 窗口

    private func buildWindow(_ opts: DemoOptions) {
        let rect = NSRect(x: 0, y: 0, width: opts.width, height: 320)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "英文写作助手 · M1 行内下划线自测"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor.textBackgroundColor
        window.delegate = self
        window.center()

        let scroll = NSScrollView(frame: rect)
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor.textBackgroundColor
        scroll.autoresizingMask = [.width, .height]

        let tv = NSTextView(frame: rect)
        tv.isEditable = true
        tv.isRichText = false
        tv.font = NSFont.systemFont(ofSize: opts.fontSize)
        tv.textContainerInset = NSSize(width: 18, height: 18)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: rect.width, height: .greatestFiniteMagnitude)
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        tv.allowsUndo = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor.textBackgroundColor
        tv.insertionPointColor = .systemBlue
        scroll.documentView = tv
        textView = tv

        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ n: Notification) { NSApp.terminate(nil) }

    // MARK: 字符 range → 视觉行矩形 → 屏幕矩形

    private func computeSpecs() -> [UnderlineSpec] {
        var specs: [UnderlineSpec] = []
        for (idx, it) in items.enumerated() {
            let lineRects = rects(forCharacterRange: it.utf16Range)
            for r in lineRects {
                specs.append(UnderlineSpec(rect: r, kind: it.kind, itemID: idx))
            }
        }
        return specs
    }

    /// enumerateEnclosingRects 天然按视觉行拆分（= Grammarly 的 HighlightRects）
    private func rects(forCharacterRange ns: NSRange) -> [CGRect] {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return [] }
        let glyphRange = lm.glyphRange(forCharacterRange: ns, actualCharacterRange: nil)
        var lineRects: [NSRect] = []
        lm.enumerateEnclosingRects(forGlyphRange: glyphRange,
                                   withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                   in: tc) { rect, _ in
            lineRects.append(rect)
        }
        let origin = textView.textContainerOrigin
        return lineRects.map { r in
            // 文本容器坐标 → 视图坐标 → 窗口坐标 → 屏幕 AppKit → Quartz
            let inView = r.offsetBy(dx: origin.x, dy: origin.y)
            let inWindow = textView.convert(inView, to: nil)
            let inScreen = window.convertToScreen(inWindow)
            return ScreenGeom.toQuartz(inScreen)
        }
    }

    // MARK: 断言

    private func selfCheck(_ specs: [UnderlineSpec]) -> Bool {
        var ok = true
        let winRect = ScreenGeom.toQuartz(window.frame)
        for (i, it) in items.enumerated() {
            let mine = specs.filter { $0.itemID == i }
            if mine.isEmpty {
                print("  FAIL edit#\(i) 没有矩形")
                ok = false
                continue
            }
            for s in mine {
                if !winRect.insetBy(dx: -2, dy: -2).contains(s.rect.origin) {
                    print(String(format: "  FAIL edit#%d 矩形越出窗口 (%.1f,%.1f)", i, s.rect.minX, s.rect.minY))
                    ok = false
                }
                if s.rect.width <= 0 || s.rect.height <= 0 {
                    print("  FAIL edit#\(i) 矩形零尺寸"); ok = false
                }
            }
            // 同一错误跨行时：先出现的行 y 更小
            let ys = mine.map(\.rect.minY)
            if ys != ys.sorted() {
                print("  FAIL edit#\(i) 行顺序不对 \(ys)"); ok = false
            }
        }
        return ok
    }

    // MARK: 离线合成快照（不依赖解锁/屏幕，走同一套 canvas.draw）

    private func exportSnapshot(to path: String) -> Bool {
        guard let content = window.contentView else { return false }
        let size = content.bounds.size
        let contentQuartz = ScreenGeom.toQuartz(window.convertToScreen(content.convert(content.bounds, to: nil)))

        // 1) 文本视图本体：走 PDF（锁屏状态下 cacheDisplay 拿到的是黑图，PDF 走的是绘制路径）
        content.layoutSubtreeIfNeeded()
        let pdfData = content.dataWithPDF(inside: content.bounds)
        let tmpDir = NSTemporaryDirectory()
        let pdfPath = tmpDir + "ew-demo-text.pdf"
        let pngPath = tmpDir + "ew-demo-text.png"
        let scale = max(window.backingScaleFactor, 2)
        guard (try? pdfData.write(to: URL(fileURLWithPath: pdfPath))) != nil else { return false }
        let px = Int(size.width * scale)
        _ = shell("sips -s format png --resampleWidth \(px) \(pdfPath) --out \(pngPath) >/dev/null 2>&1")
        guard let textRep = NSBitmapImageRep(data: (try? Data(contentsOf: URL(fileURLWithPath: pngPath))) ?? Data()) else { return false }

        // 2) 覆盖层：直接用同一个 UnderlinePainter 画进合成上下文（不经过 view 缓存，避免不透明底遮挡）
        let overlay = items.enumerated().flatMap { idx, it in
            rects(forCharacterRange: it.utf16Range).map { r in
                UnderlineSpec(rect: r.offsetBy(dx: -contentQuartz.minX, dy: -contentQuartz.minY),
                              kind: it.kind, itemID: idx)
            }
        }

        // 3) 合成
        print("── 快照本地矩形（相对内容区，左上原点；内容区 size=\(size)，Quartz 原点=(\(contentQuartz.minX),\(contentQuartz.minY))）──")
        for s in overlay {
            print(String(format: "  [%@] id=%d x=%.1f y=%.1f w=%.1f h=%.1f",
                         s.kind.rawValue, s.itemID, s.rect.minX, s.rect.minY, s.rect.width, s.rect.height))
        }
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)

        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        textRep.draw(in: NSRect(origin: .zero, size: size))
        // UnderlinePainter 期望 y 向下（左上原点），这里把画布翻成左上原点再画
        let cg = NSGraphicsContext.current!.cgContext
        cg.saveGState()
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        for s in overlay { UnderlinePainter.stroke(s.rect, s.kind) }
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = out.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: AX 矩形 vs 排版矩形 交叉校验
    //
    // 用本 App 自己的窗口当靶子：AXBoundsForRange 算出来的矩形
    // 必须和 NSLayoutManager 的视觉行矩形落在同一位置（误差 ≤ 3pt）。
    // 这条通了，说明线上对 Mail 用的那段几何代码是对的。

    private func axCrossCheck(layoutSpecs: [UnderlineSpec]) -> Bool {
        let pid = getpid()
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        guard let el = axFindTextElement(appEl) else {
            print("── AX 交叉校验：找不到自身 AX 文本元素（本进程 AX 树未暴露）──")
            return false
        }
        guard let full = AXInline.fullText(of: el) else {
            print("── AX 交叉校验：AX 读不到文本内容 ──")
            return false
        }
        let axItems = DiffSanitize.clean(MockDiff.items(for: full), in: full)
        print("── AX 交叉校验（AXBoundsForRange vs NSLayoutManager）──")
        print("AX 读回文本长度 = \((full as NSString).length)（期望 \((MockDiff.paragraph as NSString).length)）条数 = \(axItems.count)")
        guard !axItems.isEmpty else { return false }

        var ok = true
        for (i, it) in axItems.enumerated() {
            let axRects = AXInline.lineRects(for: it.utf16Range, in: el)
            let layoutRects = rects(forCharacterRange: it.utf16Range)
            guard !axRects.isEmpty, !layoutRects.isEmpty else {
                print("  FAIL edit#\(i) AX=\(axRects.count) 行 排版=\(layoutRects.count) 行")
                ok = false; continue
            }
            for (a, l) in zip(axRects, layoutRects) {
                let dx = abs(a.midX - l.midX), dy = abs(a.midY - l.midY)
                let dw = abs(a.width - l.width), dh = abs(a.height - l.height)
                let pass = dx <= 3 && dy <= 3 && dw <= 4 && dh <= 4
                print(String(format: "  %@ edit#%d AX(%.1f,%.1f,%.1f,%.1f) 排版(%.1f,%.1f,%.1f,%.1f) Δ=(%.1f,%.1f,%.1f,%.1f)",
                             pass ? "OK  " : "FAIL", i,
                             a.minX, a.minY, a.width, a.height,
                             l.minX, l.minY, l.width, l.height, dx, dy, dw, dh))
                if !pass { ok = false }
            }
        }
        print(ok ? "AX_CROSSCHECK: PASS" : "AX_CROSSCHECK: FAIL")
        return ok
    }

    private func axFindTextElement(_ appEl: AXUIElement) -> AXUIElement? {
        var out: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &out)
        print("  AX windows 读取 err=\(e.rawValue) 元素=\((out as? [AXUIElement])?.count ?? -1)")
        if e == .success, let wins = out as? [AXUIElement] {
            for w in wins {
                for d in AXInline.descendants(w, depth: 8) {
                    let role = attrString(d, kAXRoleAttribute as String) ?? ""
                    if role == "AXTextArea" || role == "AXTextField" {
                        if attrString(d, kAXValueAttribute as String) != nil { return d }
                    }
                }
            }
        }
        return AXInline.focusedElement(pid: getpid())
    }

    private func shell(_ cmd: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}
