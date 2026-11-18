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
            Task { [weak self] in
                let payload = await LocalAPI.check(text: text, language: language)
                self?.send(conn, status: 200, json: payload, origin: req.origin)
            }
        default:
            send(conn, status: 404, json: ["error": "not found"], origin: req.origin)
        }
    }

    // MARK: 检查（复用原生同一条链：中文门控 → LT → 术语护栏）

    static func check(text: String, language: String) async -> [String: Any] {
        // 中文零干扰：CJK 占比 > 0.40 直接不查（和原生完全同一口径）
        let cjk = text.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let ratio = text.isEmpty ? 0 : Double(cjk) / Double(text.unicodeScalars.count)
        if ratio > 0.40 { return ["edits": [], "engine": "skipped-cjk", "skipped": "cjk", "elapsedMs": 0] }

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
        } else {
            // 没开 LT：只返回零进程能做的（拼写 + 清晰度/风格），并如实标注
            let items = DiffSanitize.consolidate(SpellCheck.items(in: text) + StyleRules.apply(to: text), in: text)
            return ["edits": items.map { ["start": $0.start, "length": $0.length, "original": $0.original,
                                          "replacement": $0.replacement, "type": $0.type, "reason": $0.reason] },
                    "engine": ltOn ? "lt-offline" : "local-only",
                    "elapsedMs": Int(Date().timeIntervalSince(t0) * 1000)]
        }
        do {
            let out = try await LocalEngine.review(text: text, language: language)
            // 四类齐：LT（拼写/语法）+ 本地规则（清晰度/风格），统一收口
            let merged = DiffSanitize.consolidate(out.items + StyleRules.apply(to: text), in: text)
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
