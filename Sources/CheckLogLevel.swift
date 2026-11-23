// CheckLogLevel.swift — 检查事件的日志级别（纯函数，可断言）
//
// 为什么单独一个文件：这个判据错过一次，代价是整条自检信号失效。
// 11-23 查日志发现：`app.log` 一天里 20,820 行 ERROR，其中真故障 0 行 ——
// 全部是 `check kind=skip-readonly err=readonly`、`check kind=attach-el err=focused`
// 这类「正常跳过」被记成了 ERROR。自检 cron 每轮都在叫，真故障反而淹在里面。
//
// 根因：`CheckEvent.err` 是「这一轮为什么跳过 / 做了什么」的**说明文字**，不是错误标志。
//   正常路径也带说明：skip-readonly→"readonly"、skip-sensitive→"敏感字段"、
//   accept-write→"→ 新文本 栈=1"、web-poll→"blocks=46"、render→"原始 3 条 → 保留 2 条"。
// 所以判据必须看 kind，不能看 err 是否为空。

import Foundation

enum CheckLogLevel {
    /// 「本该成功却没成功」的 kind —— 只有这些进 ERROR。
    /// 新增失败型事件时必须加在这里，否则它会被当成正常注记。
    static let failureKinds: Set<String> = [
        "accept-fail",          // 点接受后写回失败（M3Flow 拒写 / 读回不一致回滚）
        "draft-backup-fail",    // 草稿备份失败（当前直接走 AppLog.error，这条留给它改成 CheckEvent 之后）
    ]

    /// 纯函数：给一条检查事件定级别。返回 "INFO" 或 "ERROR"。
    /// - Parameters:
    ///   - kind: 事件类型（skip-* / attach-* / check / render / accept-* …）
    ///   - err: 说明文字，可能为 "-"（无注记）
    static func level(kind: String, err: String) -> String {
        failureKinds.contains(kind) ? "ERROR" : "INFO"
    }
}
