// Integrations.swift — 逐 App 适配表（照 Grammarly 的 IntegrationOptions.json 形状抄，不抄内容）
//
// 为什么要有这一层：之前我们做的是「通用探测」——拿焦点元素猜是不是正文。
// Grammarly 做的是「逐 App 适配」：每个 App 一条配置，元素名用正则、浮动球位置逐 App 指定、
// 还有一份敏感字段关键词黑名单（命中就不激活，保护账号密码）。
// 我们一直「没反应」的根因就在这里：不是 UI 画得不好，是这一层从来不存在。
//
// 铁律（优先级高于任何适配规则）：
//   元素的 identifier / role / title 命中敏感关键词（password / login / account / address / id / card / cvv…）
//   → 一律不激活、不检查、不落盘正文。
//
// 数据来源：元素名必须现场探出来再填，不许猜。探不到 → isEnabled: false + 注释写「未探明」。

import Foundation

struct Integration: Codable, Equatable {
    var id: String                 // 人类可读名（"Mail"）
    var bundleId: String
    /// 正文元素 identifier 的正则；nil = 按 role 兜底（AXTextArea / AXWebArea）
    var elementName: String?
    var isMailBody: Bool = false   // 邮件正文：跳过引用链/签名区
    var allowInTextFields: Bool = false   // 单行输入框默认不工作，要显式开启
    var defaultPosition: FloatCorner = .bottomRight
    var positionOffset: [Int] = [-24, -24]
    var forbiddenCorners: [FloatCorner] = []
    var checkAncestors: Bool = false
    var isEnabled: Bool = true
    var note: String = ""
}

enum FloatCorner: String, Codable {
    case topLeft, topRight, bottomLeft, bottomRight
}

enum Integrations {

    /// 敏感字段关键词：命中即不激活（Grammarly 叫 IgnoreKeywordBlocklist）
    static let sensitiveKeywords = ["password", "passwd", "login", "sign in", "signin",
                                    "account", "address", "credit card", "card number", "cvv", "cvc",
                                    "security code", "ssn", "token", "secret", "id"]
    /// 「id」太宽（Notes 的文本框 identifier 就叫 Note[id=…]），这些例外放行
    static let sensitiveExceptions = ["note[id=", "nodeid", "grid", "valid", "idle", "width", "hidden"]

    static func isSensitive(text: String) -> Bool {
        let t = text.lowercased()
        guard !t.isEmpty else { return false }
        for e in sensitiveExceptions where t.contains(e) { return false }
        for k in sensitiveKeywords where t.contains(k) { return true }
        return false
    }

    /// 命中某 App 的配置；没有配置就返回 nil（= 不工作，而不是"通用探测"去猜）
    static func integration(bundleId: String, appName: String) -> Integration? {
        all.first { $0.isEnabled && ($0.bundleId == bundleId || $0.id == appName) }
    }

    /// 先只填 5 条。元素名是现场探到的（探不到写 false + 注释）。
    static var all: [Integration] {
        [
            // TextEdit：实测 AXTextArea（--axcheck/--axwatch 真机验过），可读可写
            Integration(id: "TextEdit", bundleId: "com.apple.TextEdit",
                        elementName: nil, isMailBody: false, allowInTextFields: false,
                        defaultPosition: .bottomRight, positionOffset: [-24, -24],
                        forbiddenCorners: [], checkAncestors: false, isEnabled: true,
                        note: "真机验过：焦点落在 AXTextArea，AXValue 可读可写"),

            // Mail：阅读/写信正文都是 AXWebArea，按文本块读（--probe-mail 实测 347 块）
            Integration(id: "Mail", bundleId: "com.apple.mail",
                        elementName: nil, isMailBody: true, allowInTextFields: false,
                        defaultPosition: .bottomRight, positionOffset: [-24, -60],
                        forbiddenCorners: [.topLeft, .topRight], checkAncestors: false, isEnabled: true,
                        note: "实测：正文 AXWebArea，按块读；compose 未探明 -> 仍按 WebArea 处理"),

            // Notes：未探明（没有开他的 Notes 去探测，按规矩写 false）
            Integration(id: "Notes", bundleId: "com.apple.Notes",
                        elementName: nil, isMailBody: false, allowInTextFields: false,
                        defaultPosition: .bottomRight, positionOffset: [-24, -24],
                        forbiddenCorners: [], checkAncestors: false, isEnabled: false,
                        note: "未探明：未在真机探测 Notes 正文元素的 identifier"),

            // Word：未探明（要开他的 Word 才能探，不许猜）
            Integration(id: "Word", bundleId: "com.microsoft.Word",
                        elementName: nil, isMailBody: false, allowInTextFields: false,
                        defaultPosition: .bottomRight, positionOffset: [-24, -60],
                        forbiddenCorners: [.topLeft, .topRight], checkAncestors: true, isEnabled: false,
                        note: "未探明：Word 正文为自绘/AX 结构未知，需真机探测后再开"),

            // Outlook：未探明
            Integration(id: "Outlook", bundleId: "com.microsoft.Outlook",
                        elementName: nil, isMailBody: true, allowInTextFields: false,
                        defaultPosition: .bottomRight, positionOffset: [-24, -60],
                        forbiddenCorners: [.topLeft, .topRight], checkAncestors: true, isEnabled: false,
                        note: "未探明：Outlook 正文元素未探测，先关"),

            // Telegram Desktop：11-19 现探（qa/evidence/ax-elements.json）
            //   AXTextArea identifier=…HistoryWidget…InputField5InnerE title=「输入消息…」
            //   frame=(390,946,1160,31) = 窗口底部整条输入框，就是它。
            //   注意：identifier 带 Rosetta 名字修饰，跨版本可能变；匹配不靠它，靠 role=AXTextArea。
            Integration(id: "Telegram", bundleId: "org.telegram.desktop",
                        elementName: nil, isMailBody: false, allowInTextFields: true,
                        defaultPosition: .bottomRight, positionOffset: [-24, -24],
                        forbiddenCorners: [], checkAncestors: false, isEnabled: true,
                        note: "已探明输入框（AXTextArea「输入消息…」，1160×31，窗口底部）；写回未做真机验证"),

            // WPS：11-19 现探只看到无标识 AXTextField/AXTextArea 且 chars=0，第二次探测窗口已关
            // → 没确认「那是正文」之前不开，按规矩保持 false
            Integration(id: "WPS", bundleId: "com.kingsoft.wpsoffice.mac",
                        elementName: nil, isMailBody: false, allowInTextFields: false,
                        defaultPosition: .bottomRight, positionOffset: [-24, -60],
                        forbiddenCorners: [.topLeft, .topRight], checkAncestors: true, isEnabled: false,
                        note: "未探明：只看到无标识 AXTextArea 且字数 0，未确认是文档正文"),

            // Pages / Slack：本次未运行，探不到就不许猜
            Integration(id: "Pages", bundleId: "com.apple.iWork.Pages",
                        elementName: nil, isMailBody: false, allowInTextFields: false,
                        defaultPosition: .bottomRight, positionOffset: [-24, -60],
                        forbiddenCorners: [], checkAncestors: true, isEnabled: false,
                        note: "未探明：11-19 探测时 Pages 未运行"),

            Integration(id: "Slack", bundleId: "com.tinyspeck.slackmacgap",
                        elementName: nil, isMailBody: false, allowInTextFields: true,
                        defaultPosition: .bottomRight, positionOffset: [-24, -24],
                        forbiddenCorners: [], checkAncestors: false, isEnabled: false,
                        note: "未探明：11-19 探测时 Slack 未运行"),
        ]
    }
}
