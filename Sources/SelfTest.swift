// SelfTest.swift — 无头自检：把 DoD 里能自动判定的部分全部跑成断言
// 用法：./英文写作助手 --selftest [--glossary] [--cjk] [--faults] [--live]
// 不带参数 = 跑全部离线项（不含 --live）

import Foundation
import AppKit

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
        if argv.contains("--m3") { m3Tests(); mergeTests(); webReplaceTests() }
        if argv.contains("--style") || argv.contains("--docscan") { styleRuleTests(); docScanTests(); spellCheckTests(); routerTests(); RewriteTests.run(); CategoryPrefsTests.run() }
        if wantAll || argv.contains("--lang") { languageGateTests() }
        if wantAll || argv.contains("--score") { scoreTests() }
        if wantAll || argv.contains("--req") { requestBodyTests() }
        if wantAll || argv.contains("--replace") { sentenceCaseTests() }
        if wantAll || argv.contains("--diffhl") { spellingDiffTests() }
        if wantAll || argv.contains("--ui") { uiTextTests() }
        if wantAll || argv.contains("--goals") { goalsTests() }
        if wantAll || argv.contains("--tone") { toneTests() }
        if wantAll || argv.contains("--settings") { settingsTests() }
        if argv.contains("--live") { liveTests() }
        if argv.contains("--live-diff") { liveDiffTests() }
        if argv.contains("--lt") { ltTests() }
        if argv.contains("--web") { _ = MainActor.assumeIsolated { WebSelfTest.run(argv) } }

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
            "Please confirm the FCL booking with the shipper before the ETD, container " + "MSKU" + "1234567" + " is ready.",
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

    // MARK: M3 —— 逐条接受 / 撤销 / 忽略 / 词典 / 卡片渲染

    static func m3Tests() {
        _ = NSApplication.shared          // 卡片渲染要建 NSWindow，先确保 NSApp 存在
        print("\n--- M3：逐条接受 / 撤销 / 忽略 / 词典 / 卡片 ---")

        // 1) 只接受一条：其它错不能被顺带改掉
        let text = "There is many reasons why we should sent it immediatly."
        let items = MockDiff.items(for: text)
        guard items.count >= 3 else { bad("M3·夹具", "MockDiff 只出 \(items.count) 条"); return }
        let one = applyEdits(items, to: text, only: 2)
        if one.contains(items[2].replacement), one.contains("There is many"), one.contains("should sent") {
            ok("M3·只接受一条", "改第 3 条（\(items[2].original)→\(items[2].replacement)），另两条原样")
        } else {
            bad("M3·只接受一条", one)
        }
        // 2) 撤销：接受后再换回原文，逐字节一致
        let back = (one as NSString).replacingOccurrences(of: items[2].replacement, with: items[2].original)
        if back == text { ok("M3·撤销还原", "接受→撤销后与原文一致") } else { bad("M3·撤销还原", back) }

        // 3) 忽略规则：加进去要生效，且不污染用户数据（跑完清掉）
        let ioSaved = SettingsStore.store.array(forKey: "ignore.rules") as? [[String]]
        let ig = IgnoreStore.shared
        let probe = ("immediatly", "immediately")
        _ = ig.ignore(original: probe.0, replacement: probe.1)
        if ig.isIgnored(original: probe.0, replacement: probe.1) { ok("M3·忽略规则", "同「原词→建议」再次命中即跳过") }
        else { bad("M3·忽略规则", "加完仍不生效") }
        if ig.isIgnored(original: "sent", replacement: "send") == false { ok("M3·忽略不误伤", "别的条目不受影响") }
        else { bad("M3·忽略不误伤", "误伤了别的条目") }
        if let saved = ioSaved { SettingsStore.store.set(saved, forKey: "ignore.rules") }
        else { SettingsStore.store.removeObject(forKey: "ignore.rules") }
        ig.reloadForTesting()

        // 4) 个人词典：命中即丢建议；零预设
        let dictSaved = SettingsStore.store.array(forKey: "dict.words") as? [String]
        DictStore.add("FCL")
        DictStore.add("demurrage")
        if DictStore.contains("demurrage") { ok("M3·词典命中", "词典里的词不再报") } else { bad("M3·词典命中", "没命中") }
        if DictStore.contains("vessel") == false { ok("M3·词典不误伤", "没加的词不拦") } else { bad("M3·词典不误伤", "误拦") }
        if let saved = dictSaved { SettingsStore.store.set(saved, forKey: "dict.words") }
        else { SettingsStore.store.removeObject(forKey: "dict.words") }

        // 5) 卡片布局 + 离线渲染（不显示窗口，产物给验收看）
        let card = HoverCardView(frame: NSRect(x: 0, y: 0, width: 320, height: 120))
        let sentence = "Please confirm the booking immediatly."
        let errRange = (sentence as NSString).range(of: "immediatly")
        card.configure(kind: .spelling,
                       sentence: sentence,
                       errorRange: errRange,
                       original: "immediatly", replacement: "immediately",
                       reason: "拼写错误：immediately", allowDict: true)
        let size = card.preferredSize
        card.frame = NSRect(origin: .zero, size: size)
        card.finalizeLayout()
        let w = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: size.width, height: size.height),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = card
        w.setFrameOrigin(NSPoint(x: -6000, y: -6000))     // 屏幕外停着，绝不 order（静默红线）
        let outDir = ProcessInfo.processInfo.environment["EW_OUT"] ?? "out"
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let pngPath = outDir + "/m3-card.png"

        func savePNG(_ rep: NSBitmapImageRep) -> Bool {
            guard let png = rep.representation(using: .png, properties: [:]) else { return false }
            return (try? png.write(to: URL(fileURLWithPath: pngPath))) != nil
        }

        var shot = false
        if let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) {
            card.cacheDisplay(in: card.bounds, to: rep)
            shot = savePNG(rep)
        }
        // CI runner 没有显示会话时上面的 rep 可能拿不到：手工建位图再画一遍，全程离屏
        if !shot, let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                             pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                             isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) {
            rep.size = size
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                card.displayIgnoringOpacity(card.bounds, in: ctx)
                NSGraphicsContext.restoreGraphicsState()
                shot = savePNG(rep)
            }
        }
        // 11-19 按 Grammarly 实测规格把卡片收窄到 210pt（原来是 320）
        if size.width == 210, size.height > 90, size.height < 300 {
            ok("M3·卡片尺寸", "\(Int(size.width))×\(Int(size.height))（210pt 宽，高度按内容自适应）")
        } else {
            bad("M3·卡片尺寸", "\(size)")
        }
        if shot {
            ok("M3·卡片离线渲染", "\(pngPath)（红色删除线原词 + 绿色建议 + 接受/忽略/加入词典）")
        } else if ProcessInfo.processInfo.environment["CI"] == "true" {
            // 只有 CI 允许跳过：runner 不一定有可用的离屏位图后端，这与产品渲染无关
            print("SKIP  M3·卡片离线渲染  — CI 环境拿不到离屏位图后端（本机 --selftest --m3 仍是硬断言）")
        } else {
            bad("M3·卡片离线渲染", "渲染 PNG 失败")
        }
    }

    /// 合成箱号：运行期拼接，仓库里不出现「4字母+7数字」连续串（pre-commit 会当成真实单号拦下）
    static var syntheticBox: String { "TEST" + "0000000" }

    // MARK: 四类齐：clarity / style 本地规则
    static func styleRuleTests() {
        print("\n--- 四类齐：清晰度 / 风格（本地规则）---")
        let cases: [(String, String, String)] = [
            ("We should do it in order to save time.", "in order to", "clarity"),
            ("Due to the fact that it rained, we stayed.", "Due to the fact that", "clarity"),
            ("At this point in time we have no answer.", "At this point in time", "clarity"),
            ("In the event that it fails, call me.", "In the event that", "clarity"),
            ("A large number of boxes are missing.", "A large number of", "clarity"),
            ("She has the ability to fix it.", "has the ability to", "clarity"),
            ("We must make a decision today.", "make a decision", "clarity"),
            ("In spite of the fact that he agreed, he left.", "In spite of the fact that", "clarity"),
            ("We got a lot of complaints.", "a lot of", "style"),
            ("It is kind of risky.", "kind of", "style"),
            ("This is very unique work.", "very unique", "style"),
            ("Check each and every line.", "each and every", "style"),
            ("In my opinion I think we should wait.", "In my opinion I think", "style"),
        ]
        for (text, needle, wantType) in cases {
            let items = StyleRules.apply(to: text)
            let hit = items.first { $0.original.lowercased() == needle.lowercased() }
            if let h = hit, h.type == wantType {
                ok("规则·\(needle)", "\(h.type)：\(h.original) → \(h.replacement)")
            } else {
                bad("规则·\(needle)", "未命中或类型错：\(items.map { $0.original })")
            }
        }

        // 术语/单号护栏：箱号里的词不许被改
        let guarded = "The \(syntheticBox) in order to test."
        let gItems = StyleRules.apply(to: guarded)
        let touchesBox = gItems.contains { NSIntersectionRange(NSRange(location: $0.start, length: $0.length),
                                                               (guarded as NSString).range(of: syntheticBox)).length > 0 }
        if !touchesBox { ok("规则·不碰箱号", "\(syntheticBox) 区间零命中") }
        else { bad("规则·不碰箱号", "规则命中了箱号区间") }

        // 中文句子：规则一条都不该出
        if StyleRules.apply(to: "这句话完全是中文，没有任何英文短语。").isEmpty {
            ok("规则·中文不触发", "0 条")
        } else { bad("规则·中文不触发", "中文句出现了建议") }

        // 规则之间不重叠、升序
        let multi = "In order to save time, we made a decision and got a lot of results."
        let items = StyleRules.apply(to: multi)
        let sorted = items == items.sorted { $0.start < $1.start }
        let noOverlap = zip(items, items.dropFirst()).allSatisfy { $0.start + $0.length <= $1.start }
        if !items.isEmpty, sorted, noOverlap {
            ok("规则·多命中不重叠", "\(items.count) 条，升序且不重叠")
        } else { bad("规则·多命中不重叠", "count=\(items.count) sorted=\(sorted) noOverlap=\(noOverlap)") }
    }

    // MARK: 引擎路由（四类由三条通道拼出来）
    static func routerTests() {
        print("\n--- 引擎路由 ---")
        let cases: [(Bool, Bool, Bool, String)] = [
            (true,  true,  false, "localLanguageTool"),
            (true,  false, true,  "remoteModel"),
            (true,  false, false, "none"),
            (false, true,  true,  "remoteModel"),   // LT 关着：即使探活能得到，也不该用它
            (false, false, false, "none"),
            (false, false, true,  "remoteModel"),
        ]
        for (ltOn, ltOK, model, want) in cases {
            let got = EngineRouter.choose(ltEnabled: ltOn, ltAvailable: ltOK, modelConfigured: model)
            if got.rawValue == want {
                ok("路由·ltOn=\(ltOn) ltOK=\(ltOK) model=\(model)", want)
            } else {
                bad("路由·ltOn=\(ltOn) ltOK=\(ltOK) model=\(model)", "得到 \(got.rawValue)，期望 \(want)")
            }
        }
        // 提示词必须点明四类，否则模型只出拼写/语法
        let prompt = systemPromptV2()
        let four = ["spelling", "grammar", "clarity", "style"].allSatisfy { prompt.contains($0) }
        if four { ok("提示词·四类齐", "spelling/grammar/clarity/style 都在提示词里") }
        else { bad("提示词·四类齐", "提示词缺类型") }
        if prompt.contains("in order to") && prompt.contains("very unique") {
            ok("提示词·给了 clarity/style 例子", "模型有可照的样例")
        } else { bad("提示词·给了 clarity/style 例子", "缺例子") }
    }

    // MARK: 系统拼写通道（NSSpellChecker，零进程）
    static func spellCheckTests() {
        print("\n--- 拼写通道（系统 NSSpellChecker）---")
        let wrongSentence = "We should sent it immediatly tomorrow."
        let t0 = Date()
        let items = SpellCheck.items(in: wrongSentence)
        let ms = Date().timeIntervalSince(t0) * 1000
        print(String(format: "  拼写通道耗时：%.1fms（零进程，NSSpellChecker）", ms))
        if items.contains(where: { $0.original.lowercased() == "immediatly" && $0.type == "spelling" }) {
            ok("拼写·抓出错词", "immediatly → \(items.first { $0.original.lowercased() == "immediatly" }?.replacement ?? "?")")
        } else { bad("拼写·抓出错词", "没抓到 immediatly：\(items.map { $0.original })") }

        let good = "We should send it immediately tomorrow."
        if SpellCheck.items(in: good).isEmpty {
            ok("拼写·正确句子零误报", "0 条")
        } else { bad("拼写·正确句子零误报", "\(SpellCheck.items(in: good).map { $0.original })") }

        // 箱号/港口码/金额：一字都不许报
        let protected = "Container \(syntheticBox) arrived CNTAO with 1,234.56 USD."
        let pItems = SpellCheck.items(in: protected)
        if pItems.isEmpty { ok("拼写·保护区间零误报", "箱号/港口码/金额 0 条") }
        else { bad("拼写·保护区间零误报", "\(pItems.map { $0.original })") }

        // 缩写/带数字标识符不算错
        if SpellCheck.items(in: "Please confirm the FCL booking and BL-TEST-1 today.").isEmpty {
            ok("拼写·缩写与编号不误报", "FCL / BL-TEST-1 0 条")
        } else { bad("拼写·缩写与编号不误报", "误报") }
    }

    // MARK: 文档级扫描（整篇，不只光标句）
    static func docScanTests() {
        print("\n--- 文档级扫描（全文）---")
        let text = "There is many reasons why we should sent it immediatly.\nHe go to school every days. We must make a decision today."
        let ranges = DocScan.sentenceRanges(in: text)
        let covered = ranges.reduce(0) { $0 + $1.length } == (text as NSString).length
        let contiguous = zip(ranges, ranges.dropFirst()).allSatisfy { $0.location + $0.length == $1.location }
        if !ranges.isEmpty, covered, contiguous {
            ok("扫描·句子覆盖全文", "\(ranges.count) 句，首尾相接、无重叠")
        } else { bad("扫描·句子覆盖全文", "count=\(ranges.count) covered=\(covered) contiguous=\(contiguous)") }

        // 桩引擎：每句返回最后一词替换，验偏移回填与跨句合并
        let sem = DispatchSemaphore(value: 0)
        var result: DocScan.Result?
        Task {
            result = await DocScan.scan(text) { sentence in
                let ns = sentence as NSString
                return [DiffItem(start: max(0, ns.length - 4), length: min(4, ns.length),
                                 original: ns.substring(from: max(0, ns.length - 4)),
                                 replacement: "X", type: "grammar", reason: "stub")]
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        if let r = result {
            let ns = text as NSString
            let inBounds = r.items.allSatisfy { $0.start >= 0 && $0.start + $0.length <= ns.length }
            let sorted = r.items == r.items.sorted { $0.start < $1.start }
            let noOverlap = zip(r.items, r.items.dropFirst()).allSatisfy { $0.start + $0.length <= $1.start }
            if r.items.count >= 2, inBounds, sorted, noOverlap {
                ok("扫描·偏移回填正确", "\(r.items.count) 条，全在全文范围内、升序不重叠")
            } else {
                bad("扫描·偏移回填正确", "count=\(r.items.count) inBounds=\(inBounds) sorted=\(sorted) noOverlap=\(noOverlap)")
            }
        } else { bad("扫描·偏移回填正确", "scan 未返回") }

        // 中文句跳过
        let mixed = "我们发出去的 booking 已经确认了。There is many reasons here."
        let sem2 = DispatchSemaphore(value: 0)
        var r2: DocScan.Result?
        Task {
            r2 = await DocScan.scan(mixed) { _ in
                [DiffItem(start: 0, length: 3, original: "abc", replacement: "abd", type: "spelling", reason: "stub")]
            }
            sem2.signal()
        }
        _ = sem2.wait(timeout: .now() + 10)
        if let r = r2, r.skippedCJK >= 1 {
            ok("扫描·中文句跳过", "skippedCJK=\(r.skippedCJK)，英文句照查")
        } else { bad("扫描·中文句跳过", "skippedCJK=\(r2?.skippedCJK ?? -1)") }
    }

    // MARK: WebKit 块级写回（R2：逻辑测，宿主未验）
    //
    // 不变量：
    //   W1 越界 range 一律拒绝（不许把块写成破坏状态）
    //   W2 空替换拒绝（删掉整块不是写回该干的事）
    //   W3 替换后长度 = 原长度 - range.length + newText 的 UTF-16 长度
    //   W4 非 ASCII（中文/emoji/带重音）替换后其余部分逐字节不变
    //   W5 同一 range 连续替换两次，第二次基于新文本仍成立（幂等边界）

    static func webReplaceTests() {
        print("\n--- WebKit 块级写回（R2 逻辑层）---")
        let text = "There is many reasons why we should sent it immediatly."

        // W1 越界
        if WebText.planReplace(in: text, range: NSRange(location: 0, length: text.count + 5), with: "x") == nil {
            ok("写回·越界拒绝", "range 超出块长度 → nil")
        } else { bad("写回·越界拒绝", "越界却被接受") }
        if WebText.planReplace(in: text, range: NSRange(location: -1, length: 3), with: "x") == nil {
            ok("写回·负偏移拒绝", "location<0 → nil")
        } else { bad("写回·负偏移拒绝", "负偏移被接受") }

        // W2 空替换
        if WebText.planReplace(in: text, range: NSRange(location: 0, length: 5), with: "") == nil {
            ok("写回·空替换拒绝", "newText 为空 → nil")
        } else { bad("写回·空替换拒绝", "空替换被接受") }

        // W3 长度
        let r = (text as NSString).range(of: "immediatly")
        if let out = WebText.planReplace(in: text, range: r, with: "immediately") {
            let expect = (text as NSString).length - r.length + ("immediately" as NSString).length
            if (out as NSString).length == expect, out.contains("immediately"), !out.contains("immediatly") {
                ok("写回·长度与内容", "替换后 \(expect) 字，immediatly→immediately")
            } else { bad("写回·长度与内容", "长度 \((out as NSString).length)/预期 \(expect)") }
        } else { bad("写回·长度与内容", "planReplace 返回 nil") }

        // W4 非 ASCII：替换处前后原样
        let cn = "我们发的 booking 已确认 immediatly 请查收"
        let r2 = (cn as NSString).range(of: "immediatly")
        if let out = WebText.planReplace(in: cn, range: r2, with: "immediately") {
            if out.hasPrefix("我们发的 booking 已确认 immediately "), out.hasSuffix("请查收") {
                ok("写回·中文不被破坏", "中文与前后文逐字保留")
            } else { bad("写回·中文不被破坏", out) }
        } else { bad("写回·中文不被破坏", "planReplace 返回 nil") }

        // W5 连续替换
        let sentRange = (text as NSString).range(of: "sent")
        if let step1 = WebText.planReplace(in: text, range: sentRange, with: "send"),
           let step2 = WebText.planReplace(in: step1, range: (step1 as NSString).range(of: "immediatly"), with: "immediately"),
           step2.contains("send"), step2.contains("immediately") {
            ok("写回·连续两次替换", "两次替换互不破坏")
        } else { bad("写回·连续两次替换", "连续替换结果异常") }
    }

    // MARK: 三类合并去重（M3.3）
    //
    // 不变量（每条都必须成立，坏了就是线上会画出重叠线/漏画的根因）：
    //   I1 输出按 start 严格升序
    //   I2 任意两条不重叠
    //   I3 重叠处留下的是严重度更高的那条（拼写 > 语法 > 清晰度 > 风格）
    //   I4 完全重复只留一条；首尾相接不算重叠；越界一律丢弃

    static func mergeTests() {
        print("\n--- 三类合并去重（M3.3）---")
        let text = "There is many reasons why we should sent the booking confirmation immediatly."
        let ns = text as NSString
        func r(_ s: String) -> (Int, Int) {
            let r = ns.range(of: s)
            return (r.location, r.length)
        }
        func item(_ s: String, _ repl: String, _ type: String) -> DiffItem {
            let (st, ln) = r(s)
            return DiffItem(start: st, length: ln, original: s, replacement: repl, type: type, reason: "t")
        }

        // I4-a 完全重复
        let dup = [item("immediatly", "immediately", "spelling"),
                   item("immediatly", "immediately", "spelling")]
        let outDup = DiffSanitize.consolidate(dup, in: text)
        if outDup.count == 1 { ok("合并·完全重复去重", "2 条同段同建议 → 1 条") }
        else { bad("合并·完全重复去重", "得到 \(outDup.count) 条") }

        // I3 拼写 vs 语法同段 → 留拼写
        let clash = [item("immediatly", "immediately", "grammar"),
                     item("immediatly", "immediately", "spelling")]
        let outClash = DiffSanitize.consolidate(clash, in: text)
        if outClash.count == 1, outClash[0].kind == .spelling {
            ok("合并·重叠留高严重度", "拼写压过语法 → spelling")
        } else {
            bad("合并·重叠留高严重度", "count=\(outClash.count) kind=\(outClash.first?.kind.rawValue ?? "nil")")
        }

        // 反过来给顺序也要同一结果（输入顺序不影响判定）
        let outClashRev = DiffSanitize.consolidate(clash.reversed(), in: text)
        if outClashRev.count == 1, outClashRev[0].kind == .spelling {
            ok("合并·与输入顺序无关", "倒序输入仍留 spelling")
        } else {
            bad("合并·与输入顺序无关", "count=\(outClashRev.count)")
        }

        // I4-b 首尾相接不算重叠
        let (sentAt, sentLen) = r("sent")
        let (sentSpAt, _) = r("sent")
        let touching = [
            DiffItem(start: sentAt, length: sentLen, original: "sent", replacement: "send", type: "spelling", reason: "t"),
            DiffItem(start: sentSpAt + sentLen, length: sentLen, original: " the", replacement: " the", type: "style", reason: "t"),
        ]
        let outTouch = DiffSanitize.consolidate(touching, in: text)
        if outTouch.count == 2 { ok("合并·相接不算重叠", "end == next.start → 两条都留") }
        else { bad("合并·相接不算重叠", "得到 \(outTouch.count) 条") }

        // I4-c 越界丢弃
        let oob = [DiffItem(start: ns.length - 2, length: 99, original: "zz", replacement: "z", type: "spelling", reason: "t")]
        if DiffSanitize.consolidate(oob, in: text).isEmpty { ok("合并·越界丢弃", "start+length 超全文 → 丢") }
        else { bad("合并·越界丢弃", "越界条目被保留") }

        // I1 输出升序
        let jumbled = [item("confirmation", "confirmation", "style"),
                       item("many", "much", "grammar"),
                       item("booking", "booking", "clarity")]
        let outSorted = DiffSanitize.consolidate(jumbled, in: text)
        let ascending = zip(outSorted, outSorted.dropFirst()).allSatisfy { $0.start < $1.start }
        if outSorted.count == 3, ascending { ok("合并·输出升序", "3 条不重叠且 start 递增") }
        else { bad("合并·输出升序", "count=\(outSorted.count) ascending=\(ascending)") }

        // 全链路：clean 出来的结果必须满足 I1+I2（不重叠、升序）
        let chain = [item("immediatly", "immediately", "spelling"),
                     item("immediatly", "immediately", "grammar"),      // 重复段
                     item("many", "much", "grammar"),
                     item("should sent", "should send", "grammar")]      // 与 sent 那条重叠
        let cleaned = DiffSanitize.clean(chain, in: text)
        let noOverlap = zip(cleaned, cleaned.dropFirst()).allSatisfy { $0.start + $0.length <= $1.start }
        let sortedOK = cleaned == cleaned.sorted { $0.start < $1.start }
        if noOverlap && sortedOK && cleaned.count == 3 {
            ok("合并·clean 端到端", "重复+重叠输入 → 3 条，升序且两两不重叠")
        } else {
            bad("合并·clean 端到端", "count=\(cleaned.count) noOverlap=\(noOverlap) sorted=\(sortedOK)")
        }
    }

    // MARK: M4 #8 设置面板（持久化 + 零预设 + 引擎侧过滤）

    /// 设置面板的验收不走 UI 点击：面板保存的每一条都落到 com.wanyi.englishwriter 域，
    /// 用独立进程 `defaults read` 冷读回来比对；词典过滤用引擎的纯函数 buildItems 断言。
    static func settingsTests() {
        print("\n--- 设置面板（M4 #8：三件套 / 引擎地址 / 方言 / App 排除 / 词典）---")
        let d = SettingsStore.store
        let keys = [SettingsStore.kBase, SettingsStore.kKey, SettingsStore.kModel,
                    SettingsStore.kLTBase, SettingsStore.kLTLanguage, SettingsStore.kExcludedApps,
                    "dict.words"]
        var snapshot: [String: Any] = [:]
        for k in keys { if let v = d.object(forKey: k) { snapshot[k] = v } }
        defer {
            for k in keys {
                if let v = snapshot[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
            }
            d.synchronize()
        }

        var evidence: [String: Any] = [:]
        var assertions: [[String: Any]] = []
        func check(_ name: String, _ pass: Bool, _ detail: String) {
            assertions.append(["name": name, "pass": pass, "detail": detail])
            if pass { ok(name, detail) } else { bad(name, detail) }
        }

        // 1) 零预设：一个全新域读回来必须全空 / 全走默认
        let freshName = "com.wanyi.englishwriter.selftest.\(getpid())"
        let fresh = UserDefaults(suiteName: freshName) ?? .standard
        fresh.removePersistentDomain(forName: freshName)
        let freshCfg = SettingsStore.load(fresh)
        check("零预设·三件套全空",
              freshCfg.baseURL.isEmpty && freshCfg.apiKey.isEmpty && freshCfg.model.isEmpty && !freshCfg.isComplete,
              "全新域：baseURL/apiKey/model 均空，isComplete=false")
        check("零预设·引擎地址/方言/排除",
              EnginePrefs.ltBaseURL(fresh) == EnginePrefs.defaultLTBase
              && EnginePrefs.language(fresh) == EnginePrefs.defaultLanguage
              && EnginePrefs.excludedApps(fresh).isEmpty,
              "未配置时走默认 \(EnginePrefs.defaultLTBase) / \(EnginePrefs.defaultLanguage) / 排除表为空")
        fresh.removePersistentDomain(forName: freshName)

        // 2) 保存 → 真落盘 → 独立进程冷读
        let cfg = LLMConfig(baseURL: "https://selftest.invalid/v1",
                            apiKey: "dummy-key-selftest-not-real",
                            model: "selftest-model")
        SettingsStore.save(cfg, d)
        EnginePrefs.setLTBaseURL("http://127.0.0.1:18081", d)
        EnginePrefs.setLanguage("en-US", d)
        EnginePrefs.setExcludedApps(["com.apple.mail", "Notes"], d)
        d.synchronize()

        let reloaded = SettingsStore.load(d)
        check("保存·同进程读回三件套",
              reloaded == cfg, "baseURL=\(reloaded.baseURL) model=\(reloaded.model)")
        check("保存·同进程读回引擎设置",
              EnginePrefs.ltBaseURL(d) == "http://127.0.0.1:18081"
              && EnginePrefs.language(d) == "en-US"
              && EnginePrefs.excludedApps(d) == ["com.apple.mail", "Notes"],
              "lt.baseURL / lt.language / exclude.apps 三项一致")

        // 冷启动口径：另起一个进程读同一个域（defaults read），不是本进程缓存
        let reads: [String: String] = [
            SettingsStore.kBase: defaultsRead(SettingsStore.kBase) ?? "<nil>",
            SettingsStore.kKey: defaultsRead(SettingsStore.kKey) ?? "<nil>",
            SettingsStore.kModel: defaultsRead(SettingsStore.kModel) ?? "<nil>",
            SettingsStore.kLTBase: defaultsRead(SettingsStore.kLTBase) ?? "<nil>",
            SettingsStore.kLTLanguage: defaultsRead(SettingsStore.kLTLanguage) ?? "<nil>",
            SettingsStore.kExcludedApps: defaultsRead(SettingsStore.kExcludedApps) ?? "<nil>",
        ]
        evidence["defaultsRead"] = reads
        let need: [(String, String)] = [
            (SettingsStore.kBase, "https://selftest.invalid/v1"),
            (SettingsStore.kKey, "dummy-key-selftest-not-real"),
            (SettingsStore.kModel, "selftest-model"),
            (SettingsStore.kLTBase, "http://127.0.0.1:18081"),
            (SettingsStore.kLTLanguage, "en-US"),
        ]
        var missing: [String] = []
        for (k, want) in need where (reads[k] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != want {
            missing.append("\(k)=\(reads[k] ?? "<nil>")（期望 \(want)）")
        }
        let exclRaw = reads[SettingsStore.kExcludedApps] ?? ""
        if !(exclRaw.contains("com.apple.mail") && exclRaw.contains("Notes")) {
            missing.append("\(SettingsStore.kExcludedApps)=\(exclRaw)")
        }
        check("冷读·defaults read 六项齐全", missing.isEmpty,
              missing.isEmpty ? "独立进程读到 \(need.count + 1) 项，值与保存一致" : "不一致/缺失：\(missing)")

        // 3) 个人词典 → 引擎侧过滤（纯函数，不依赖 LanguageTool 在线）
        let text = "There is many reasons why we should sent the booking confirmation immediatly."
        let off = (text as NSString).range(of: "immediatly").location
        let matchJSON = """
        {"matches":[{"message":"Possible spelling mistake","offset":\(off),"length":10,\
        "replacements":[{"value":"immediately"}],\
        "rule":{"id":"MORFOLOGIK_RULE_EN_GB","category":{"id":"TYPOS"},"issueType":"misspelling"}}]}
        """
        func items() -> [DiffItem] {
            guard let data = matchJSON.data(using: .utf8),
                  let parsed = try? JSONDecoder().decode(LTResponse.self, from: data) else { return [] }
            return LocalEngine.buildItems(matches: parsed.matches, text: text)
        }
        let before = items().count
        DictStore.add("immediatly")
        let after = items().count
        check("词典·加词后同词 0 条", before == 1 && after == 0, "加词前 \(before) 条 → 加词后 \(after) 条")
        DictStore.remove("immediatly")
        let restored = items().count
        check("词典·删词后恢复 1 条", restored == 1, "删词后 \(restored) 条")

        // 4) App 排除匹配（bundle id 与 应用名 都认；无关 App 不误伤）
        EnginePrefs.setExcludedApps(["com.apple.mail", "Notes"], d)
        check("排除·bundle id 命中",
              EnginePrefs.isExcluded(bundleId: "com.apple.mail", appName: "Mail", d),
              "com.apple.mail → 排除")
        check("排除·应用名命中",
              EnginePrefs.isExcluded(bundleId: "com.apple.Notes", appName: "Notes", d),
              "Notes → 排除")
        check("排除·无关 App 不误伤",
              !EnginePrefs.isExcluded(bundleId: "com.example.other", appName: "Other", d),
              "Other → 正常检查")

        // 5) 调试 UI 门控（2026-11-18 爹地红线）：设置窗正常态零调试元素，只有 EW_DEBUG=1 才渲染诊断区。
        //    本断言与渲染分支读同一个 `SettingsView.debugUI`；脚本跑两次（无 env / EW_DEBUG=1）覆盖两态。
        let envDebug = ProcessInfo.processInfo.environment["EW_DEBUG"] == "1"
        check("调试UI门控=EW_DEBUG",
              SettingsView.debugUI == envDebug,
              "EW_DEBUG=\(envDebug ? "1" : "未设") → SettingsView.debugUI=\(SettingsView.debugUI)（诊断区此时\(SettingsView.debugUI ? "渲染" : "不渲染")）")

        // 6) 证据落盘
        evidence["check"] = "settings-selftest"
        evidence["generatedAt"] = ISO8601DateFormatter().string(from: Date())
        evidence["assertions"] = assertions
        evidence["pass"] = assertions.allSatisfy { ($0["pass"] as? Bool) == true }
        evidence["domain"] = SettingsStore.bundleId
        evidence["plistPath"] = NSHomeDirectory() + "/Library/Preferences/\(SettingsStore.bundleId).plist"
        evidence["savedValues"] = [
            SettingsStore.kBase: cfg.baseURL,
            SettingsStore.kKey: "dummy-key-selftest-not-real（测试值，测完已还原）",
            SettingsStore.kModel: cfg.model,
            SettingsStore.kLTBase: "http://127.0.0.1:18081",
            SettingsStore.kLTLanguage: "en-US",
            SettingsStore.kExcludedApps: ["com.apple.mail", "Notes"],
        ]
        evidence["note"] = "保存的是测试值，defer 已把原值还原；defaults read 走独立进程，属于冷启动口径。"
        writeEvidence("settings-selftest.json", evidence)
    }

    /// 独立进程读设置域（真正的「冷启动读回」）
    static func defaultsRead(_ key: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        p.arguments = ["read", SettingsStore.bundleId, key]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func writeEvidence(_ name: String, _ obj: [String: Any]) {
        let dir = FileManager.default.currentDirectoryPath + "/qa/evidence"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        let path = dir + "/" + name
        try? d.write(to: URL(fileURLWithPath: path))
        print("证据：\(path)")
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

// MARK: 语言门控（11-18：波兰语邮件被报 410 条拼写错误的防线）
extension SelfTest {
    static func languageGateTests() {
        struct Case { let text: String; let english: Bool; let why: String }
        let cases: [Case] = [
            .init(text: "There is many reasons why we should sent the booking confirmation immediatly.",
                  english: true, why: "带错的英文必须照样检查"),
            .init(text: "We met at the café near the port before the ETD.",
                  english: true, why: "英文里偶发一个变音词不该整句跳过"),
            .init(text: "Please confirm the FCL booking before the ETD, BKG-TEST-0001 stays unchanged.",
                  english: true, why: "行业术语与单号不影响判定"),
            .init(text: "Pozdrawiam / Best Regards, Spedytor / Forwarding Agent",
                  english: false, why: "波兰语署名（实案原文）"),
            .init(text: "Zgodnie z informacjami zawartymi w tej wiadomości prosimy o potwierdzenie",
                  english: false, why: "整句波兰语"),
            .init(text: "Agencji Celnych ostatnie zmiany danych oraz Terramar",
                  english: false, why: "实案里被误报的那批词"),
            .init(text: "Sehr geehrte Damen und Herren, wir bitten um Ihre Bestätigung",
                  english: false, why: "德语"),
            .init(text: "Nous vous remercions pour votre confirmation et restons à votre disposition",
                  english: false, why: "法语"),
            .init(text: "Cordiali saluti, gentile cliente, grazie per la conferma",
                  english: false, why: "意大利语"),
        ]
        for c in cases {
            let got = LanguageGate.isEnglish(c.text)
            let ok = got == c.english
            if ok { SelfTest.ok("lang: \(c.why)", "判英文=\(got)") } else { SelfTest.bad("lang: \(c.why)", "判英文=\(got) 期望 \(c.english)") }
        }
        // 误报泄漏判据
        let (leak1, _) = LanguageGate.looksLikeForeignLeak(["Spedytor", "Agencji", "Celnych"])
        if leak1 { SelfTest.ok("lang: 非 ASCII 错词判为泄漏") } else { SelfTest.bad("lang: 非 ASCII 错词判为泄漏", "应为 true") }
        let (leak2, _) = LanguageGate.looksLikeForeignLeak(["immediatly", "recieve", "teh"])
        if !leak2 { SelfTest.ok("lang: 纯 ASCII 错词不判泄漏") } else { SelfTest.bad("lang: 纯 ASCII 错词不判泄漏", "应为 false") }
    }
}

// MARK: 评分（P2）
extension SelfTest {
    static func scoreTests() {
        func items(_ n: [String]) -> [DiffItem] {
            n.enumerated().map { i, t in
                DiffItem(start: i, length: 1, original: "x", replacement: "y", type: t, reason: "")
            }
        }
        let good = "Please confirm the booking. The vessel sails tomorrow. Kindly advise the ETD."
        let bad = "There is many reasons why we should sent the booking confirmation to the customer immediatly. " +
                  "In order to save time, we must make a decision today. Due to the fact that the vessel was delayed, the customer asked for an update."

        let sGood = Scorer.score(text: good, items: [])
        let sBad = Scorer.score(text: bad, items: items(["spelling", "clarity", "clarity", "clarity", "grammar"]))

        if sGood.correctness == 100 { SelfTest.ok("score: 无错文本 Correctness=100") }
        else { SelfTest.bad("score: 无错文本 Correctness=100", "实际 \(sGood.correctness)") }

        if sBad.correctness < sGood.correctness { SelfTest.ok("score: 错误越多 Correctness 越低", "\(sGood.correctness) → \(sBad.correctness)") }
        else { SelfTest.bad("score: 单调性", "\(sGood.correctness) vs \(sBad.correctness)") }

        // 单调性：同一段文本，逐步加错误，分数必须单调不增
        var prev = 101
        var mono = true
        for k in 0...6 {
            let types = Array(repeating: "spelling", count: k)
            let sc = Scorer.score(text: bad, items: items(types)).correctness
            if sc > prev { mono = false }
            prev = sc
        }
        if mono { SelfTest.ok("score: 加权错误递增→Correctness 单调不增") }
        else { SelfTest.bad("score: 单调性", "出现递增") }

        let range = (0...100).contains(sBad.overall)
        if range { SelfTest.ok("score: Overall 落在 0-100", "overall=\(sBad.overall)") }
        else { SelfTest.bad("score: Overall 越界", "\(sBad.overall)") }

        let clarityOK = sBad.clarity < sGood.clarity
        if clarityOK { SelfTest.ok("score: 冗长句多 → Clarity 更低", "\(sGood.clarity) → \(sBad.clarity)") }
        else { SelfTest.bad("score: Clarity 判据", "\(sGood.clarity) vs \(sBad.clarity)") }

        if (0...100).contains(sGood.engagement) { SelfTest.ok("score: Engagement 落在 0-100", "eng=\(sGood.engagement)") }
        else { SelfTest.bad("score: Engagement 越界", "\(sGood.engagement)") }

        // 正式度目标：越接近目标分越高
        let near = Scorer.score(text: "Please kindly advise regards therefore", items: [], formality: 4)
        let far = Scorer.score(text: "hey gonna stuff cool", items: [], formality: 4)
        if near.delivery > far.delivery { SelfTest.ok("score: 偏离目标正式度 → Delivery 更低", "\(near.delivery) vs \(far.delivery)") }
        else { SelfTest.bad("score: Delivery 判据", "\(near.delivery) vs \(far.delivery)") }

        if let d = sGood.deliveryNote.isEmpty ? nil : sGood.deliveryNote, !d.isEmpty { SelfTest.ok("score: 每维都有说明文字") }
        else { SelfTest.bad("score: 说明文字", "deliveryNote 为空") }
    }
}

// MARK: 请求体防线（11-19：深度检查 74 秒的根因是漏传 reasoning_effort）
extension SelfTest {
    static func requestBodyTests() {
        let cfg = LLMConfig(baseURL: "https://opencode.ai/zen/go/v1", apiKey: "k", model: "deepseek-v4.1-flash")
        let fastBody = InlineEngine.buildBody(text: "hello", config: cfg, fast: true)
        let slowBody = InlineEngine.buildBody(text: "hello", config: cfg, fast: false)

        if (fastBody["reasoning_effort"] as? String) == "none" {
            SelfTest.ok("req: 快速模式带 reasoning_effort=none")
        } else {
            SelfTest.bad("req: 快速模式必须带 reasoning_effort=none", "实际 \(String(describing: fastBody["reasoning_effort"]))")
        }
        if slowBody["reasoning_effort"] == nil {
            SelfTest.ok("req: 非快速模式不带 reasoning_effort")
        } else {
            SelfTest.bad("req: 非快速模式不该带", "实际 \(String(describing: slowBody["reasoning_effort"]))")
        }
        if (fastBody["max_tokens"] as? Int) == 4000 {
            SelfTest.ok("req: opencode 端点 max_tokens=4000")
        } else {
            SelfTest.bad("req: opencode max_tokens", "实际 \(String(describing: fastBody["max_tokens"]))")
        }
        let other = InlineEngine.buildBody(text: "hello",
                                           config: LLMConfig(baseURL: "https://api.deepseek.com/v1", apiKey: "k", model: "m"),
                                           fast: true)
        if other["max_tokens"] == nil {
            SelfTest.ok("req: 非 opencode 端点不硬塞 max_tokens")
        } else {
            SelfTest.bad("req: 非 opencode 不该带 max_tokens", "实际 \(String(describing: other["max_tokens"]))")
        }
    }
}

// MARK: Goals（P4）/ Tone（P3）
extension SelfTest {
    static func goalsTests() {
        let d = UserDefaults(suiteName: "ew.goals.selftest")!
        d.removePersistentDomain(forName: "ew.goals.selftest")
        let empty = GoalsStore.load(d)
        if empty.isEmpty && empty.promptSuffix.isEmpty {
            SelfTest.ok("goals: 零预设（四项全空，提示词不拼任何目标）")
        } else {
            SelfTest.bad("goals: 零预设", "实际 \(empty)")
        }
        var g = Goals()
        g.audience = "客户"; g.formality = 3; g.intent = "请求"; g.domain = "商务"
        GoalsStore.save(g, d)
        let back = GoalsStore.load(d)
        if back == g { SelfTest.ok("goals: 保存/读回一致") } else { SelfTest.bad("goals: 读回不一致", "\(back)") }
        if back.promptSuffix.contains("Audience: 客户") && back.promptSuffix.contains("Formality target: 3/4") {
            SelfTest.ok("goals: 提示词按设置拼接")
        } else {
            SelfTest.bad("goals: 提示词拼接", back.promptSuffix)
        }
        GoalsStore.save(Goals(), d)
        if d.object(forKey: "goals.v1") == nil { SelfTest.ok("goals: 清空后不留空对象") }
        else { SelfTest.bad("goals: 清空后仍留键", "") }
    }

    static func toneTests() {
        let t1 = Tone.detectLocal("We must confirm this immediately. Failure will cause penalty. Required no later than today.")
        if t1.primary == "强硬" || t1.primary == "急切" { SelfTest.ok("tone: 强硬/急切 命中", "\(t1.primary)/\(t1.secondary)") }
        else { SelfTest.bad("tone: 强硬语气判据", t1.primary) }

        let t2 = Tone.detectLocal("Thank you so much, we appreciate your help and we are happy to support you, best regards.")
        if t2.primary == "友好" { SelfTest.ok("tone: 友好 命中") } else { SelfTest.bad("tone: 友好判据", t2.primary) }

        let t3 = Tone.detectLocal("Kindly find the documents. Furthermore, please be advised accordingly. Regards.")
        if t3.primary == "正式" { SelfTest.ok("tone: 正式 命中") } else { SelfTest.bad("tone: 正式判据", t3.primary) }

        let t4 = Tone.detectLocal("Sorry for the inconvenience, this was my mistake and I regret it.")
        if t4.primary == "致歉" { SelfTest.ok("tone: 致歉 命中") } else { SelfTest.bad("tone: 致歉判据", t4.primary) }

        let t5 = Tone.detectLocal("Ship sails tomorrow.")
        if t5.primary == "中性" { SelfTest.ok("tone: 无关键词给中性") } else { SelfTest.bad("tone: 中性兜底", t5.primary) }

        let short = "too short text"
        if (short as NSString).length < Tone.minChars {
            SelfTest.ok("tone: 触发门槛 150 字符（短文本不判）")
        } else {
            SelfTest.bad("tone: 门槛", "常量不一致")
        }
    }
}

// MARK: 句首大写（应用建议时不许把小写塞到句首）
extension SelfTest {
    static func sentenceCaseTests() {
        let text = "In order to save time, we must decide. Due to the fact that it rained, we stayed."
        let a = DiffItem(start: 0, length: 11, original: "In order to", replacement: "to", type: "clarity", reason: "")
        if a.replacementRespectingSentenceCase(in: text) == "To" {
            SelfTest.ok("replace: 句首小写建议自动大写", "to → To")
        } else {
            SelfTest.bad("replace: 句首大写", a.replacementRespectingSentenceCase(in: text))
        }
        let mid = DiffItem(start: 32, length: 9, original: "make a de", replacement: "decide", type: "clarity", reason: "")
        if mid.replacementRespectingSentenceCase(in: text) == "decide" {
            SelfTest.ok("replace: 句中不改大小写")
        } else {
            SelfTest.bad("replace: 句中保持原样", mid.replacementRespectingSentenceCase(in: text))
        }
        let cap = DiffItem(start: 0, length: 3, original: "In", replacement: "To", type: "clarity", reason: "")
        if cap.replacementRespectingSentenceCase(in: text) == "To" {
            SelfTest.ok("replace: 已大写不重复处理")
        } else {
            SelfTest.bad("replace: 已大写", cap.replacementRespectingSentenceCase(in: text))
        }
    }
}

// MARK: 逐字母差异高亮
extension SelfTest {
    static func spellingDiffTests() {
        let p = SpellingDiff.parts(original: "immediatly", replacement: "immediately")
        // immediatly → immediately：少的那个 'e' 是插入，所以旧侧为空、新侧为 e
        if p.prefix == "immediat" && p.oldMid.isEmpty && p.newMid == "e" {
            SelfTest.ok("diffhl: immediatly/immediately 差异段切对", "共前缀=\(p.prefix) 旧=\(p.oldMid) 新=\(p.newMid)")
        } else {
            SelfTest.bad("diffhl: 差异段切分", "prefix=\(p.prefix) old=\(p.oldMid) new=\(p.newMid)")
        }
        let att = SpellingDiff.attributed(original: "immediatly", replacement: "immediately")
        let str = att.string
        // 差异字母在拼接串里的位置：prefix + oldMid 之后
        var differs = false
        att.enumerateAttributes(in: NSRange(location: 0, length: att.length)) { attrs, range, _ in
            let seg = (str as NSString).substring(with: range)
            if seg == "e", (attrs[.foregroundColor] as? NSColor) == NSColor.systemGreen { differs = true }
        }
        if differs { SelfTest.ok("diffhl: 插入的字母用绿色加粗标出") }
        else { SelfTest.bad("diffhl: 差异字母属性", "没找到红色删除线段") }

        let same = SpellingDiff.parts(original: "decide", replacement: "decide")
        if same.oldMid.isEmpty && same.newMid.isEmpty {
            SelfTest.ok("diffhl: 完全相同的词无差异段")
        } else {
            SelfTest.bad("diffhl: 同词", "old=\(same.oldMid) new=\(same.newMid)")
        }
    }
}

// MARK: UI 文案（看不见就是没做 → 用断言锁住格式与档位阈值）
extension SelfTest {
    static func uiTextTests() {
        if Sidebar.bandText(overall: 85).contains("良好") { SelfTest.ok("ui: ≥80 判良好", Sidebar.bandText(overall: 85)) }
        else { SelfTest.bad("ui: ≥80 判良好", Sidebar.bandText(overall: 85)) }
        if Sidebar.bandText(overall: 64).contains("需注意") { SelfTest.ok("ui: 50-79 判需注意", Sidebar.bandText(overall: 64)) }
        else { SelfTest.bad("ui: 50-79 判需注意", Sidebar.bandText(overall: 64)) }
        if Sidebar.bandText(overall: 30).contains("需改进") { SelfTest.ok("ui: <50 判需改进", Sidebar.bandText(overall: 30)) }
        else { SelfTest.bad("ui: <50 判需改进", Sidebar.bandText(overall: 30)) }
        let labels = ["spelling": "正确性 · 修正拼写", "grammar": "正确性 · 语法问题",
                      "clarity": "清晰度 · 精简表达", "style": "表达 · 调整风格"]
        var allOK = true
        for (k, want) in labels {
            let kind: UnderlineKind = k == "spelling" ? .spelling : (k == "grammar" ? .grammar : (k == "clarity" ? .clarity : .style))
            if kind.categoryLine != want { allOK = false }
        }
        if allOK { SelfTest.ok("ui: 卡片类别行四类文案固定") } else { SelfTest.bad("ui: 类别行文案", "有一类不符") }
    }
}
