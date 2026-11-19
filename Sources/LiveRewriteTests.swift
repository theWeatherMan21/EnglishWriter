// LiveRewriteTests.swift — 真模型跑改写 / 语气（唯一能证伪桩断言的一层）
//
// 桩断言全绿 != 真模型能跑：真实返回会带 markdown 围栏、少字段、整段重写偷懒、把术语改掉。
// 这里只做一件事：拿真实 key 跑一遍，把「原始片段 / 解析结果 / 被护栏丢掉的条目」照实打出来。
//
// 用法（key 只走环境变量，不落盘、不进设置）：
//   EW_BASE_URL=... EW_API_KEY=... EW_MODEL=... ./build/英文写作助手 --live-rewrite
//   EW_BASE_URL=... EW_API_KEY=... EW_MODEL=... ./build/英文写作助手 --live-tone

import Foundation

enum LiveRewriteTests {

    /// 单据号用「不撞箱号形态」的仿真编号（pre-commit 会把「4字母+7数字」当成真实单号拦下；
    /// 箱号保护本身由离线测试覆盖：规则·不碰箱号 / 拼写·保护区间零误报）
    static let ref = "BKG-TEST-0001"

    static var passage: String {
        "We must make a decision in order to save time, and the FCL booking " + ref + " is still pending."
    }

    static func runRewrite() async -> Bool {
        print("\n--- 真模型·改写建议（--live-rewrite）---")
        return await run(labels: Rewrite.defaultLabels, tag: "rewrite")
    }

    static func runTone() async -> Bool {
        print("\n--- 真模型·语气（--live-tone）---")
        return await run(labels: Rewrite.toneLabels, tag: "tone")
    }

    /// 直连 session：URLSession 默认会走系统代理（Clash），实测把它指到代理上就 20s 超时；
    /// 这里只对这个 session 关代理，不动系统设置（项目内兜底）。
    private static func directSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 90
        return URLSession(configuration: cfg)
    }

    /// 五句业务英文 × 3 轮（知澜的口径：5/5 · 5/5 · ms 每轮）
    private static let batch: [String] = [
        "I have send the report immediatly and it is very good.",
        "Please kindly advise us the vessel schedule at your earliest convenience.",
        "We was late because there is many problems with the booking.",
        "The cargo was load yesterday and the free time is 10 days.",
        "Looking forward to hear from you about the B/L copy.",
    ]

    static func runBatch(labels: [String], tag: String, rounds: Int = 3) async -> Bool {
        var cfg = SettingsStore.fromEnvironment()
        if !cfg.isComplete { cfg = SettingsStore.load() }
        guard cfg.isComplete else {
            print("FAIL  live-" + tag + " 配置缺失（env 与设置面板都为空）")
            return false
        }
        print("  endpoint=" + cfg.baseURL + " model=" + cfg.model)
        var allOK = true
        for r in 1...rounds {
            var okCount = 0, distinct = 0, msTotal = 0
            for text in batch {
                let t0 = Date()
                let cands = (try? await Rewrite.suggest(segment: text, config: cfg, labels: labels,
                                                        timeout: 45, session: Self.directSession())) ?? []
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                msTotal += ms
                let applied = cands.map { $0.appliedText(to: text) }
                if !applied.isEmpty && applied.contains(where: { $0 != text }) { okCount += 1 }
                if Set(applied).count == applied.count && applied.count > 0 { distinct += 1 }
            }
            let avg = msTotal / max(1, batch.count)
            let pass = okCount == batch.count && distinct == batch.count
            print("  轮\(r)  \(okCount)/\(batch.count) 有候选 · \(distinct)/\(batch.count) 不重复 · 平均 \(avg)ms  \(pass ? "PASS" : "FAIL")")
            if !pass { allOK = false }
        }
        return allOK
    }

    private static func run(labels: [String], tag: String) async -> Bool {
        // 先看环境变量，没有再回落 App 自己的设置（爹地已经在设置面板配好了，
        // 验收不该每次都手拼三个 env）
        var cfg = SettingsStore.fromEnvironment()
        if !cfg.isComplete { cfg = SettingsStore.load() }
        guard cfg.isComplete else {
            print("FAIL  live-" + tag + " 配置缺失：env 与设置面板都没配（EW_BASE_URL / EW_API_KEY / EW_MODEL）")
            return false
        }
        print("  endpoint=" + cfg.baseURL + " model=" + cfg.model + " labels=" + labels.joined(separator: "/"))
        let t0 = Date()
        do {
            let out = try await Rewrite.suggestDetailed(segment: passage, config: cfg,
                                                        labels: labels, timeout: 45,
                                                        session: Self.directSession())
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let raw = out.raw
            let flat = raw.replacingOccurrences(of: "\n", with: " ")
            print("  耗时 " + String(ms) + "ms；原始响应 " + String(raw.count) + " 字")
            print("  原始片段：" + String(flat.prefix(400)))
            guard !out.candidates.isEmpty else {
                print("FAIL  解析出 0 个候选（原始响应见上）")
                return false
            }
            var allGood = true
            for c in out.candidates {
                let applied = c.appliedText(to: passage)
                print("  · [" + c.label + "] " + String(c.items.count) + " 条 → " + applied)
                if c.items.isEmpty { allGood = false }
                let whole = c.items.count == 1 && c.items[0].start == 0
                    && c.items[0].length == (passage as NSString).length
                if whole { print("    x 整段一条替换（应被拒）"); allGood = false }
                if applied == passage { print("    x 候选没有改变文本"); allGood = false }
                if applied.contains("BKG") && !applied.contains(ref) {
                    print("    x 箱号被改动"); allGood = false
                }
            }
            let distinct = Set(out.candidates.map { $0.label }).count
            if distinct < min(2, labels.count) {
                print("  x label 数量不对：" + out.candidates.map { $0.label }.joined(separator: ","))
                allGood = false
            }
            let ok = !out.candidates.isEmpty && allGood
            print(ok ? "RESULT: PASS（" + String(out.candidates.count) + " 个候选）" : "RESULT: FAIL")
            return ok
        } catch {
            print("FAIL  请求失败：" + String(describing: error))
            return false
        }
    }
}
