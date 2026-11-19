// DiagWindow.swift — 诊断窗口（让你看见它到底干了什么）
//
// 之前所有诊断只有 Diag 里的内部变量，没有窗口 —— 爹地问「UI 方面呢」，这是唯一还缺的一块。
// 只读：不改任何状态；3 秒刷新一次（读本地内存计数，不是轮询服务）。

import AppKit
import SwiftUI

final class DiagWindowController {
    static let shared = DiagWindowController()
    private var window: NSWindow?

    @MainActor
    func show() {
        if let w = window {
            Audit.show()
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = DiagView()
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        Audit.window()
        w.title = "英文写作助手 · 诊断"
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        Audit.show()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

final class DiagModel: ObservableObject {
    @Published var tick = 0
    @Published var fast = CategoryPrefs.fastMode()
    @Published var ltOn = EnginePrefs.ltEnabled()
    @Published var types: [String] = CategoryPrefs.allTypes.filter { CategoryPrefs.isEnabled($0) }
    @Published var sens = CategoryPrefs.sensitivity()
    private var timer: Timer?

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }
    deinit { timer?.invalidate() }

    func refresh() {
        fast = CategoryPrefs.fastMode()
        ltOn = EnginePrefs.ltEnabled()
        types = CategoryPrefs.allTypes.filter { CategoryPrefs.isEnabled($0) }
        sens = CategoryPrefs.sensitivity()
        tick += 1
    }
}

struct DiagView: View {
    @StateObject private var m = DiagModel()
    private var d: InlineController.InlineDiag { InlineController.shared.diag }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("运行状态").font(.system(size: 13, weight: .semibold))
                row("引擎路由", d.engineChoice)
                row("检查次数", "\(d.checks)")
                row("模型请求", "\(d.requests)")
                row("中文跳过", "\(d.skippedChinese)")
                row("同句去重", "\(d.dedupedHits)")
                row("焦点兜底", "\(d.fallbackTextArea)")
                row("最近耗时", d.lastElapsed)
                row("最近矩形", "\(d.lastRectCount)")
                row("上次取文本", "\(d.lastTextLen) 字 / 通道 \(d.lastPath)")
                row("最近错误", d.lastError)
                row("写回方式", Diag.shared.applyMethod)
                row("撤销次数", "\(Diag.shared.undoCount)")

                Divider()
                Text("当前设置").font(.system(size: 13, weight: .semibold))
                row("本地 LanguageTool", m.ltOn ? "开（闲置 600s 自动退）" : "关（省 ~370MB）")
                row("快速模式（关推理链）", m.fast ? "开" : "关")
                row("检查类别", m.types.joined(separator: " / "))
                row("敏感度", m.sens.rawValue)
                row("模型接口", SettingsStore.load().isComplete ? "已配置" : "未配置")

                Divider()
                HStack(spacing: 10) {
                    Button("刷新") { m.refresh() }
                    Button("清掉下划线") { InlineController.shared.clearUnderlines() }
                    Button("打开设置") {
                        if let model = AppModel.diagRef { SettingsWindowController.shared.show(model: model) }
                    }
                }
                Text("刷新计数：\(m.tick)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
            Text(v).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }
}
