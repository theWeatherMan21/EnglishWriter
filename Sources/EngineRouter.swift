// EngineRouter.swift — 引擎路由（纯函数，可测）
//
// 四类错误由三条通道拼出来：
//   拼写  → NSSpellChecker（零进程，永远可用）
//   清晰度/风格 → 本地规则表（StyleRules，零进程）
//   语法  → 本地 LanguageTool（JVM，可选、默认关）或模型接口（OpenAI 兼容）
//
// 这里只决定「语法这一路走谁」，不碰 IO，方便穷举断言。

import Foundation

enum EngineRouter {

    enum GrammarChoice: String {
        case localLanguageTool      // 本地 LT 在跑且开关打开
        case remoteModel            // 没开 LT（或 LT 不可用）但填了三件套
        case none                   // 都没有：只出力所能及的拼写/清晰度/风格
    }

    /// - Parameters:
    ///   - ltEnabled: 设置面板里的开关（默认 false）
    ///   - ltAvailable: 探活结果（只有 ltEnabled 才会去探）
    ///   - modelConfigured: 三件套齐全
    static func choose(ltEnabled: Bool, ltAvailable: Bool, modelConfigured: Bool) -> GrammarChoice {
        if ltEnabled && ltAvailable { return .localLanguageTool }
        if modelConfigured { return .remoteModel }
        return .none
    }

    /// 给 UI/诊断用的人话
    static func describe(_ c: GrammarChoice) -> String {
        switch c {
        case .localLanguageTool: return "语法：本地 LanguageTool"
        case .remoteModel:       return "语法：模型接口"
        case .none:              return "语法：未启用（只出拼写/清晰度/风格）"
        }
    }
}
