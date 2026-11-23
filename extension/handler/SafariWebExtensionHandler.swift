// Safari Web Extension 的原生处理器：Safari 加载扩展时要能找到这个类。
// 内容脚本（content.js）负责画线与卡片；这里只处理「扩展 → 原生」的消息，
// 目前只回一个心跳，证明原生侧真的被调起来了（不带业务、不落盘）。
import Foundation
#if canImport(SafariServices)
import SafariServices
#endif

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = NSExtensionItem()
        var payload: [String: Any] = ["ok": true, "host": "EnglishWriter"]
        #if canImport(SafariServices)
        item.userInfo = [SFExtensionMessageKey: payload]
        #else
        item.userInfo = ["message": payload]
        #endif
        _ = payload
        context.completeRequest(returningItems: [item], completionHandler: nil)
    }
}
