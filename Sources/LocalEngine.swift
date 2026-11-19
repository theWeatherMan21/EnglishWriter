// LocalEngine.swift — LanguageTool 本地引擎（即时检查主力：毫秒级、零成本、不出网）
//
// 与 LLM 通道产出同一种 [DiffItem]，上层渲染 / 卡片 / 接受 完全不区分来源。
// 服务地址默认 127.0.0.1:8081（scripts/languagetool-up.sh 拉起），探活 300ms 超时。

import Foundation

// MARK: - 不该被检查的区间（行业术语 / 单据号 / 编码 / 签名）

enum SpanGuard {
    /// 这些区间里的建议一律丢弃：画在箱号上或把 FCL 改成别的，都是误报
    static func guardedRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        var out: [NSRange] = []
        let patterns: [(String, NSRegularExpression.Options)] = [
            (#"\b[A-Z]{4}\d{7}\b"#, []),                       // 箱号（4 位字母 + 7 位数字）
            (#"\b\d{6,}\b"#, []),                             // 长数字（订舱号/工作号/BL 号）
            (#"\b[A-Z]{5}\b"#, []),                           // 港口码 CNTAO / CNSHA
            (#"\b[A-Z]{2,4}\d{4,}\b"#, []),                   // HBL123456 / ETA2026
            (#"\b[\w.+-]+@[\w-]+\.[\w.]+\b"#, []),            // 邮箱
            (#"https?://\S+"#, []),                           // 链接
            (#"\b\d{1,3}([,. ]\d{3})*(\.\d{1,4})?\b"#, []),   // 金额 / 数字
            (#"\b(T/T|L/C|D/P|D/A|FOB|CIF|CFR|FCA|EXW|DDP|DAP|CPT|CIP)\b"#, []),
        ]
        // 行业术语（多词）：模型常把 free time 改成 free time allowed、把 demurrage 当拼写错。
        // 这些是业务口径，不是语法错，一律保护起来（11-19 深度检查实测抓到 1 条误报）。
        let terms = ["free time", "demurrage", "detention", "bill of lading", "delivery order",
                     "letter of credit", "packing list", "shipping instruction", "booking note",
                     "arrival notice", "certificate of origin", "port of discharge", "port of loading",
                     "container yard", "container freight station", "telex release", "switch b/l",
                     "master bill of lading", "house bill of lading"]
        let termPattern = "\\b(" + terms.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b"
        if let re = try? NSRegularExpression(pattern: termPattern, options: [.caseInsensitive]) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out.append(m.range)
            }
        }
        for (p, o) in patterns {
            if let re = try? NSRegularExpression(pattern: p, options: o) {
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    out.append(m.range)
                }
            }
        }
        // 行业术语：按原样形态（含大小写）比对，出现即护住
        for term in industryTerms {
            var searchFrom = 0
            while searchFrom < ns.length {
                let r = ns.range(of: term, options: [], range: NSRange(location: searchFrom, length: ns.length - searchFrom))
                if r.location == NSNotFound { break }
                // 只护「独立 token」：前后不能紧贴字母数字
                let before = r.location > 0 ? ns.character(at: r.location - 1) : 32
                let afterIdx = r.location + r.length
                let after = afterIdx < ns.length ? ns.character(at: afterIdx) : 32
                if !isAlnum(before) && !isAlnum(after) { out.append(r) }
                searchFrom = r.location + max(r.length, 1)
            }
        }
        return out
    }

    private static func isAlnum(_ c: unichar) -> Bool {
        guard let u = Unicode.Scalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(u)
    }

    /// 签名块起点：命中即认为后面全是签名，不检查
    static let signatureMarkers = [
        "Best regards", "Kind regards", "Regards,", "BR,", "Cordialement",
        "Saygılarımla", "Met vriendelijke groet", "Mit freundlichen Grüßen",
    ]

    static func signatureStart(in text: String) -> Int? {
        let ns = text as NSString
        var best: Int?
        for m in signatureMarkers {
            let r = ns.range(of: m)
            if r.location != NSNotFound, best == nil || r.location < best! { best = r.location }
        }
        return best
    }

    static func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        NSIntersectionRange(a, b).length > 0
    }
}

/// 行业术语（大小写敏感；只护这些写法）
let industryTerms: [String] = [
    "FCL", "LCL", "BL", "B/L", "ETD", "ETA", "ATA", "ATD", "SO", "SI", "VGM",
    "CY", "CFS", "THC", "POD", "POL", "HBL", "MBL", "D/O", "C/O", "IMO", "HS",
    "DG", "TEU", "FEU", "DAP", "CIF", "FOB", "CFR", "DDP", "EXW", "MSDS",
    "PO", "PI", "CI", "PL", "SCAC", "AMF", "ISF", "BCO", "NVOCC", "LCL/FCL",
    "shipper", "consignee", "demurrage", "detention", "stowage", "manifest",
]

// MARK: - LanguageTool

struct LTMatch: Decodable {
    struct Rule: Decodable {
        struct Category: Decodable { let id: String }
        let id: String
        let category: Category?
        let issueType: String?
    }
    struct Replacement: Decodable { let value: String }
    let message: String
    let offset: Int
    let length: Int
    let replacements: [Replacement]?
    let rule: Rule
}

struct LTResponse: Decodable {
    let matches: [LTMatch]
}

enum LocalEngine {
    /// 引擎地址：设置面板可改；没填就是本机 8081（默认值不落进配置）
    static var baseURLString: String {
        get { EnginePrefs.ltBaseURL() }
        set { EnginePrefs.setLTBaseURL(newValue) }
    }

    private static var lastProbe: (ok: Bool, at: Date) = (false, .distantPast)

    // MARK: 闲置退出（2026-11-18：LT 是 JVM，常驻 368MB，闲置就得让位）
    //
    // 实测：Xmx192m → OOM；Xmx256m → 可用、冷启动 1.8s、RSS 368MB。
    // 堆调小压不动 RSS，真正省内存只有「不检查时别驻留」这条路。
    private(set) static var lastUsed: Date = .distantPast
    static func touch() { lastUsed = Date() }

    /// 闲置秒数（默认 600s；EW_LT_IDLE 可覆盖，测试用短值）
    static var idleLimit: TimeInterval {
        Double(ProcessInfo.processInfo.environment["EW_LT_IDLE"] ?? "") ?? 600
    }

    /// 是否还在跑（用 pgrep 认 java + languagetool jar，避免误杀别的 java）
    static func runningPID() -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", "languagetool-server.jar"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Int32(out.split(separator: "\n").first.map(String.init) ?? "")
    }

    /// 闲置超时就退出；返回是否真的退了一个
    @discardableResult
    static func idleExitIfNeeded() -> Bool {
        guard let pid = runningPID() else { return false }
        // lastUsed 还是「从未用过」时不能当闲置：外面/自举刚起的 JVM 会被 30s 巡检秒杀（真机踩过）
        if lastUsed == .distantPast { lastUsed = Date(); return false }
        let idle = Date().timeIntervalSince(lastUsed)
        guard idle >= idleLimit else { return false }
        kill(pid, SIGTERM)
        usleep(400_000)
        if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        lastProbe = (false, .distantPast)
        FileHandle.standardError.write("[lt] idle \(Int(idle))s >= \(Int(idleLimit))s → 已退出 (pid \(pid))\n".data(using: .utf8)!)
        return true
    }

    /// App 起来时挂一次兜底巡检（每 30s 看一次；不是轮询服务器，只看本地进程）
    static func startIdleWatchdog() {
        Task.detached {
            while true {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                _ = idleExitIfNeeded()
            }
        }
    }

    /// 探活结果缓存 60 秒：避免每句话都探测一次（不是轮询 Timer）
    static func available(force: Bool = false) async -> Bool {
        if !force, Date().timeIntervalSince(lastProbe.at) < 60 { return lastProbe.ok }
        guard let url = URL(string: baseURLString + "/v2/languages") else {
            lastProbe = (false, Date()); return false
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.6
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            lastProbe = (ok, Date())
            if ok { touch() }     // 探活成功就算「刚用过」，否则看门狗把刚落地的 JVM 当闲置秒杀
            return ok
        } catch {
            lastProbe = (false, Date())
            return false
        }
    }

    /// 一句 → 逐条 diff（UTF-16 偏移，和 AX / NSString 口径一致）
    /// 构造 /v2/check 请求。抽成纯函数是为了能断言「换了方言，请求参数真的变」——
    /// 这条以前只能靠真人切完看结果，坏没坏看不出来。
    static func checkRequest(text: String, language: String,
                             base: String = baseURLString) -> URLRequest? {
        guard let url = URL(string: base + "/v2/check") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 6
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            .init(name: "text", value: text),
            .init(name: "language", value: language),
            .init(name: "level", value: "picky"),
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        return req
    }

    static func review(text: String, language: String = "en-GB",
                       session: URLSession = .shared) async throws -> InlineOutcome {
        guard let req = checkRequest(text: text, language: language), let url = req.url else {
            throw ReviewFailure.notConfigured
        }

        touch()
        let t0 = Date()
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .timedOut {
            throw ReviewFailure.timeout
        } catch {
            throw ReviewFailure.network((error as NSError).localizedDescription)
        }
        let elapsed = Date().timeIntervalSince(t0)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ReviewFailure.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        guard let parsed = try? JSONDecoder().decode(LTResponse.self, from: data) else {
            throw ReviewFailure.badJSON(String(data: data, encoding: .utf8) ?? "")
        }

        // 过滤：护住区间内的、没有替换建议的、签名之后的、个人词典里的
        let items = buildItems(matches: parsed.matches, text: text)
        return InlineOutcome(items: DiffSanitize.clean(items, in: text),
                             endpoint: url.absoluteString,
                             model: "languagetool (\(language))",
                             elapsed: elapsed)
    }

    /// 原始命中 → 可上屏条目。纯函数：不碰网络、不碰 UI，单测直接喂构造数据。
    /// 四条丢弃规则都在这里，别在别处复制：签名块之后 / 护栏区间 / 词典词 / 越界或无替换。
    static func buildItems(matches: [LTMatch], text: String) -> [DiffItem] {
        let ns = text as NSString
        let guarded = SpanGuard.guardedRanges(in: text)
        let sigStart = SpanGuard.signatureStart(in: text)
        let raw = matches.compactMap { m -> DiffItem? in
            let r = NSRange(location: m.offset, length: m.length)
            if let s = sigStart, r.location >= s { return nil }
            if guarded.contains(where: { SpanGuard.intersects($0, r) }) { return nil }
            guard let repl = m.replacements?.first?.value, !repl.isEmpty else { return nil }
            guard r.location >= 0, r.location + r.length <= ns.length else { return nil }
            let original = ns.substring(with: r)
            if original == repl { return nil }
            return DiffItem(start: r.location, length: r.length,
                            original: original, replacement: repl,
                            type: kindFor(m).rawValue,
                            reason: m.message)
        }
        // 个人词典 / 忽略规则：与远端 diff 通道共用同一份实现（PersonalFilter），别在这里重写一份
        return PersonalFilter.apply(raw, in: text)
    }

    private static func kindFor(_ m: LTMatch) -> UnderlineKind {
        switch (m.rule.issueType ?? "").lowercased() {
        case "misspelling": return .spelling
        case "typographical", "whitespace", "duplication": return .spelling
        case "style", "register", "redundancy": return .style
        case "grammar", "inconsistency": return .grammar
        default: break
        }
        switch (m.rule.category?.id ?? "").uppercased() {
        case "TYPOS", "CASING", "PUNCTUATION": return .spelling
        case "STYLE", "REDUNDANCY", "PLAIN_ENGLISH": return .style
        case "CONFUSED_WORDS", "MISC": return .clarity
        default: return .grammar
        }
    }
}
