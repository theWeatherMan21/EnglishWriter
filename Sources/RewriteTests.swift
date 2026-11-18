// RewriteTests.swift — 改写建议的断言（桩响应，不联网）
//
// 不变量：
//   R1 三个版本按序解析，label 保留（缺 label 按默认顺序补）
//   R2 每条候选必须能落成逐条 diff；整段一条替换的候选一律丢
//   R3 越界候选丢弃；坏 JSON 不崩、返回空
//   R4 应用顺序倒序（避免前面改完让后面偏移错位）
//   R5 模型没配 → 入口不可用（Rewrite.isAvailable == false）

import Foundation

enum RewriteTests {

    static func run() {
        print("\n--- 改写建议（rewrite）---")
        let seg = "We must make a decision in order to save time."
        let ns = seg as NSString
        func range(_ s: String) -> (loc: Int, len: Int) {
            let r = ns.range(of: s)
            return (r.location, r.length)
        }
        let decision = range("make a decision")
        let inorder = range("in order to")

        let stub = """
        {"candidates":[
          {"label":"更简洁","note":"去掉冗余","edits":[
            {"start":\(decision.loc),"length":\(decision.len),"original":"make a decision","replacement":"decide","type":"clarity","reason":"冗长"},
            {"start":\(inorder.loc),"length":\(inorder.len),"original":"in order to","replacement":"to","type":"clarity","reason":"冗长"}]},
          {"label":"更正式","edits":[
            {"start":\(decision.loc),"length":\(decision.len),"original":"make a decision","replacement":"reach a decision","type":"style","reason":"书面"}]},
          {"label":"更清晰","edits":[
            {"start":\(inorder.loc),"length":\(inorder.len),"original":"in order to","replacement":"so as to","type":"clarity","reason":"明确"}]}
        ]}
        """

        let cands = Rewrite.parse(stub, segment: seg)
        if cands.count == 3, cands.map({ $0.label }) == ["更简洁", "更正式", "更清晰"] {
            SelfTest.ok("改写·三版本按序解析", "3 个候选，label 齐全")
        } else {
            SelfTest.bad("改写·三版本按序解析", "count=\(cands.count) labels=\(cands.map { $0.label })")
        }

        if let first = cands.first {
            let applied = first.appliedText(to: seg)
            if applied == "We must decide to save time." {
                SelfTest.ok("改写·逐条 diff 落成句子", applied)
            } else {
                SelfTest.bad("改写·逐条 diff 落成句子", applied)
            }
        }

        // R2：整段一条替换 → 丢
        let whole = "{\"candidates\":[{\"label\":\"X\",\"edits\":[{\"start\":0,\"length\":\(ns.length),\"original\":\"\(seg)\",\"replacement\":\"Shorter.\",\"type\":\"style\",\"reason\":\"整段\"}]}]}"
        if Rewrite.parse(whole, segment: seg).isEmpty {
            SelfTest.ok("改写·整段替换被拒", "整段单条 → 丢弃")
        } else {
            SelfTest.bad("改写·整段替换被拒", "整段候选被接受")
        }

        // R3：越界 + 坏 JSON
        let oob = "{\"candidates\":[{\"label\":\"X\",\"edits\":[{\"start\":9999,\"length\":5,\"original\":\"zzzzz\",\"replacement\":\"y\",\"type\":\"style\",\"reason\":\"x\"}]}]}"
        if Rewrite.parse(oob, segment: seg).isEmpty { SelfTest.ok("改写·越界候选丢弃", "偏移超界 → 丢弃") }
        else { SelfTest.bad("改写·越界候选丢弃", "越界候选被接受") }
        if Rewrite.parse("not json at all", segment: seg).isEmpty { SelfTest.ok("改写·坏 JSON 不崩", "返回空") }
        else { SelfTest.bad("改写·坏 JSON 不崩", "解析出结果") }

        // label 缺失 → 补默认
        let noLabel = "{\"candidates\":[{\"edits\":[{\"start\":\(decision.loc),\"length\":\(decision.len),\"original\":\"make a decision\",\"replacement\":\"decide\",\"type\":\"clarity\",\"reason\":\"x\"}]}]}"
        if let c = Rewrite.parse(noLabel, segment: seg).first, c.label == "更简洁" {
            SelfTest.ok("改写·缺 label 补默认", c.label)
        } else {
            SelfTest.bad("改写·缺 label 补默认", "未补")
        }

        // R4：倒序应用
        if let items = cands.first?.items {
            let order = Rewrite.applyOrder(items)
            let starts = order.map { items[$0].start }
            if starts == starts.sorted(by: >) {
                SelfTest.ok("改写·倒序应用", "start 从大到小：\(starts)")
            } else {
                SelfTest.bad("改写·倒序应用", "\(starts)")
            }
        }

        // R5：模型没配 → 入口不可用
        if !Rewrite.isAvailable(LLMConfig(baseURL: "", apiKey: "", model: "")) {
            SelfTest.ok("改写·未配模型则不可用", "入口应隐藏")
        } else {
            SelfTest.bad("改写·未配模型则不可用", "仍显示入口")
        }
    }

}
