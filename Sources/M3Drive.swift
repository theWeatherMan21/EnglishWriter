// M3Drive.swift — M3 链路的一次完整「命中 → 弹出 → 接受 → 撤销（+ 忽略）」离线驱动
//
// 为什么要有它：DoD 要的是「行级日志证明链路真实走到」，不是一段自述。
// 这里走的是产品里同一批函数（HoverCoordinator.hitTest / M3Flow.placement / CardWeb.payload /
// M3Flow.accept / M3Flow.undo / IgnoreStore），只是文档换成内存 BufferDoc——
// 所以不需要真窗口、不抢焦点、不上屏（静默红线），也能把每一步的坐标与文本打出来。
//
// 入口两个：
//   ./英文写作助手 --m3-drive            人读的行级日志（默认写 out/m3-drive.log）
//   --selftest --m3                      断言版（SelfTest 里调 run()，PASS/FAIL 计入汇总）

import AppKit

enum M3Drive {

    struct Result {
        var pass = 0
        var fail = 0
        var lines: [String] = []
    }

    /// 一次完整链路；out != nil 时把行级日志落盘
    @discardableResult
    static func run(out: String? = nil, verbose: Bool = true) -> Result {
        var r = Result()
        let t0 = Date()
        func stamp() -> String {
            String(format: "%.3fs", Date().timeIntervalSince(t0))
        }
        func line(_ tag: String, _ msg: String) {
            let l = "\(stamp()) [\(tag)] \(msg)"
            r.lines.append(l)
            if verbose { print(l) }
        }
        func check(_ name: String, _ cond: Bool, _ detail: String) {
            if cond {
                r.pass += 1
                line("PASS", "\(name) — \(detail)")
            } else {
                r.fail += 1
                line("FAIL", "\(name) — \(detail)")
            }
        }

        // ── 0) 固定夹具：一段真会犯的错句 + 逐条 diff
        let text = "There is many reasons why we should sent it immediatly."
        let items = MockDiff.items(for: text)
        line("fixture", "text=\"\(text)\" utf16=\((text as NSString).length) items=\(items.count)")
        for (i, it) in items.enumerated() {
            line("diff", "idx=\(i) start=\(it.start) len=\(it.length) \"\(it.original)\"→\"\(it.replacement)\" type=\(it.type)")
        }
        check("夹具三条", items.count == 3, "MockDiff 出 \(items.count) 条")

        // ── 1) 命中：矩形来自 M1 的 HighlightRects（全局屏幕坐标、左上原点）
        //     离线用固定几何，真机上是 AXBoundsForRange 折算后的同一种 rect
        func rectFor(_ i: Int) -> CGRect {
            CGRect(x: 120 + CGFloat(i) * 180, y: 240, width: 96, height: 14)
        }
        let specs = items.enumerated().map { UnderlineSpec(rect: rectFor($0.offset), kind: $0.element.kind, itemID: $0.offset) }
        for s in specs { line("rect", "item=\(s.itemID) rect=(\(Int(s.rect.minX)),\(Int(s.rect.minY)),\(Int(s.rect.width)),\(Int(s.rect.height)))") }

        let hoverPoint = CGPoint(x: rectFor(2).midX, y: rectFor(2).midY)
        let hit = HoverCoordinator.hitTest(specs, at: hoverPoint)
        line("hover", "cursor=(\(Int(hoverPoint.x)),\(Int(hoverPoint.y))) → hit=\(hit.map { "item\($0.itemID) \"\(items[$0.itemID].original)\"" } ?? "nil")")
        check("命中第三条", hit?.itemID == 2,
              "点 (\(Int(hoverPoint.x)),\(Int(hoverPoint.y))) 落在 rect#2 上")

        let missPoint = CGPoint(x: rectFor(2).midX, y: rectFor(2).maxY + 20)
        let miss = HoverCoordinator.hitTest(specs, at: missPoint)
        line("hover", "cursor=(\(Int(missPoint.x)),\(Int(missPoint.y))) → hit=\(miss == nil ? "nil" : "item\(miss!.itemID)")")
        check("空白处不命中", miss == nil, "矩形下方 20pt 处不弹卡片")

        // ── 2) 卡片：内容 = 类别色标 / 原句 / 建议 / 一句中文理由 / 接受·忽略
        let idx = hit?.itemID ?? 2
        let item = items[idx]
        let anchor = rectFor(idx)
        let sentence = "There is many reasons why we should sent it immediatly."
        let errRange = (sentence as NSString).range(of: item.original)
        let ns = sentence as NSString
        let before = errRange.location != NSNotFound
            ? ns.substring(to: errRange.location).split(separator: " ").suffix(5).joined(separator: " ")
            : ""
        let after = errRange.location != NSNotFound
            ? ns.substring(from: NSMaxRange(errRange)).split(separator: " ").prefix(5).joined(separator: " ")
            : ""
        let reason = ReasonText.zh(type: item.type, reason: item.reason, original: item.original, replacement: item.replacement)
        let payload = CardWeb.payload(category: item.kind.categoryLine,
                                      color: "#EE1437",
                                      before: before.isEmpty ? "" : "…" + before + " ",
                                      original: item.original,
                                      replacement: item.replacement,
                                      after: after.isEmpty ? "" : " " + after + "…",
                                      reason: reason, allowDict: true, canRewrite: false)
        line("card", "category=\(payload["category"] ?? "-") color=\(payload["color"] ?? "-")")
        line("card", "原句=\(payload["before"] ?? "")[\(payload["original"] ?? "")]\(payload["after"] ?? "")")
        line("card", "建议=\(payload["replacement"] ?? "") 理由=\(payload["reason"] ?? "")")
        line("card", "buttons=接受,忽略 (+加入词典/本次忽略/···)")
        check("卡片带中文理由", ReasonText.hasCJK(reason) && !reason.isEmpty, "reason=\"\(reason)\"")
        check("卡片字段齐全", payload["original"] as? String == item.original
                && payload["replacement"] as? String == item.replacement
                && payload["reason"] as? String == reason, "原句/建议/理由三项非空且与条目一致")

