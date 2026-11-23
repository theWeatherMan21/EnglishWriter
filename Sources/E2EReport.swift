// E2EReport.swift — 把日志变成一条机器结论（--e2e-report）
//
// 为什么需要：爹地每测一次，我们都在用人眼在几千行日志里找「线出来了吗 / 点中了吗 / 写回去了吗」。
// 这一步必须自己算。用法：
//   ./build/英文写作助手 --e2e-report            # 看最近 10 分钟
//   ./build/英文写作助手 --e2e-report 30         # 看最近 30 分钟
//
// 判据（按真机顺序，缺一环就指出缺在哪）：
//   compose       出现 compose 判定=true 或 render(写信窗) → 认这是写信窗
//   lines         render 里 items>0 且 rects>0
//   click         click-hit 出现（click-miss 会打出差几像素）
//   accept        accept-begin → accept-write（若出现 accept-fail 直接判 FAIL 并带原因）
//   readback      无 accept-fail，且 accept-write 之后没有紧随的失败

import Foundation

enum E2EReport {

    struct Verdict {
        var window: String = ""
        var compose = false
        var lines = 0
        var clickHit = 0
        var clickMiss = 0
        var acceptBegin = 0
        var acceptWrite = 0
        var acceptFail = 0
        var lastFailReason = ""
        var lastDiag = ""
        var verdict = ""
    }

    static func logPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/EnglishWriter/app.log")
    }

    static func run(minutes: Int) -> Int32 {
        let path = logPath()
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            print("找不到日志：\(path)")
            return 2
        }
        let since = Date().addingTimeInterval(-Double(minutes) * 60)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        fmt.locale = Locale(identifier: "en_US_POSIX")

        var v = Verdict()
        v.window = "最近 \(minutes) 分钟"
        for line in raw.split(separator: "\n") {
            guard line.count > 19 else { continue }
            let stamp = String(line.prefix(19))
            guard let at = fmt.date(from: stamp), at >= since else { continue }
            let s = String(line)
            if s.contains("kind=render") {
                // items=N rects=M
                if let it = number(after: "items=", in: s), let rc = number(after: "rects=", in: s),
                   it > 0, rc > 0 {
                    v.lines += 1
                    v.compose = true
                    v.lastDiag = s.components(separatedBy: "err=").last ?? ""
                }
            }
            if s.contains("compose 判定") && s.contains("true") { v.compose = true }
            if s.contains("kind=click-hit") { v.clickHit += 1; v.lastDiag = s }
            if s.contains("kind=click-miss") { v.clickMiss += 1; v.lastDiag = s }
            if s.contains("kind=accept-begin") { v.acceptBegin += 1 }
            if s.contains("kind=accept-write") { v.acceptWrite += 1 }
            if s.contains("kind=accept-fail") {
                v.acceptFail += 1
                v.lastFailReason = s.components(separatedBy: "err=").last ?? ""
            }
        }

        print("== 真机闭环核对（\(v.window)）==")
        print("  写信窗识别   \(v.compose ? "是" : "否")")
        print("  画线次数     \(v.lines)   (render 且 items>0 且 rects>0)")
        print("  点中线/点空  hit=\(v.clickHit) miss=\(v.clickMiss)")
        print("  接受序列     begin=\(v.acceptBegin) write=\(v.acceptWrite) fail=\(v.acceptFail)")

        if v.acceptFail > 0 {
            print("RESULT: FAIL —— 接受失败：\(v.lastFailReason)")
            return 1
        }
        if !v.compose {
            print("RESULT: 等待 —— 这段时间没有写信窗出线（先在 Mail 新建一封写错句）")
            return 0
        }
        if v.lines == 0 {
            print("RESULT: FAIL —— 认了写信窗但一条线都没画")
            return 1
        }
        if v.clickHit == 0 {
            print("RESULT: 等待 —— 线有了（\(v.lines) 次），还没点中过线")
            if v.clickMiss > 0 { print("  最近一次 miss：\(v.lastDiag)") }
            return 0
        }
        if v.acceptWrite == 0 {
            print("RESULT: 等待 —— 点中线了，但还没走到写回（卡片里的「接受」点了吗）")
            return 0
        }
        print("RESULT: PASS —— 出线 \(v.lines) 次 · 点中 \(v.clickHit) 次 · 写回 \(v.acceptWrite) 次 · 零失败")
        return 0
    }

    static func number(after key: String, in s: String) -> Int? {
        guard let r = s.range(of: key) else { return nil }
        let rest = s[r.upperBound...]
        let digits = rest.prefix { $0.isNumber || $0 == "-" }
        return Int(digits)
    }
}
