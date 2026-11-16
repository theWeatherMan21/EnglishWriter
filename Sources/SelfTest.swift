// SelfTest.swift — 无头自检：把 DoD 里能自动判定的部分全部跑成断言
// 用法：./英文写作助手 --selftest [--glossary] [--cjk] [--faults] [--live]
// 不带参数 = 跑全部离线项（不含 --live）

import Foundation

struct Fixture: Decodable {
    struct Case: Decodable {
        let id: String
        let text: String
        let badSuggestion: String
        let expect: String      // "drop" | "pass"
        let why: String
    }
    let cases: [Case]
    let live: [String]
}

enum SelfTest {
    static var pass = 0
    static var fail = 0
    static var lines: [String] = []

    static func ok(_ name: String, _ detail: String = "") {
        pass += 1
        let line = "PASS  \(name)\(detail.isEmpty ? "" : "  — \(detail)")"
        print(line); lines.append(line)
    }

    static func bad(_ name: String, _ detail: String) {
        fail += 1
        let line = "FAIL  \(name)  — \(detail)"
        print(line); lines.append(line)
    }

    static func run(_ argv: [String]) -> Int32 {
        let wantAll = !argv.contains("--glossary") && !argv.contains("--cjk") && !argv.contains("--faults") && !argv.contains("--live")
        print("=== 英文写作助手 selftest ===")

        if wantAll || argv.contains("--cjk") { cjkTests() }
        if wantAll || argv.contains("--glossary") { glossaryTests() }
        if wantAll || argv.contains("--faults") { faultTests() }
        if wantAll || argv.contains("--diff") { diffTests() }
        if argv.contains("--live") { liveTests() }
        if argv.contains("--live-diff") { liveDiffTests() }
        if argv.contains("--lt") { ltTests() }

        print("\n=== 汇总：PASS \(pass) / FAIL \(fail) ===")
        if let dir = ProcessInfo.processInfo.environment["EW_SELFTEST_OUT"] {
            try? lines.joined(separator: "\n").write(toFile: dir, atomically: true, encoding: .utf8)
        }
        return fail == 0 ? 0 : 1
    }

    // MARK: 语言门控

    static func cjkTests() {
        print("\n--- 语言门控（CJK 占比 > 0.40 → 不介入）---")
        let cases: [(String, String, Bool)] = [
            ("全中文", "麻烦确认一下这批货的船期和舱位", true),
            ("中文为主", "请确认 FCL 订舱的 ETD 和舱位情况", true),
            ("英文为主", "Please confirm the ETD of this FCL booking, 谢谢", false),
            ("纯英文", "Please confirm the ETD of this FCL booking", false),
            ("中文标点也算", "好的，收到。", true),
            ("空串", "", false),
            ("单字中文混长英文", "Our vessel departed Shanghai yesterday as planned, 好", false),
        ]
        for (name, text, expectSkip) in cases {
            let r = shouldSkipAsChinese(text)
            let ratio = String(format: "%.2f", cjkRatio(text))
            if r == expectSkip { ok("门控·\(name)", "ratio=\(ratio) skip=\(r)") }
            else { bad("门控·\(name)", "ratio=\(ratio) 期望 skip=\(expectSkip) 实际 \(r)") }
        }
    }

    // MARK: 术语硬闸

    static func glossaryTests() {
        print("\n--- 术语硬闸（建议改动术语 token → 丢弃）---")
        guard let fx = loadFixtures() else {
            bad("夹具加载", "fixtures/glossary.json 读不到")
            return
        }
        if fx.cases.count < 20 { bad("夹具数量", "只有 \(fx.cases.count) 条，DoD 要求 ≥20") }
        else { ok("夹具数量", "\(fx.cases.count) 条") }

        for c in fx.cases {
            let r = glossaryGate(original: c.text, suggestion: c.badSuggestion)
            let got = (r == .pass) ? "pass" : "drop"
            if got == c.expect {
                ok("硬闸·\(c.id)", "\(c.expect)（\(c.why)）")
            } else {
                bad("硬闸·\(c.id)", "期望 \(c.expect) 实际 \(got)（\(c.why)）")
            }
        }
        // 术语在原文与建议里都不动的正常改写必须放行
        let normal = glossaryGate(original: "The FCL cargo has been shipped, we needs the BL now.",
                                  suggestion: "The FCL cargo has been shipped; we need the BL now.")
        if normal == .pass { ok("硬闸·正常改写放行") } else { bad("硬闸·正常改写放行", "\(normal)") }
        // 无改动必须丢
        if case .drop = glossaryGate(original: "FCL cargo ok", suggestion: "FCL cargo ok") { ok("硬闸·无改动丢弃") }
        else { bad("硬闸·无改动丢弃", "没丢") }
    }

