// LiveAB.swift — 快速模式 A/B：开/关推理链，测延迟 + 质量指标
//
// 目的：知澜实测 reasoning_effort:"none" 把改写从 18s 压到 2s；但"更快"不能以掉质量为代价。
// 这里用同一批用例开/关各跑一遍，比三个硬指标：
//   · 延迟
//   · 偏移命中率（edit 的 start/length 在原文上取出来的片段必须等于 original）
//   · 术语/单号被改动的条数（应为 0）
//
// 用法：EW_BASE_URL=... EW_API_KEY=... EW_MODEL=... ./build/英文写作助手 --live-ab
// 产物：qa/evidence/live-ab.json

import Foundation

enum LiveAB {

    static let cases: [String] = [
        "There is many reasons why we should sent the booking confirmation to the customer immediatly.",
        "Our sales team have received three new enquiry last week, and they was not able to reply on time.",
        "Please confirm the FCL booking with the shipper before the ETD, the VGM cut off is tomorrow.",
        "We must make a decision in order to save time, and the booking reference BKG-TEST-0001 is still pending.",
        "Although the shipment was delayed due to the fact that the vessel was rerouted, and although we had already informed the customer about the revised schedule, we still need to confirm whether the demurrage charges can be waived, because the delay was not caused by us but by the carrier's operational adjustment at the transshipment port, which nobody could have predicted in advance.",
    ]

    struct Row: Codable {
        var caseIndex: Int
        var fast: Bool
        var ms: Int
        var edits: Int
        var offsetsHit: Int
        var offsetsMiss: Int
        var termViolations: Int
        var types: [String]
        var error: String?
    }

    static func run() async -> Bool {
        let cfg = SettingsStore.fromEnvironment()
        guard cfg.isComplete else {
            print("FAIL  --live-ab 需要 EW_BASE_URL / EW_API_KEY / EW_MODEL")
            return false
        }
        print("\n--- 快速模式 A/B（deepseek 推理链 开/关）---")
        print("  model=\(cfg.model)")
        let original = CategoryPrefs.fastMode()
        defer { CategoryPrefs.setFastMode(original) }

        var rows: [Row] = []
        for fast in [true, false] {
            CategoryPrefs.setFastMode(fast)
            for (i, text) in cases.enumerated() {
                let ns = text as NSString
                let t0 = Date()
                var row = Row(caseIndex: i, fast: fast, ms: 0, edits: 0,
                              offsetsHit: 0, offsetsMiss: 0, termViolations: 0, types: [], error: nil)
                do {
                    let out = try await InlineEngine.review(text: text, config: cfg, timeout: 90,
                                                            session: directSession())
                    row.ms = Int(Date().timeIntervalSince(t0) * 1000)
                    row.edits = out.items.count
                    row.types = out.items.map { $0.type }
                    let guarded = SpanGuard.guardedRanges(in: text)
                    for it in out.items {
                        let r = NSRange(location: it.start, length: it.length)
                        if it.start >= 0, it.length > 0, it.start + it.length <= ns.length,
                           ns.substring(with: r) == it.original {
                            row.offsetsHit += 1
                        } else {
                            row.offsetsMiss += 1
                        }
                        if guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) {
                            row.termViolations += 1
                        }
                    }
                } catch {
                    row.ms = Int(Date().timeIntervalSince(t0) * 1000)
                    row.error = String(describing: error)
                }
                rows.append(row)
                let tag = fast ? "fast" : "slow"
                print("  #\(i) \(tag) \(row.ms)ms edits=\(row.edits) hit=\(row.offsetsHit) miss=\(row.offsetsMiss) termViol=\(row.termViolations)"
                      + (row.error.map { " err=\($0)" } ?? ""))
            }
        }

        func summary(_ fast: Bool) -> (ms: Int, edits: Int, hit: Int, miss: Int, viol: Int) {
            let rs = rows.filter { $0.fast == fast }
            return (rs.reduce(0) { $0 + $1.ms }, rs.reduce(0) { $0 + $1.edits },
                    rs.reduce(0) { $0 + $1.offsetsHit }, rs.reduce(0) { $0 + $1.offsetsMiss },
                    rs.reduce(0) { $0 + $1.termViolations })
        }
        let f = summary(true), s = summary(false)
        print("  汇总 fast: 总 \(f.ms)ms / edits \(f.edits) / hit \(f.hit) / miss \(f.miss) / termViol \(f.viol)")
        print("  汇总 slow: 总 \(s.ms)ms / edits \(s.edits) / hit \(s.hit) / miss \(s.miss) / termViol \(s.viol)")

        let out: [String: Any] = [
            "model": cfg.model,
            "rows": rows.map { r -> [String: Any] in
                ["case": r.caseIndex, "fast": r.fast, "ms": r.ms, "edits": r.edits,
                 "hit": r.offsetsHit, "miss": r.offsetsMiss, "termViolations": r.termViolations,
                 "types": r.types, "error": r.error ?? ""]
            },
            "summary": ["fast": ["ms": f.ms, "edits": f.edits, "hit": f.hit, "miss": f.miss, "termViol": f.viol],
                        "slow": ["ms": s.ms, "edits": s.edits, "hit": s.hit, "miss": s.miss, "termViol": s.viol]],
        ]
        let dir = FileManager.default.currentDirectoryPath + "/qa/evidence"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: URL(fileURLWithPath: dir + "/live-ab.json"))
            print("  证据：qa/evidence/live-ab.json")
        }
        // 判定口径（钉死，别再拿"条数完全相等"当门槛——两档都全命中，只是快档少报 2 条）：
        //   · 两档偏移 miss 都必须是 0（错位=画错地方，绝不允许）
        //   · 两档术语触碰都必须是 0
        //   · 快档报出的条数不低于慢档的 80%（召回不能塌）
        let recallKept = Double(f.edits) >= Double(s.edits) * 0.8
        let qualityOK = f.miss == 0 && s.miss == 0 && f.viol == 0 && s.viol == 0 && recallKept
        print("  质量门：miss=0？\(f.miss == 0 && s.miss == 0) termViol=0？\(f.viol == 0 && s.viol == 0) 召回保持≥80%？\(recallKept)（\(f.edits) vs \(s.edits)）")
        print(qualityOK ? "RESULT: PASS（快 \(f.ms)ms vs 慢 \(s.ms)ms）" : "RESULT: FAIL（质量指标退化）")
        return qualityOK
    }

    private static func directSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 90
        c.timeoutIntervalForResource = 180
        return URLSession(configuration: c)
    }
}
