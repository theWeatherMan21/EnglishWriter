// LanguageGate.swift — 只查英文（否则外语会被逐字当成英文拼写错误，比不检查更糟）
//
// 11-18 实案：Mail 里一封波兰语邮件被报出 410 条「拼写错误」
// （Agencji→Agency、Celnych→Clench、danych→Danish、Terramar→Tremor…）。
// 原来只有 CJK 门控，拉丁语系的外语全漏过去了。
//
// 判据三条，命中任一即判「非英文」（每条都保守：宁可少查，不可乱报）：
//   1. 变音字符：ą ć ę ł ń ó ś ź ż / ä ö ü ß / à è ì ò ù / ç ñ å ø æ —— 占非空白字符 >1%
//   2. 高频非英文词：przy / oraz / sobie / danych / zmian / jest / nie / się … 出现 ≥2 次
//   3. NLLanguageRecognizer：文本 ≥30 字符时判主语言，非英文且置信度 ≥0.5
//
// 反过来：英语文本里偶然出现一个 café、naïve 不应被判成外语 —— 所以第 1 条用比例不用「出现即跳」。

import Foundation
import NaturalLanguage

enum LanguageGate {

    /// 变音字符集合（拉丁扩展 A/B + 常见西欧）
    private static let accented: Set<Character> = Set("ąćęłńóśźżĄĆĘŁŃÓŚŹŻäöüßÄÖÜàáâãåçèéêëìíîïñòóôõùúûýÿÀÁÂÃÅÇÈÉÊËÌÍÎÏÑÒÓÔÕÙÚÛÝ")

    /// 高频非英文词（波兰语/德语/法语/西语/意语里极常见，英文里基本不出现）
    private static let foreignWords: Set<String> = [
        // 波兰语
        "przy", "oraz", "sobie", "danych", "zmian", "jest", "nie", "się", "sie", "który", "ktore",
        "jako", "temu", "przez", "dla", "tego", "być", "byc", "może", "moze", "tylko", "naszej",
        "firmy", "stron", "zgodnie", "informacji", "adres", "spółka", "spolka", "pozdrawiam",
        "spedytor", "agencji", "celnych", "ostatnie", "wiadomości", "wiadomosci", "danych", "zmian",
        // 德语
        "und", "der", "die", "das", "nicht", "mit", "sich", "auch", "wird", "werden", "ist",
        "für", "fur", "über", "uber", "eine", "einen", "sehr", "geehrte",
        // 法语 / 西语 / 意语
        "nous", "vous", "avec", "pour", "dans", "être", "etre", "nous", "merci", "cordialement",
        "para", "con", "por", "una", "gracias", "saludos", "estimado",
        "gentile", "cordiali", "saluti", "spettabile", "prego",
    ]

    /// 这句该不该查（false = 不是英文，整句跳过，只记日志不上屏）
    static func isEnglish(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }

        // 0) CJK 直接判非英文（11-23 负例断言抓到的漏洞：
        //    「总经理应虹于11月23日休假」这种短中文，长度 < 30 不走 NL 主语言判定 → 被放过，
        //    结果整句中文被送进 LanguageTool。中文块按设计一律跳过。）
        var scalars = 0, cjk = 0
        for u in t.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(u) {
            scalars += 1
            switch u.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF, 0xF900...0xFAFF:
                cjk += 1
            default: break
            }
        }
        if cjk >= 2, scalars > 0, Double(cjk) / Double(scalars) > 0.2 { return false }

        // 1) 变音字符比例
        var total = 0, marked = 0
        for ch in t where !ch.isWhitespace && !ch.isNewline {
            total += 1
            if accented.contains(ch) { marked += 1 }
        }
        // 需要一个「数量 + 比例」双门槛：英语里偶发 café / naïve 不该整句跳过，
        // 而波兰语/德语这类真正的外语变音字符是成片出现的。
        if marked >= 3, total > 0, Double(marked) / Double(total) > 0.01 { return false }
        if marked >= 2, total > 0, Double(marked) / Double(total) > 0.05 { return false }

        // 2) 高频外语词
        let words = t.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" })
        var hits = 0
        for w in words where foreignWords.contains(String(w)) {
            hits += 1
            if hits >= 2 { return false }
        }

        // 3) 主语言判定（短文本不判，避免误导）
        if t.count >= 30 {
            let rec = NLLanguageRecognizer()
            rec.processString(t)
            if let lang = rec.dominantLanguage, lang != .english {
                let conf = rec.languageHypotheses(withMaximum: 1).first?.value ?? 0
                if conf >= 0.5 { return false }
            }
        }
        return true
    }

    /// 主语言判定（不设长度门槛，供泄漏检查用）
    static func dominantNonEnglish(_ s: String) -> Bool {
        guard s.count >= 8 else { return false }
        let rec = NLLanguageRecognizer()
        rec.processString(s)
        guard let lang = rec.dominantLanguage, lang != .english else { return false }
        let conf = rec.languageHypotheses(withMaximum: 1).first?.value ?? 0
        return conf >= 0.3
    }

    /// 误报泄漏检查：被判出的「错词」里非 ASCII 占比 >20% 说明门控漏了外语
    static func looksLikeForeignLeak(_ originals: [String]) -> (Bool, Double) {
        guard !originals.isEmpty else { return (false, 0) }
        // 规则 B：把命中的「错词」拼起来再看一遍语言——波兰语词本身可能是纯 ASCII
        // （Spedytor / Agencji / Celnych），非 ASCII 比例抓不到，但整串会被判成非英文。
        if originals.count >= 3, dominantNonEnglish(originals.joined(separator: " ")) { return (true, 1.0) }
        var nonASCII = 0, total = 0
        for o in originals {
            for u in o.unicodeScalars {
                total += 1
                if u.value > 127 { nonASCII += 1 }
            }
        }
        let ratio = total == 0 ? 0 : Double(nonASCII) / Double(total)
        return (ratio > 0.20, ratio)
    }
}
