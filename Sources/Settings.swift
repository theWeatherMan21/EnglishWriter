// Settings.swift — 设置窗口 + 诊断面板（唯一允许抢键盘的窗口）

import AppKit
import SwiftUI

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(model: AppModel) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(model: model)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "英文写作助手 · 设置"
        w.contentView = NSHostingView(rootView: view)
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var diag = Diag.shared
    @ObservedObject var badge = SaveBadge()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("模型接口（三项手填，无预设默认值）").font(.system(size: 13, weight: .semibold))
                field("Base URL", text: $model.config.baseURL, hint: "例：https://api.example.com/v1（OpenAI 兼容）")
                field("API Key", text: $model.config.apiKey, hint: "只存本机 UserDefaults")
                field("Model", text: $model.config.model, hint: "请求体里的 model 字段")
                HStack(spacing: 8) {
                    Button("保存") { save() }
                    Text(badge.text).font(.system(size: 11)).foregroundStyle(.secondary)
                }

                Divider()
                Text("辅助功能权限").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    Circle().fill(AXPermission.granted() ? Color.green : Color.orange).frame(width: 8, height: 8)
                    Text(AXPermission.granted() ? "已授权" : "未授权（读不到选区）").font(.system(size: 12))
                    Spacer()
                    Button("申请授权") { _ = AXPermission.request() }
                    Button("打开系统设置") { AXPermission.openSettingsPane() }
                }

                Divider()
                Text("诊断（DoD 取证）").font(.system(size: 13, weight: .semibold))
                VStack(alignment: .leading, spacing: 4) {
                    row("请求数 requests", "\(diag.requests)")
                    row("中文门控跳过", "\(diag.skippedChinese)")
                    row("术语硬闸丢弃", "\(diag.gateDropped)")
                    row("上次 endpoint", diag.lastEndpoint)
                    row("上次 model", diag.lastModel)
                    row("上次耗时", diag.lastElapsed)
                    row("写回方式", diag.applyMethod)
                    row("撤销次数", "\(diag.undoCount)")
                    row("最后一条错误", diag.lastError)
                }
                Text("纪律：无 Timer 轮询、无 AXObserver、无 CGEventTap —— 只在被点的那一刻读一次 AX。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(18)
        }
        .frame(width: 520, height: 460)
    }

    private func field(_ title: String, text: Binding<String>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium))
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12).monospaced())
                .onChange(of: text.wrappedValue) { _ in save() }
            Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 140, alignment: .leading)
            Text(v).font(.system(size: 11).monospaced()).textSelection(.enabled)
            Spacer()
        }
    }

    private func save() {
        SettingsStore.save(model.config)
        badge.text = "已保存 \(Date().formatted(date: .omitted, time: .standard))"
    }
}

/// 避免 @State 宏（CLT 工具链没有 SwiftUIMacros 插件）
final class SaveBadge: ObservableObject {
    @Published var text = ""
}