    // MARK: 失败态

    static func faultTests() {
        print("\n--- 失败态三条（含真实本地服务验证）---")
        // 1) 纯文案断言
        let httpMsg = ReviewFailure.http(500, "internal boom").userMessage
        if httpMsg.contains("HTTP 500") && httpMsg.contains("internal boom") { ok("文案·非200", httpMsg) }
        else { bad("文案·非200", httpMsg) }

        if parseSuggestionPayload("这不是 JSON") == nil { ok("解析·坏 JSON 返回 nil") }
        else { bad("解析·坏 JSON", "居然解析成功了") }
        let badJSONMsg = ReviewFailure.badJSON("<html>oops</html>").userMessage
        if badJSONMsg.contains("没按 JSON 回") { ok("文案·解析失败", badJSONMsg) }
        else { bad("文案·解析失败", badJSONMsg) }

        let toMsg = ReviewFailure.timeout.userMessage
        if toMsg.contains("15 秒") { ok("文案·超时", toMsg) }
        else { bad("文案·超时", toMsg) }

        // 围栏容错
        let fenced = "```json\n{\"original\":\"a\",\"suggestion\":\"b\",\"reason\":\"c\"}\n```"
        if parseSuggestionPayload(fenced)?.suggestion == "b" { ok("解析·围栏容忍") }
        else { bad("解析·围栏容忍", "解析不到") }

        // 2) 真实本地服务：非 200 + 真超时
        let port = 18731
        let timeoutPort = 18732
        let base = ProcessInfo.processInfo.environment["EW_FAULT_SERVER"] ?? ""
        guard !base.isEmpty else {
            print("SKIP  真实服务验证（未设 EW_FAULT_SERVER，由 selftest.sh 提供）")
            return
        }
        _ = port; _ = timeoutPort

        let badCfg = LLMConfig(baseURL: base, apiKey: "test", model: "test")
        let sem = DispatchSemaphore(value: 0)
        var gotHTTP: String?
        Engine.reviewT(text: "Hello world", config: badCfg, timeout: 3) { result in
            if case .failure(let f) = result { gotHTTP = (f as? ReviewFailure)?.userMessage ?? "\(f)" }
            sem.signal()
        }
        sem.wait()
        if let m = gotHTTP, m.contains("HTTP 500") { ok("真实·非200 映射", m) }
        else { bad("真实·非200 映射", gotHTTP ?? "无结果") }

        let hangCfg = LLMConfig(baseURL: base.replacingOccurrences(of: "/v1", with: "/hang/v1"), apiKey: "t", model: "t")
        let sem2 = DispatchSemaphore(value: 0)
        var gotTimeout: String?
        Engine.reviewT(text: "Hello world", config: hangCfg, timeout: 2) { result in
            if case .failure(let f) = result { gotTimeout = (f as? ReviewFailure)?.userMessage ?? "\(f)" }
            sem2.signal()
        }
        sem2.wait()
        if let m = gotTimeout, m.contains("15 秒") || m.contains("没回话") { ok("真实·超时映射", m) }
        else { bad("真实·超时映射", gotTimeout ?? "无结果") }
    }

    // MARK: 真接口

