// LocalAPI.swift — 给浏览器扩展用的本机 HTTP 接口（只监听 127.0.0.1）
//
// 为什么需要它：Chrome 里拿 DOM 的是扩展，但引擎（LanguageTool / 模型 / 术语护栏 / 中文门控）
// 只能在 App 这一侧复用 —— 否则同一套护栏要在 JS 里再写一遍，必然漂移。
//
// 安全边界：
//   · 只绑 127.0.0.1（不对外监听）
//   · 必须带 token（首次启动生成，落在 Application Support，不预设、不写死在代码里）
//   · CORS 只回显 chrome-extension:// 与 http://localhost 来源
//
// 路由：
//   GET  /v1/health   → {ok, version, lt, port, tokenRequired}
//   POST /v1/check    → {"text","language"} → {edits:[{start,length,original,replacement,type,reason}], engine, elapsedMs, skipped}
//
// 用法：App 启动即监听；端口默认 17817，可用 EW_API_PORT 覆盖。

import Foundation
import Network

final class LocalAPI {

    static let shared = LocalAPI()

    private let queue = DispatchQueue(label: "com.wanyi.englishwriter.api")
    private var listener: NWListener?
    private(set) var token: String = ""
    private(set) var running = false
    private(set) var port: UInt16 = 17817

    // MARK: 生命周期

