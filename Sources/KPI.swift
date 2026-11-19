// KPI.swift — 画线率（rectCount / itemCount）按 App 统计
//
// 为什么要有它：日志里能算出来「有建议」和「画出线」是两个数，差值就是真实缺口。
// 旧账（今日之前）：Safari 850 有建议 / 112 有线 = 13%，Mail 68/21 = 31%，QQ·Hermes·TextEdit 100%。
// 规矩：任何「链路通了」的结论必须同时报这个比值，低于目标就不算做完。

import Foundation

enum KPI {
    struct Row {
        var app: String
        var checks = 0
        var withItems = 0
        var withRects = 0
        var pathTop: [String: Int] = [:]
        var drawRate: Double { withItems == 0 ? 0 : Double(withRects) / Double(withItems) }
    }

    static func run(_ argv: [String]) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let logPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/EnglishWriter/check-log.jsonl")
        guard let data = FileManager.default.contents(atPath: logPath),
              let text = String(data: data, encoding: .utf8) else {
            print("FAIL 读不到 check-log.jsonl：\(logPath)")
            return 1
        }
        var rows: [String: Row] = [:]
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let e = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let kind = e["kind"] as? String ?? ""
            // 只算 render：web-poll 记的是「读到几块正文」，不是建议条数。
            // 混进来会把「块数 850 / 有线 112」误算成画线率 13%（11-19 实测踩过）。
            guard kind == "render" else { continue }
            let app = e["app"] as? String ?? "?"
            let ic = e["itemCount"] as? Int ?? 0
            let rc = e["rectCount"] as? Int ?? 0
            var r = rows[app] ?? Row(app: app)
            r.checks += 1
            if ic > 0 { r.withItems += 1 }
            if ic > 0 && rc > 0 { r.withRects += 1 }
            let p = String((e["path"] as? String ?? "-").prefix(14))
            r.pathTop[p, default: 0] += 1
            rows[app] = r
        }

        let sorted = rows.values.filter { $0.checks >= 3 }.sorted { $0.checks > $1.checks }
        print("--- 画线率（rectCount / 有建议次数）---")
        print(String(format: "%-18@ %6@ %6@ %6@ %8@  %@", "App" as NSString, "检查" as NSString,
                     "有建议" as NSString, "有线" as NSString, "画线率" as NSString, "主路径" as NSString))
        for r in sorted {
            let top = r.pathTop.max { $0.value < $1.value }?.key ?? "-"
            print(String(format: "%-18@ %6d %6d %6d %7.1f%%  %@",
                         r.app as NSString, r.checks, r.withItems, r.withRects, r.drawRate * 100, top))
        }

        // 目标：原生与浏览器宿主都 ≥ 90%
        var below: [String] = []
        for r in sorted where r.withItems >= 5 && r.drawRate < 0.9 {
            below.append("\(r.app) \(Int(r.drawRate * 100))%")
        }
        if below.isEmpty {
            print("=== KPI：PASS（所有 ≥5 次样本的 App 画线率 ≥90%）===")
            return 0
        }
        print("=== KPI：FAIL（低于 90%：" + below.joined(separator: "、") + "）===")
        return 1
    }
}