    static func liveTests() {
        print("\n--- 真接口（--live，走 EW_BASE_URL/EW_API_KEY/EW_MODEL）---")
        let cfg = SettingsStore.fromEnvironment()
        guard cfg.isComplete else {
            bad("live 配置", "EW_BASE_URL / EW_API_KEY / EW_MODEL 缺一项")
            return
        }
        guard let fx = loadFixtures() else { bad("live 夹具", "读不到"); return }
        var touched = 0
        var noChange = 0
        var changed = 0
        var checked = 0
        for (i, text) in fx.live.enumerated() {
            let sem = DispatchSemaphore(value: 0)
            var outcome: Result<ReviewOutcome, Error>?
            Engine.reviewT(text: text, config: cfg, timeout: 30) { outcome = $0; sem.signal() }
            sem.wait()
            checked += 1
            switch outcome {
            case .success(let out):
                let g = glossaryGate(original: text, suggestion: out.suggestion.suggestion)
                switch g {
                case .pass:
                    changed += 1
                    ok("live#\(i + 1)", "改动放行，耗时 \(String(format: "%.1f", out.elapsed))s")
                case .drop(let why) where why.hasPrefix("术语被改动"):
                    touched += 1
                    bad("live#\(i + 1)", "建议触碰术语 → \(why)")
                case .drop:
                    noChange += 1
                    ok("live#\(i + 1)", "模型未改动（不算误报）")
                }
            case .failure(let e):
                let msg = (e as? ReviewFailure)?.userMessage ?? "\(e)"
                bad("live#\(i + 1)", msg)
            case .none:
                bad("live#\(i + 1)", "无结果")
            }
        }
        print("\nlive 汇总：检查 \(checked) 条，有改动 \(changed)，未改动 \(noChange)，**术语被触碰 \(touched)**")
        if touched == 0 { ok("live·术语零误报", "\(checked) 条全部未触碰术语 token") }
        else { bad("live·术语零误报", "\(touched) 条触碰术语") }
        // 防「模型啥也不改也算过」的空转：至少 80% 的句子必须给出真实改动
        let need = Int((Double(checked) * 0.8).rounded())
        if changed >= need { ok("live·真的在改", "\(changed)/\(checked) 条给出真实改动（门槛 \(need)）") }
        else { bad("live·真的在改", "只有 \(changed)/\(checked) 条有改动（门槛 \(need)）") }
    }

    // MARK: 逐条 diff 契约（离线）

    static func diffTests() {
        print("\n--- 逐条 diff 契约（解析 / 定位修复 / 重叠丢弃）---")
        let text = "There is many reasons. We should sent it immediatly."

        // 1) 标准形态
        let good = """
        {"edits":[{"start":0,"length":13,"original":"There is many","replacement":"There are many","type":"grammar","reason":"复数主语"},{"start":44,"length":10,"original":"immediatly","replacement":"immediately","type":"spelling","reason":"拼写"}]}
        """
        if let items = DiffParse.parse(good) {
            let cleaned = DiffSanitize.clean(items, in: text)
            if cleaned.count == 2 { ok("diff·标准解析", "2 条") } else { bad("diff·标准解析", "只拿到 \(cleaned.count) 条") }
            if cleaned.first?.kind == .grammar && cleaned.last?.kind == .spelling { ok("diff·类型映射") }
            else { bad("diff·类型映射", "类型错") }
        } else { bad("diff·标准解析", "解析失败") }

        // 2) 裸数组 + 围栏
        let bare = "```json\n[{\"start\":0,\"length\":13,\"original\":\"There is many\",\"replacement\":\"There are many\",\"type\":\"grammar\",\"reason\":\"x\"}]\n```"
        if DiffParse.parse(bare)?.count == 1 { ok("diff·围栏裸数组") } else { bad("diff·围栏裸数组", "解析失败") }

        // 3) 偏移错位 → 按原文重新定位
        let wrongOffset = [DiffItem(start: 999, length: 10, original: "immediatly", replacement: "immediately", type: "spelling", reason: "x")]
        let repaired = DiffSanitize.clean(wrongOffset, in: text)
        if repaired.count == 1, repaired[0].start == 41 { ok("diff·偏移修复", "start=\(repaired.first?.start ?? -1)") }
        else { bad("diff·偏移修复", "\(repaired.map(\.start))") }

        // 4) 原文压根不存在 → 丢弃，绝不画错位置
        let ghost = [DiffItem(start: 0, length: 5, original: "zzzzz", replacement: "y", type: "grammar", reason: "x")]
        if DiffSanitize.clean(ghost, in: text).isEmpty { ok("diff·幽灵条目丢弃") }
        else { bad("diff·幽灵条目丢弃", "没丢") }

        // 5) 重叠 → 只留第一条
        let overlap = [
            DiffItem(start: 0, length: 13, original: "There is many", replacement: "There are many", type: "grammar", reason: "a"),
            DiffItem(start: 6, length: 4, original: "many", replacement: "much", type: "grammar", reason: "b"),
        ]
        if DiffSanitize.clean(overlap, in: text).count == 1 { ok("diff·重叠丢弃") }
        else { bad("diff·重叠丢弃", "重叠没处理") }

        // 6) 越界 → 丢弃
        let oob = [DiffItem(start: 900, length: 10, original: "xx", replacement: "y", type: "grammar", reason: "x")]
        if DiffSanitize.clean(oob, in: text).isEmpty { ok("diff·越界丢弃") }
        else { bad("diff·越界丢弃", "没丢") }

        // 7) 应用后文本正确
        let items = DiffSanitize.clean(DiffParse.parse(good) ?? [], in: text)
        let applied = applyEdits(items, to: text)
        if applied == "There are many reasons. We should sent it immediately." { ok("diff·应用结果", applied) }
        else { bad("diff·应用结果", applied) }
    }

