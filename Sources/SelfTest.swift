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
        if argv.contains("--live") { liveTests() }

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
