// RequestLog.swift — 每次模型请求体摘要落盘（诊断用，不进仓库）
//
// 为什么要有它：11-19 深度检查花了 74 秒，事后无法判断到底是「没传 reasoning_effort」
// 还是「传了端点不认」。一行摘要就能分清：model / reasoning / max_tokens / 句数 / 字数。
// 位置：~/Library/Application Support/EnglishWriter/llm-requests.jsonl

import Foundation

enum RequestLog {
    private static let q = DispatchQueue(label: "ew.reqlog")
    // 同步写：CLI 模式跑完立刻 exit，异步队列会被直接丢掉（踩过：日志一条都没有）

    static func append(model: String, reasoning: String, maxTokens: Int, sentences: Int, chars: Int,
                       resp: String = "") {
        let row: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "model": model, "reasoning_effort": reasoning,
            "max_tokens": maxTokens, "sentences": sentences, "chars": chars,
            // 模型返回内容（截 500）：荒谬建议（如 my→my）应当在日志里一眼看到，不用手动复现
            "resp": String(resp.prefix(500)),
        ]
        guard let d = try? JSONSerialization.data(withJSONObject: row),
              var line = String(data: d, encoding: .utf8) else { return }
        line += "\n"
        q.sync {
            let fm = FileManager.default
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("EnglishWriter/llm-requests.jsonl")
            try? fm.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: base) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? line.write(to: base, atomically: true, encoding: .utf8)
            }
        }
    }
}