    // MARK: 逐条 diff 契约（真接口）

    static func liveDiffTests() {
        print("\n--- 逐条 diff 真接口（--live-diff，走 EW_BASE_URL/EW_API_KEY/EW_MODEL）---")
        let cfg = SettingsStore.fromEnvironment()
        guard cfg.isComplete else { bad("live-diff 配置", "EW_BASE_URL / EW_API_KEY / EW_MODEL 缺一项"); return }
        let cases = [
            "There is many reasons why we should sent the booking confirmation to the customer immediatly.",
            "Our sales team have received three new enquiry last week, and they was not able to reply on time.",
            "Please confirm the FCL booking with the shipper before the ETD, the VGM cut off is tomorrow.",
            "Everything looks fine to me, thanks for the quick reply.",
        ]
        var total = 0, located = 0, touched = 0
        for (i, text) in cases.enumerated() {
            let sem = DispatchSemaphore(value: 0)
            var res: Result<InlineOutcome, Error>?
            Task.detached {
                do { res = .success(try await InlineEngine.review(text: text, config: cfg, timeout: 30)) }
                catch { res = .failure(error) }
                sem.signal()
            }
            sem.wait()
            switch res {
            case .success(let out):
                total += out.items.count
                // 每条都必须真实落在原文对应片段上（sanitize 之后应当 100% 命中）
                let ns = text as NSString
                var badOnes: [String] = []
                for it in out.items {
                    let okRange = it.start >= 0 && it.start + it.length <= ns.length
                    let sub = okRange ? ns.substring(with: NSRange(location: it.start, length: it.length)) : "<越界>"
                    if sub != it.original { badOnes.append("\(it.original)→\(sub)") }
                }
                located += out.items.count - badOnes.count
                // 术语零触碰：应用后术语 token 集合必须一致
                let applied = applyEdits(out.items, to: text)
                let before = glossaryOccurrences(text).sorted()
                let after = glossaryOccurrences(applied).sorted()
                let termOK = before == after
                if !termOK { touched += 1 }

                let desc = out.items.map { "\($0.kind.rawValue):\($0.original)→\($0.replacement)" }.joined(separator: " | ")
                let line = "#\(i + 1) \(out.items.count) 条 \(String(format: "%.2f", out.elapsed))s 术语\(termOK ? "OK" : "被改")"
                if badOnes.isEmpty && termOK { ok("live-diff·\(line)", desc.isEmpty ? "无错误（正确）" : desc) }
                else { bad("live-diff·\(line)", "错位 \(badOnes) 术语\(termOK)") }
            case .failure(let e):
                bad("live-diff·#\(i + 1)", (e as? ReviewFailure)?.userMessage ?? "\(e)")
            case .none:
                bad("live-diff·#\(i + 1)", "无结果")
            }
        }
        print("\nlive-diff 汇总：共 \(total) 条 edit，落在原文上 \(located) 条，术语被改 \(touched) 篇")
        if total > 0 && located == total { ok("live-diff·偏移全部命中", "\(located)/\(total)") }
        else { bad("live-diff·偏移全部命中", "\(located)/\(total)") }
    }

    // MARK: 本地引擎（LanguageTool，真实 HTTP 到 127.0.0.1:8081）

