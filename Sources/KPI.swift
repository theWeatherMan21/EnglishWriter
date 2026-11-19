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

        // 点击命中率：只统计「点的 App 就是画线的 App」那部分。
        // 点在别的 App 上 miss 是正确行为（那些线不在那儿），混进来会把命中率算低。
        var inDomain = 0, inHit = 0, crossApp = 0, emptyLine = 0
        for line in text.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let e = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
            let kind = e["kind"] as? String ?? ""
            guard kind == "click-hit" || kind == "click-miss" else { continue }
            let err = e["err"] as? String ?? ""
            let rects = e["rectCount"] as? Int ?? 0
            // 新格式：owner=Mail(1343) front=Mail(1343)
            let owner = err.range(of: "owner=").map { String(err[$0.upperBound...].prefix(while: { $0 != "(" })) }
            let front = err.range(of: "front=").map { String(err[$0.upperBound...].prefix(while: { $0 != "(" })) }
            if owner == nil || front == nil { continue }        // 旧格式没有 App 信息，无法判定
            if rects == 0 { emptyLine += 1; continue }          // 屏幕上本来没有线，点哪儿都算 miss
            if owner != front { crossApp += 1; continue }        // 点在别的 App 上：正常 miss
            inDomain += 1
            if kind == "click-hit" { inHit += 1 }
        }
        if inDomain > 0 && inDomain < 5 {
            let rate = Double(inHit) / Double(inDomain) * 100
            print(String(format: "--- 点击命中率：样本不足（%d 次，命中 %d 次 = %.1f%%），本次不判定 ---",
                         inDomain, inHit, rate))
            print("  判据：同一 App 且屏幕上有线 ≥5 次样本才评；跨 App \(crossApp) 次、无线 \(emptyLine) 次已排除")
        } else if inDomain >= 5 {
            let rate = Double(inHit) / Double(inDomain) * 100
            print(String(format: "--- 点击命中率（只在「同一个 App、且屏幕上有线」时统计）---"))
            print(String(format: "  同一 App 且有线：%d 次，命中 %d 次 = %.1f%%", inDomain, inHit, rate))
            print("  排除：跨 App 点击 \(crossApp) 次（那些线不在这儿，正常 miss）；无线的点击 \(emptyLine) 次")
            if rate < 95 {
                print(String(format: "=== 点击 KPI：FAIL（目标 ≥95%%，当前 %.1f%%）===", rate))
                return 1
            }
            print("=== 点击 KPI：PASS（≥95%）===")
        } else {
            print("--- 点击命中率：还没有带坐标的样本（新格式上线后需要真人点几次）---")
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
