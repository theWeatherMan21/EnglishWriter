// AppLog.swift — 常驻日志落盘（2026-11-18）
//
// 读者是 agent（自检 cron / 婉宜 / 知澜），**不是用户**。所以：
//   · 界面里不出现「导出日志」「复制诊断」按钮；
//   · 排障靠 `~/Library/Logs/EnglishWriter/app.log` + selfcheck 探针；
//   · 格式统一 `YYYY-MM-DD HH:mm:ss LEVEL tag key=value`，normal 正则一条就能覆盖。
//
// 为什么现在才有：v0.1 纪律是「不常驻」，所以一直只有 CLI 探针往 out/ 写。
// 11-16 改成 Grammarly 同款常驻后，App 本体没有任何可观测输出 —— UI 一砍就真的瞎了。

import Foundation

enum AppLog {
    static let dir: URL = {
        let d = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/EnglishWriter", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    static var file: URL { dir.appendingPathComponent("app.log") }

    private static let queue = DispatchQueue(label: "com.wanyi.englishwriter.applog")

    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    static func info(_ tag: String, _ msg: String) { write("INFO", tag, msg) }
    static func error(_ tag: String, _ msg: String) { write("ERROR", tag, msg) }

    static func write(_ level: String, _ tag: String, _ msg: String) {
        let line = "\(stamp()) \(level) \(tag) \(msg)\n"
        queue.sync {
            let p = file
            let dir = p.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 5MB 滚动一份，避免无限增长（读者只需要最近现场）
            if let attrs = try? FileManager.default.attributesOfItem(atPath: p.path),
               let size = attrs[.size] as? Int, size > 5 * 1024 * 1024 {
                let old = dir.appendingPathComponent("app.log.1")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: p, to: old)
            }
            if let h = try? FileHandle(forWritingTo: p) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? line.write(to: p, atomically: true, encoding: .utf8)
            }
        }
    }
}
