// SpellCheck.swift — 系统 NSSpellChecker 拼写通道（零额外内存，毫秒级）
//
// 为什么：本地 LanguageTool 是 JVM，常驻 346–448MB（实测），而「拼写」这件事 macOS 自带
// NSSpellChecker 就能做，零进程、零常驻内存。所以拼写走系统、语法走 LT（或模型），
// LT 只在需要语法检查时按需拉起、闲置就退出。
//
// 护栏与原生同口径：
//   · 落在 SpanGuard 区间（术语/箱号/港口码/金额/邮箱/链接）里的词一律不算错
//   · 个人词典（DictStore）里的词不算错
//   · 中文句子不进来（调用方已门控）

import AppKit

enum SpellCheck {

    /// 一段英文 → 拼写类 DiffItem（UTF-16 偏移相对传入文本）
    static func items(in text: String, language: String = "en") -> [DiffItem] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let guarded = SpanGuard.guardedRanges(in: text)
        let dict = Set(DictStore.words.map { $0.lowercased() })
        var out: [DiffItem] = []
        let checker = NSSpellChecker.shared
        var from = 0

        while from < ns.length {
            var wordLen = 0
            let r = checker.checkSpelling(of: text, startingAt: from, language: language,
                                          wrap: false, inSpellDocumentWithTag: 0, wordCount: &wordLen)
            guard r.location != NSNotFound, r.length > 0 else { break }
            let word = ns.substring(with: r)
            from = r.location + max(1, r.length)

            if word.count < 3 { continue }                                  // 过短不报，避免 I/a/an 噪声
            if dict.contains(word.lowercased()) { continue }
            if guarded.contains(where: { NSIntersectionRange($0, r).length > 0 }) { continue }
            if isLikelyCode(word) { continue }                              // 全大写缩写 / 含数字
            // 这个名字/词在别的语言里是对的 → 不是英文拼写错误（实案：Spedytor/Agencji/Jaroslaw/Terramar
            // 被当成英文错字报给爹地，一封波兰语邮件刷出几百条红线）
            if isValidInOtherLanguage(word) { continue }
            if isLikelyProperNoun(word, at: r.location, in: ns) { continue }

            let guesses = checker.guesses(forWordRange: r, in: text, language: language,
                                          inSpellDocumentWithTag: 0) ?? []
            guard let best = guesses.first, best.lowercased() != word.lowercased() else { continue }
            out.append(DiffItem(start: r.location, length: r.length,
                                original: word, replacement: best,
                                type: "spelling",
                                reason: "拼写：\(word) → \(best)（系统词典）"))
        }
        return DiffSanitize.consolidate(out, in: text)
    }

    /// 全大写缩写（FCL / ETA）、含数字（BL123）、带下划线或驼峰的标识符：不当拼写错误
    private static func isLikelyCode(_ s: String) -> Bool {
        if s.contains(where: { $0.isNumber || $0 == "_" || $0 == "." }) { return true }
        let letters = s.filter { $0.isLetter }
        if !letters.isEmpty, letters.allSatisfy({ $0.isUppercase }) { return true }
        return false
    }

    /// 在常见非英文语言里查这个词：任一语言认为它正确 → 丢弃（本地词典，零网络）
    static func isValidInOtherLanguage(_ word: String) -> Bool {
        let langs = ["pl", "de", "fr", "es", "it", "nl", "pt", "sv", "da"]
        let checker = NSSpellChecker.shared
        for lang in langs {
            var wordLen = 0
            let r = checker.checkSpelling(of: word, startingAt: 0, language: lang,
                                         wrap: false, inSpellDocumentWithTag: 0, wordCount: &wordLen)
            if r.location == NSNotFound { return true }   // 该语言词典里认得这个词
        }
        return false
    }

    /// 专有名词启发：句中首字母大写、且不是句首 → 大概率是人名/公司名/地名，不报拼写
    static func isLikelyProperNoun(_ word: String, at loc: Int, in ns: NSString) -> Bool {
        guard let first = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(first) else { return false }
        // 句首判定：往前找一个非空白字符，是句末标点或行首 → 句首，不算专有名词启发
        var i = loc - 1
        while i >= 0 {
            let ch = ns.substring(with: NSRange(location: i, length: 1))
            if ch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { i -= 1; continue }
            if ".!?\n".contains(ch) { return false }
            break
        }
        // 全大写缩写已经在上游过滤；这里只处理「首字母大写且词内还有小写」的形态
        let hasLower = word.dropFirst().contains { $0.isLowercase }
        return hasLower
    }
}
