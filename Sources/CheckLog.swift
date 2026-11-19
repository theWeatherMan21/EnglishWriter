// CheckLog.swift — 常驻模式下每次检查落一行 JSON（用户看不到，我用来复盘）
//
// 为什么必须落盘：爹地报「打了字没反应」时，我需要知道他打字那一刻 App 到底看到了什么
// （哪个 role、是不是 WebKit、读到几个字、命中几条、算出几个矩形）。没有这份日志，
// 只能靠猜，猜错就是第二次伤害。
//
// 位置：~/Library/Application Support/EnglishWriter/check-log.jsonl（不进仓库）
// 轮转：单文件超 5MB 就切成 .1（保留一份），永远不无限长

import Foundation

struct CheckLog {
    private static let q = DispatchQueue(label: "ew.checklog")
    /// 同一条事实不重写：轮询一秒一拍会把日志刷成废纸
    private static var lastKey = ""
    private static var lastAt = Date.distantPast
    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("EnglishWriter/check-log.jsonl")
    }

    /// O_APPEND + flock：常驻实例和 CLI 探针会同时往同一个文件写，
    /// 之前 seekToEndOfFile + write 不是原子的，实测出过 2 行被截断的残句（坏行）。
    private static func appendLineAtomically(_ line: String, to u: URL) {
        let fd = open(u.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else {
            try? line.write(to: u, atomically: true, encoding: .utf8)
            return
        }
        defer { close(fd) }
        _ = flock(fd, LOCK_EX)
        let data = Data(line.utf8)
        data.withUnsafeBytes { buf in
            if let base = buf.baseAddress { _ = write(fd, base, buf.count) }
        }
        _ = flock(fd, LOCK_UN)
    }

    static func append(_ e: InlineController.CheckEvent) {
        let row: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: e.at),
            "kind": e.kind, "pid": Int(e.pid), "app": e.app, "role": e.role,
            "textLen": e.textLen, "sentenceLen": e.sentenceLen,
            "itemCount": e.itemCount, "rectCount": e.rectCount,
            "elapsed": e.elapsed, "err": e.err, "path": e.path,
        ]
        let key = "\(e.kind)|\(e.app)|\(e.role)|\(e.textLen)|\(e.itemCount)|\(e.rectCount)|\(e.err)"
        if key == lastKey, Date().timeIntervalSince(lastAt) < 60 { return }
        lastKey = key; lastAt = Date()

        guard let data = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        q.async {
            let fm = FileManager.default
            let u = url
            try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? fm.attributesOfItem(atPath: u.path)[.size] as? Int, size > 5_000_000 {
                let old = u.deletingLastPathComponent().appendingPathComponent("check-log.1.jsonl")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: u, to: old)
            }
            appendLineAtomically(line, to: u)
        }
    }
}
