// CategoryPrefsTests.swift — 类别开关与敏感度的断言（纯函数，不碰宿主）
//
// 不变量：
//   C1 默认全开：四类都保留
//   C2 关掉某一类 → 该类一条都不出现，其它类不受影响
//   C3 轻度敏感度 → clarity/style 被压制，即使四类都开着
//   C4 标准/激进 → 四类都保留（这两档目前语义相同，激进只是不额外压制）
//   C5 过滤不改变条目内容（start/length/original/replacement 一字不动）
//   C6 未知类型不会被开关误放行（只认四种）

import Foundation

enum CategoryPrefsTests {

    private static func item(_ type: String, _ start: Int) -> DiffItem {
        DiffItem(start: start, length: 4, original: "orig", replacement: "repl", type: type, reason: "t")
    }

    static func run() {
        print("\n--- 类别开关 / 敏感度 ---")
        let all = [item("spelling", 0), item("grammar", 10), item("clarity", 20), item("style", 30)]

        // C1 默认全开
        let def = CategoryPrefs.filter(all, enabled: Set(CategoryPrefs.allTypes), sensitivity: .standard)
        SelfTest.ok(def.count == 4 ? "类别·默认全开四类" : "类别·默认全开四类",
                    def.count == 4 ? "4 条全保留" : "只剩 \(def.count) 条")

        // C2 关掉 style
        var on = Set(CategoryPrefs.allTypes); on.remove("style")
        let noStyle = CategoryPrefs.filter(all, enabled: on, sensitivity: .standard)
        if noStyle.count == 3, !noStyle.contains(where: { $0.kind.rawValue == "style" }) {
            SelfTest.ok("类别·关 style 只去掉 style", "3 条，style 0 条")
        } else {
            SelfTest.bad("类别·关 style 只去掉 style", "count=\(noStyle.count)")
        }

        // C2b 只留拼写
        let onlySpell = CategoryPrefs.filter(all, enabled: ["spelling"], sensitivity: .standard)
        if onlySpell.count == 1, onlySpell[0].kind.rawValue == "spelling" {
            SelfTest.ok("类别·只留拼写", "1 条 spelling")
        } else {
            SelfTest.bad("类别·只留拼写", "count=\(onlySpell.count)")
        }

        // C3 轻度压制 clarity/style
        let light = CategoryPrefs.filter(all, enabled: Set(CategoryPrefs.allTypes), sensitivity: .light)
        if light.count == 2, light.allSatisfy({ $0.kind.rawValue == "spelling" || $0.kind.rawValue == "grammar" }) {
            SelfTest.ok("敏感度·轻度只报拼写语法", "2 条")
        } else {
            SelfTest.bad("敏感度·轻度只报拼写语法", "count=\(light.count)")
        }

        // C4 激进不额外压制
        let aggr = CategoryPrefs.filter(all, enabled: Set(CategoryPrefs.allTypes), sensitivity: .aggressive)
        if aggr.count == 4 { SelfTest.ok("敏感度·激进四类都报", "4 条") }
        else { SelfTest.bad("敏感度·激进四类都报", "count=\(aggr.count)") }

        // C5 过滤不改内容
        let kept = CategoryPrefs.filter(all, enabled: Set(CategoryPrefs.allTypes), sensitivity: .standard)
        if zip(kept, all).allSatisfy({ $0.start == $1.start && $0.length == $1.length && $0.original == $1.original && $0.replacement == $1.replacement }) {
            SelfTest.ok("类别·过滤不改条目内容", "字段逐条一致")
        } else {
            SelfTest.bad("类别·过滤不改条目内容", "内容被改")
        }

        // C6 未知类型：按语法兜底（UnderlineKind.from 的既定行为），但要显式钉住，避免以后变成"随机放行"
        let weird = all + [item("zzz-unknown", 40)]
        let w = CategoryPrefs.filter(weird, enabled: Set(CategoryPrefs.allTypes), sensitivity: .standard)
        if w.contains(where: { $0.kind.rawValue == "grammar" && $0.start == 40 }) {
            SelfTest.ok("类别·未知类型按语法兜底", "zzz-unknown → grammar（既定行为）")
        } else {
            SelfTest.bad("类别·未知类型按语法兜底", "未知类型没被兜底成 grammar")
        }
        // 关掉语法时，未知类型也必须一起消失（不能因为兜底就绕过开关）
        var noGram = Set(CategoryPrefs.allTypes); noGram.remove("grammar")
        let w2 = CategoryPrefs.filter(weird, enabled: noGram, sensitivity: .standard)
        if !w2.contains(where: { $0.start == 40 }) {
            SelfTest.ok("类别·关语法时未知类型也消失", "开关对兜底类型同样生效")
        } else {
            SelfTest.bad("类别·关语法时未知类型也消失", "关语法后未知类型仍在")
        }
    }
}