        // 尺寸 + 就近弹出（下方放不下翻到上方）
        let cardSize = CGSize(width: CardWeb.cardWidth, height: 132)
        let screenVisible = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let below = M3Flow.placement(anchor: anchor, size: cardSize, visible: screenVisible)
        line("card", "frame=(\(Int(below.minX)),\(Int(below.minY)),\(Int(below.width)),\(Int(below.height))) anchor=(\(Int(anchor.minX)),\(Int(anchor.minY))) 屏幕=(0,0,1512,982)")
        check("卡片贴在矩形下方", below.minY == anchor.maxY + 4, "anchor.maxY=\(Int(anchor.maxY)) frame.minY=\(Int(below.minY))")

        let lowAnchor = CGRect(x: 1300, y: 960, width: 96, height: 14)
        let flipped = M3Flow.placement(anchor: lowAnchor, size: cardSize, visible: screenVisible)
        line("card", "翻转用例 anchor=(1300,960) → frame=(\(Int(flipped.minX)),\(Int(flipped.minY)),\(Int(flipped.width)),\(Int(flipped.height)))")
        check("屏幕底边自动翻转", flipped.maxY <= lowAnchor.minY + 0.5, "frame.maxY=\(Int(flipped.maxY)) ≤ anchor.minY=\(Int(lowAnchor.minY))")
        check("屏幕右边自动夹住", flipped.maxX <= screenVisible.maxX, "frame.maxX=\(Int(flipped.maxX)) ≤ 1512")

        // ── 3) 接受：只替换该一条 range，走 applyEdits(only:)
        let stack = M3UndoStack()
        let doc = BufferDoc(text, pid: 4242)
        let out1 = M3Flow.accept(items: items, only: idx, in: doc, stack: stack)
        let expected = "There is many reasons why we should sent it immediately."
        line("accept", "applyEdits(only: \(idx)) → \"\(doc.fullText)\"")
        line("accept", "栈 depth=\(stack.count) top=\(stack.top?.describe ?? "-")")
        check("接受后文本等于期望串", doc.fullText == expected, "实际=\"\(doc.fullText)\"")
        check("同段其它建议未被动", doc.fullText.contains("There is many") && doc.fullText.contains("should sent"),
              "「There is many」「should sent」原样保留")
        check("撤销栈记了 pid+range+快照", stack.top.map { $0.pid == 4242 && $0.range.length == item.length && $0.snapshot == text } ?? false,
              stack.top?.describe ?? "栈为空")

        // ── 4) 撤销：执行后回到原文
        let undone = M3Flow.undo(stack: stack)
        line("undo", "菜单「撤销上次替换」 → \(undone.ok) \"\(doc.fullText)\"")
        check("撤销后回到原文", undone.ok && doc.fullText == text, "实际=\"\(doc.fullText)\"")
        check("撤销栈已出栈", stack.count == 0, "depth=\(stack.count)")

        // ── 5) 忽略：该条记入忽略集合，后续检查结果里过滤掉
        let savedRules = SettingsStore.store.array(forKey: "ignore.rules") as? [[String]]
        let savedHashes = SettingsStore.store.array(forKey: "ignore.hashes") as? [String]
        let hash = M3Ignore.hash(original: item.original, replacement: item.replacement)
        _ = IgnoreStore.shared.ignore(original: item.original, replacement: item.replacement)
        let kept = M3Ignore.filter(items) { IgnoreStore.shared.isIgnored(original: $0.original, replacement: $0.replacement) }
        line("ignore", "hash=\(hash) 写入忽略集合 → 再查一次：\(items.count) 条 → \(kept.count) 条")
        check("忽略后该条不再返回", kept.count == items.count - 1 && !kept.contains { $0.original == item.original },
              "剩 \(kept.map(\.original))")
        check("忽略按文本 hash 命中", IgnoreStore.shared.isIgnored(hash: hash), "isIgnored(hash:) = true")
        check("hash 稳定且区分条目", hash == M3Ignore.hash(original: item.original, replacement: item.replacement)
                && hash != M3Ignore.hash(original: "sent", replacement: "send"), "同条同哈希、异条不同哈希")
        // 清理：把落盘规则写回原状（自测不许污染用户设置）
        if let savedRules = savedRules { SettingsStore.store.set(savedRules, forKey: "ignore.rules") }
        else { SettingsStore.store.removeObject(forKey: "ignore.rules") }
        if let savedHashes = savedHashes { SettingsStore.store.set(savedHashes, forKey: "ignore.hashes") }
        else { SettingsStore.store.removeObject(forKey: "ignore.hashes") }
        IgnoreStore.shared.clearSession()
        IgnoreStore.shared.reloadForTesting()

        // ── 6) 落盘
        if let path = out {
            let header = "# M3 链路驱动 · \(AppLog.stamp()) · fixture=\u{201C}\(text)\u{201D}\n"
            let body = header + r.lines.joined(separator: "\n") + "\n# PASS \(r.pass) / FAIL \(r.fail)\n"
            let url = URL(fileURLWithPath: path)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? body.write(to: url, atomically: true, encoding: .utf8)
            print("LOG: \(path)")
        }
        AppLog.info("m3", "drive pass=\(r.pass) fail=\(r.fail) hit=item\(idx) undo=\(undone.ok)")
        return r
    }
}