    func start() {
        guard listener == nil else { return }
        port = UInt16(ProcessInfo.processInfo.environment["EW_API_PORT"] ?? "") ?? 17817
        token = Self.loadOrCreateToken()
        do {
            // 只绑回环：NWListener 默认监听所有网卡（IPv6 *），必须显式限定 127.0.0.1
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                     port: NWEndpoint.Port(rawValue: port)!)
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.running = true
                    FileHandle.standardError.write("[api] listening 127.0.0.1:\(self?.port ?? 0)\n".data(using: .utf8)!)
                case .failed, .cancelled:
                    self?.running = false
                default: break
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            FileHandle.standardError.write("[api] start failed: \(error)\n".data(using: .utf8)!)
        }
    }

    var tokenPath: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/EnglishWriter"
        return dir + "/api-token.txt"
    }

    /// token 只生成一次；不预置默认值（爹地口径：不给预设默认值）
    private static func loadOrCreateToken() -> String {
        let dir = NSHomeDirectory() + "/Library/Application Support/EnglishWriter"
        let path = dir + "/api-token.txt"
        if let s = try? String(contentsOfFile: path, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count >= 16 { return t }
        }
        let t = UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.prefix(8)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? (t + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return t
    }

    // MARK: 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let d = data { buf.append(d) }
            if error != nil { conn.cancel(); return }

            if let req = Self.parse(buf) {
                self.route(req, on: conn)
                return
            }
            if isComplete { conn.cancel(); return }
            if buf.count > 4 * 1024 * 1024 { conn.cancel(); return }
            self.receive(conn, buffer: buf)
        }
    }

    struct Request {
        var method = ""
        var path = ""
        var headers: [String: String] = [:]
        var body: Data = Data()
        var origin: String? { headers["origin"] }
        func header(_ k: String) -> String? { headers[k.lowercased()] }
    }

    /// 收齐 header + Content-Length 指定长度才算解析成功
    private static func parse(_ data: Data) -> Request? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(data: data[data.startIndex..<sep.lowerBound], encoding: .utf8) ?? ""
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let first = lines.removeFirst().components(separatedBy: " ")
        guard first.count >= 2 else { return nil }
        var r = Request()
        r.method = first[0].uppercased()
        r.path = first[1].components(separatedBy: "?")[0]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[line.startIndex..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            r.headers[k] = v
        }
        let bodyStart = sep.upperBound
        let body = data[bodyStart...]
        let need = Int(r.headers["content-length"] ?? "0") ?? 0
        if body.count < need { return nil }
        r.body = Data(body.prefix(need))
        return r
    }

    private func route(_ req: Request, on conn: NWConnection) {
        if req.method == "OPTIONS" {
            send(conn, status: 204, json: nil, origin: req.origin)
            return
        }
        switch (req.method, req.path) {
        case ("GET", "/v1/health"):
            let body: [String: Any] = ["ok": true, "version": "0.2.0", "port": Int(port),
                                       "lt": LocalEngine.baseURLString, "tokenRequired": true]
            send(conn, status: 200, json: body, origin: req.origin)
        case ("POST", "/v1/check"):
            guard let tok = req.header("x-ew-token"), tok == token else {
                send(conn, status: 401, json: ["error": "bad token"], origin: req.origin)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty else {
                send(conn, status: 400, json: ["error": "text required"], origin: req.origin)
                return
            }
            let language = obj["language"] as? String ?? "en-GB"
            let mode = obj["mode"] as? String ?? "full"      // "local" = 只要本地即时结果
            Task { [weak self] in
                let payload = await LocalAPI.check(text: text, language: language, mode: mode)
                self?.send(conn, status: 200, json: payload, origin: req.origin)
            }
        case ("POST", "/v1/rewrite"):
            guard let tok = req.header("x-ew-token"), tok == token else {
                send(conn, status: 401, json: ["error": "bad token"], origin: req.origin)
                return
            }
            guard let obj = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
                  let text = obj["text"] as? String, !text.isEmpty else {
                send(conn, status: 400, json: ["error": "text required"], origin: req.origin)
                return
            }
            Task { [weak self] in
                let payload = await LocalAPI.rewrite(text: text)
                self?.send(conn, status: 200, json: payload, origin: req.origin)
            }
        default:
            send(conn, status: 404, json: ["error": "not found"], origin: req.origin)
        }
    }

    // MARK: 检查（复用原生同一条链：中文门控 → LT → 术语护栏）

    /// 改写 / 语气：与桌面端 RewriteFlow 同一条链（同一个提示词、同一个模型）。
    /// 模型没配就直接说没配，不假装给了候选。
    static func rewrite(text: String) async -> [String: Any] {
        let t0 = Date()
        let cfg = SettingsStore.load()
        guard Rewrite.isAvailable(cfg) else {
            return ["candidates": [], "error": "model-not-configured", "elapsedMs": 0]
        }
        do {
            let cands = try await Rewrite.suggest(segment: text, config: cfg)
            let elapsed = Int(Date().timeIntervalSince(t0) * 1000)
            let list: [[String: Any]] = cands.map {
                ["label": $0.label, "text": $0.appliedText(to: text), "note": $0.note]
            }
            return ["candidates": list, "elapsedMs": elapsed]
        } catch {
            return ["candidates": [], "error": "\(error)", "elapsedMs": Int(Date().timeIntervalSince(t0) * 1000)]
        }
    }

    static func check(text: String, language: String, mode: String = "full") async -> [String: Any] {
        // 中文零干扰：口径统一到 LanguageGate.cjkGate（这里原来自带一个 0.40，是第四个副本）
        if LanguageGate.cjkRatio(text) > LanguageGate.cjkGate {
            return ["edits": [], "engine": "skipped-cjk", "skipped": "cjk", "elapsedMs": 0]
        }

        let t0 = Date()
        let ltOn = EnginePrefs.ltEnabled()
        var ltOK = ltOn ? await LocalEngine.available() : false
        if ltOn && !ltOK {
            // 可能是刚被拉起来还没就绪；探活缓存 60s 会把「未就绪」当成「不可用」，
            // 这里强制复探一次（LT 热态 300ms 内返回），免得白丢一轮语法
            LocalEngineBootstrap.ensureRunningThrottled()
            ltOK = await LocalEngine.available(force: true)
        }
        if ltOn && ltOK {
            // 走本地 LT（下面继续）
        } else if mode == "local" {
            // 即时通道：只用本地规则（毫秒级），让界面先有线，模型结果随后覆盖
            let items = CategoryPrefs.filterForDisplay(
                DiffSanitize.consolidate(SpellCheck.items(in: text) + LocalGrammar.apply(to: text)
                                         + StyleRules.apply(to: text), in: text))
            return ["edits": items.map { ["start": $0.start, "length": $0.length,
                                           "original": $0.original, "replacement": $0.replacement,
                                           "type": $0.type, "reason": $0.reason] },
                    "engine": "local-instant", "elapsedMs": Int(Date().timeIntervalSince(t0) * 1000)]
        } else if SettingsStore.load().isComplete {
            // LT 关但模型配了：用模型跑语法（与桌面端同一条 Diff.review），
            // 本地再补拼写/语法规则/清晰度/风格 —— 浏览器里的检查质量不该比桌面端低
            let cfg = SettingsStore.load()
            do {
                let out = try await InlineEngine.review(text: text, config: cfg)
                let merged = CategoryPrefs.filterForDisplay(
                    DiffSanitize.consolidate(SpanGuard.filterModelItems(out.items, in: text) + SpellCheck.items(in: text)
                                             + LocalGrammar.apply(to: text) + StyleRules.apply(to: text), in: text))
                let edits = merged.map { it -> [String: Any] in
                    ["start": it.start, "length": it.length, "original": it.original,
                     "replacement": it.replacement, "type": it.type, "reason": it.reason]
                }
                return ["edits": edits, "engine": "model", "elapsedMs": Int(Date().timeIntervalSince(t0) * 1000)]
            } catch {
                // 模型失败就老实地退到本地，并在 engine 里说明，不假装
                let items = CategoryPrefs.filterForDisplay(
                    DiffSanitize.consolidate(SpellCheck.items(in: text) + LocalGrammar.apply(to: text)
                                             + StyleRules.apply(to: text), in: text))
                return ["edits": items.map { ["start": $0.start, "length": $0.length,
                                               "original": $0.original, "replacement": $0.replacement,
                                               "type": $0.type, "reason": $0.reason] },
                        "engine": "local-fallback(model failed)", "error": "\(error)",
                        "elapsedMs": Int(Date().timeIntervalSince(t0) * 1000)]
            }
        } else {
            // LT 关、模型也没配：只返回零进程能做的（拼写 + 本地语法/清晰度/风格），并如实标注
            let items = CategoryPrefs.filterForDisplay(
                DiffSanitize.consolidate(SpellCheck.items(in: text) + LocalGrammar.apply(to: text)
                                         + StyleRules.apply(to: text), in: text))
            return ["edits": items.map { ["start": $0.start, "length": $0.length, "original": $0.original,
                                          "replacement": $0.replacement, "type": $0.type, "reason": $0.reason] },
                    "engine": ltOn ? "lt-offline" : "local-only",
                    "elapsedMs": Int(Date().timeIntervalSince(t0) * 1000)]
        }
        do {
            let out = try await LocalEngine.review(text: text, language: language)
            // 四类齐：LT（拼写/语法）+ 本地规则（清晰度/风格），统一收口
            let merged = CategoryPrefs.filterForDisplay(
                DiffSanitize.consolidate(out.items + SpellCheck.items(in: text) + StyleRules.apply(to: text), in: text))
            let edits = merged.map { it -> [String: Any] in
                ["start": it.start, "length": it.length, "original": it.original,
                 "replacement": it.replacement, "type": it.type, "reason": it.reason]
            }
            return ["edits": edits, "engine": "languagetool",
                    "elapsedMs": Int(Date().timeIntervalSince(t0) * 1000)]
        } catch {
            return ["edits": [], "engine": "error", "error": "\(error)",
                    "elapsedMs": Int(Date().timeIntervalSince(t0) * 1000)]
        }
    }

    // MARK: 响应

    private func send(_ conn: NWConnection, status: Int, json: [String: Any]?, origin: String?) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) } ?? Data()
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : (status == 401 ? "Unauthorized" : (status == 204 ? "No Content" : "Error")))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\n"
        // 只放行扩展与本地来源；token 仍是真正的门
        if let o = origin, o.hasPrefix("chrome-extension://") || o.hasPrefix("http://localhost") || o.hasPrefix("http://127.0.0.1") {
            head += "Access-Control-Allow-Origin: \(o)\r\n"
            head += "Vary: Origin\r\n"
        } else if origin != nil {
            head += "Access-Control-Allow-Origin: null\r\n"
        }
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: content-type, x-ew-token\r\n"
        head += "Access-Control-Max-Age: 600\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