    static func ltTests() {
        print("\n--- 本地引擎（LanguageTool，\(LocalEngine.baseURLString)）---")
        let sem = DispatchSemaphore(value: 0)
        var alive = false
        Task.detached { alive = await LocalEngine.available(force: true); sem.signal() }
        sem.wait()
        guard alive else { bad("LT·探活", "127.0.0.1:8081 不通（先跑 scripts/languagetool-up.sh）"); return }
        ok("LT·探活", "在线")

        func review(_ text: String) -> (items: [DiffItem], ms: Double) {
            let s = DispatchSemaphore(value: 0)
            var out: [DiffItem] = []
            var ms = 0.0
            Task.detached {
                do {
                    let r = try await LocalEngine.review(text: text)
                    out = r.items; ms = r.elapsed * 1000
                } catch { print("  LT err: \(error)") }
                s.signal()
            }
            s.wait()
            return (out, ms)
        }

        // 1) 有错句：必须报，且偏移必须精确落在原文
        let badSentences = [
            "There is many reasons why we should sent the booking confirmation to the customer immediatly.",
            "Our sales team have received three new enquiry last week, and they was not able to reply on time.",
            "I has send the documents yesterday, please check it.",
        ]
        for (i, t) in badSentences.enumerated() {
            let (items, ms) = review(t)
            let ns = t as NSString
            let exact = items.allSatisfy { ns.substring(with: NSRange(location: $0.start, length: $0.length)) == $0.original }
            let desc = items.map { "\($0.original)→\($0.replacement)" }.joined(separator: " | ")
            if !items.isEmpty && exact {
                ok("LT·有错句#\(i + 1)", "\(items.count) 条 \(String(format: "%.0f", ms))ms：\(desc)")
            } else {
                bad("LT·有错句#\(i + 1)", "报 \(items.count) 条，偏移精确=\(exact)：\(desc)")
            }
        }

        // 2) 干净行业句：必须 0 条（误报是这类产品最大的死因）
        let cleanSentences = [
            "Please confirm the FCL booking with the shipper before the ETD, container MSKU1234567 is ready.",
            "The vessel departed CNTAO on 20th Nov 2026, ETA CNSHA is 22nd Nov 2026.",
            "We have received the VGM and the SI for booking 202612345678, thanks for your help.",
            "Kindly note that demurrage starts on 25th Nov if the CY pickup is delayed.",
            "According to the manifest, POL is CNSHA and POD is NLRTM for this shipment.",
        ]
        for (i, t) in cleanSentences.enumerated() {
            let (items, ms) = review(t)
            let desc = items.map { "\($0.kind.rawValue):\($0.original)→\($0.replacement)" }.joined(separator: " | ")
            if items.isEmpty {
                ok("LT·干净句#\(i + 1)", "0 条 \(String(format: "%.0f", ms))ms")
            } else {
                bad("LT·干净句#\(i + 1)", "\(items.count) 条误报：\(desc)")
            }
        }

        // 3) 中文不检查（门控在调用前就挡住，这里验证引擎侧也不该有中文建议）
        if shouldSkipAsChinese("请确认这批货的船期和舱位，谢谢") { ok("LT·中文门控") }
        else { bad("LT·中文门控", "门控没拦住") }

        // 4) 签名块之后的建议必须被丢掉
        let signed = "Please confirm the booking.\nBest regards,\nZhang Wei"
        let (signItems, _) = review(signed)
        let afterSig = signItems.filter { $0.start > 20 }
        if afterSig.isEmpty { ok("LT·签名块不检查", "报 \(signItems.count) 条且都在签名前") }
        else { bad("LT·签名块不检查", "\(afterSig.map(\.original))") }
    }

    // MARK: 工具

    static func loadFixtures() -> Fixture? {
        let candidates = [
            "fixtures/glossary.json",
            Bundle.main.bundlePath + "/Contents/Resources/glossary.json",
            FileManager.default.currentDirectoryPath + "/fixtures/glossary.json",
        ]
        for p in candidates {
            if let d = try? Data(contentsOf: URL(fileURLWithPath: p)),
               let f = try? JSONDecoder().decode(Fixture.self, from: d) { return f }
        }
        return nil
    }
}
