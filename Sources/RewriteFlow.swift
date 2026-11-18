// RewriteFlow.swift — 改写/语气的统一入口（菜单和悬停卡片都走它）
//
// 铁律：
//   · 点了才发请求（不自动发，烧钱）
//   · 模型没配齐 → 入口不出现（菜单项不加、卡片按钮隐藏）
//   · 候选逐条 diff，倒地写入，⇧⌘Z 可整体回滚
//   · 会话状态全在内存里，不落盘

import AppKit

enum RewriteFlow {

    private static var pending: (cands: [RewriteCandidate], segment: String, segStart: Int)?

    @MainActor
    static func start(tone: Bool) {
        let ctrl = InlineController.shared
        guard Rewrite.isAvailable() else { ctrl.noteForRewrite("模型三项没填，改写不可用"); return }
        guard let ctx = ctrl.rewriteContext() else { ctrl.noteForRewrite("请先选中或把光标放进要改写的英文段落"); return }
        let segment = (ctx.full as NSString).substring(with: ctx.sel)
        guard (segment as NSString).length >= 8 else { ctrl.noteForRewrite("选中的段落太短，没什么可改的"); return }

        ctrl.noteForRewrite(tone ? "语气改写中…" : "改写中…")
        Task { @MainActor in
            do {
                let labels = tone ? Rewrite.toneLabels : Rewrite.defaultLabels
                let cands = try await Rewrite.suggest(segment: segment, config: SettingsStore.load(), labels: labels)
                guard !cands.isEmpty else { ctrl.noteForRewrite("模型没给出可用候选（可换长一点的段落再试）"); return }
                pending = (cands, segment, ctx.sel.location)
                let menu = NSMenu()
                for (i, c) in cands.enumerated() {
                    let it = NSMenuItem(title: "\(c.label)（\(c.items.count) 处）", action: nil, keyEquivalent: "")
                    it.tag = i
                    it.target = RewriteMenuTarget.shared
                    it.action = #selector(RewriteMenuTarget.pick(_:))
                    menu.addItem(it)
                }
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            } catch {
                ctrl.noteForRewrite("改写失败：\(error)")
            }
        }
    }

    @MainActor
    static func applyPicked(_ index: Int) {
        guard let p = pending, index < p.cands.count else { return }
        let c = p.cands[index]
        let n = Rewrite.apply(c, segment: p.segment, segStart: p.segStart, via: InlineController.shared)
        InlineController.shared.noteForRewrite(n > 0 ? "已应用「\(c.label)」：\(n) 处（⇧⌘Z 可撤销）" : "写回失败：该输入框不接受 AX 写入")
        pending = nil
    }
}

final class RewriteMenuTarget: NSObject {
    static let shared = RewriteMenuTarget()
    @MainActor @objc func pick(_ sender: NSMenuItem) { RewriteFlow.applyPicked(sender.tag) }
}
