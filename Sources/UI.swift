// UI.swift — 菜单栏面板（非激活）、设置窗口、状态模型

import AppKit
import SwiftUI

// MARK: - 诊断计数

@MainActor
final class Diag: ObservableObject {
    static let shared = Diag()
    @Published var requests = 0
    @Published var skippedChinese = 0
    @Published var gateDropped = 0
    @Published var lastEndpoint = "-"
    @Published var lastModel = "-"
    @Published var lastError = "-"
    @Published var lastElapsed = "-"
    @Published var applyMethod = "-"
    @Published var undoCount = 0
}

// MARK: - 状态模型

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case notConfigured
        case noPermission
        case info(String)          // 门控/无选区等：只给一句提示
        case loading(String)       // 原句
        case result(String, String, String)  // 原句 / 建议 / 原因
        case failure(String)
    }

    @Published var phase: Phase = .idle
    @Published var config: LLMConfig = SettingsStore.load()
    @Published var pendingUndo: Bool = false

    private var lastApplied: (snapshot: SelectionSnapshot, newText: String)?

    var canUndo: Bool { lastApplied != nil }

    // MARK: 触发

    func trigger() {
        let target = AXTarget.shared
        if !target.startTrackingDoneOrStart() { return }
        guard AXPermission.granted() else {
            Diag.shared.lastError = "无辅助功能权限"
            showPanel(phase: .noPermission)
            return
        }
        guard config.isComplete else {
            showPanel(phase: .notConfigured)
            return
        }

        let snap: SelectionSnapshot
        do {
            snap = try target.readSelection()
        } catch let e as AXReadError {
            Diag.shared.lastError = e.message
            showPanel(phase: .info(e.message))
            return
        } catch {
            Diag.shared.lastError = "读取失败：\(error)"
            showPanel(phase: .info("读取失败：\(error)"))
            return
        }

        // 语言门控：中文占比超阈值 → 完全不介入，不发请求
        if shouldSkipAsChinese(snap.text) {
            Diag.shared.skippedChinese += 1
            return                       // 连卡片都不弹
        }
        if snap.text.count > maxInputCharacters {
            showPanel(phase: .failure(ReviewFailure.tooLong(snap.text.count).userMessage))
            return
        }

        showPanel(phase: .loading(snap.text))
        let cfg = config
        let text = snap.text
        Task { [weak self] in
            Diag.shared.requests += 1
            do {
                let out = try await Engine.review(text: text, config: cfg)
                let diag = Diag.shared
                diag.lastEndpoint = out.endpoint
                diag.lastModel = out.model
                diag.lastElapsed = String(format: "%.2fs", out.elapsed)
                diag.lastError = "-"
                switch glossaryGate(original: snap.text, suggestion: out.suggestion.suggestion) {
                case .pass:
                    self?.phase = .result(snap.text, out.suggestion.suggestion, out.suggestion.reason)
                case .drop(let why):
                    diag.gateDropped += 1
                    diag.lastError = "术语硬闸丢弃：\(why)"
                    self?.phase = .info("没有要改的（硬闸拦截：\(why)）")
                }
                self?.showPanelRefresh()
            } catch let f as ReviewFailure {
                Diag.shared.lastError = f.userMessage
                self?.phase = .failure(f.userMessage)
                self?.showPanelRefresh()
            } catch {
                Diag.shared.lastError = "\(error)"
                self?.phase = .failure("请求失败：\(error)")
                self?.showPanelRefresh()
            }
        }
    }

    // MARK: 应用 / 撤销

    func apply(snapshotText: String, suggestion: String) {
        // 重新取一次当前选区，保证写回的是原句所在位置
        guard let snap = try? AXTarget.shared.readSelection() else {
            Diag.shared.lastError = "选区已失效，重新选中再试"
            phase = .failure("选区已失效：重新选中原句再点应用")
            showPanelRefresh()
            return
        }
        let result = AXTarget.shared.replaceSelection(in: snap, with: suggestion)
        Diag.shared.applyMethod = result.method.rawValue + (result.ok ? "" : "(失败)")
        if result.ok {
            lastApplied = (snap, suggestion)
            pendingUndo = true
            Diag.shared.lastError = result.detail
            closePanel()
        } else {
            Diag.shared.lastError = result.detail
            phase = .failure(result.detail)
            showPanelRefresh()
        }
    }

    func undo() {
        guard let last = lastApplied else { return }
        let r = AXTarget.shared.undoReplace(snapshot: last.snapshot, newText: last.newText)
        Diag.shared.undoCount += 1
        Diag.shared.lastError = r.detail
        if r.ok {
            lastApplied = nil
            pendingUndo = false
            return
        }
        showPanel(phase: .failure("撤销失败：\(r.detail)"))
    }

    // MARK: 面板

    private var panel: CardPanel?

    func showPanel(phase: Phase) {
        self.phase = phase
        if panel == nil { panel = CardPanel(model: self) }
        panel?.showNearMouse()
    }

    func showPanelRefresh() {
        if panel == nil { panel = CardPanel(model: self) }
        panel?.showNearMouse()
    }

    func closePanel() {
        panel?.orderOut(nil)
    }
}

// MARK: - 设置存储（三项全手填，零预设默认值）

enum SettingsStore {
    /// 设置域钉死成 bundle id：.app 与命令行裸二进制读写同一份，验收能直接 defaults read
    static let bundleId = "com.wanyi.englishwriter"
    static var store: UserDefaults { UserDefaults(suiteName: bundleId) ?? .standard }

    static let kBase = "llm.baseURL"
    static let kKey = "llm.apiKey"
    static let kModel = "llm.model"
    static let kLTBase = "lt.baseURL"
    static let kLTLanguage = "lt.language"
    static let kExcludedApps = "exclude.apps"

    static func load(_ d: UserDefaults = SettingsStore.store) -> LLMConfig {
        return LLMConfig(
            baseURL: d.string(forKey: kBase) ?? "",
            apiKey: d.string(forKey: kKey) ?? "",
            model: d.string(forKey: kModel) ?? ""
        )
    }

    static func save(_ c: LLMConfig, _ d: UserDefaults = SettingsStore.store) {
        d.set(c.baseURL, forKey: kBase)
        d.set(c.apiKey, forKey: kKey)
        d.set(c.model, forKey: kModel)
    }

    /// selftest 用：从环境变量读，避免污染用户配置
    static func fromEnvironment() -> LLMConfig {
        let e = ProcessInfo.processInfo.environment
        return LLMConfig(baseURL: e["EW_BASE_URL"] ?? "",
                         apiKey: e["EW_API_KEY"] ?? "",
                         model: e["EW_MODEL"] ?? "")
    }
}

// MARK: - 非激活面板（打开时 Mail 不失焦）

final class CardPanel: NSPanel {
    private var model: AppModel

    init(model: AppModel) {
        self.model = model
        Audit.window()
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                   styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        let host = NSHostingView(rootView: CardView(model: model, panel: self))
        host.frame = contentRect(forFrameRect: frame)
        contentView = host
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func showNearMouse() {
        let mouse = NSEvent.mouseLocation
        let size = frame.size
        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - 24
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let vis = screen.visibleFrame
            x = min(max(x, vis.minX + 8), vis.maxX - size.width - 8)
            if y < vis.minY + 8 { y = mouse.y + 24 }
            y = min(max(y, vis.minY + 8), vis.maxY - size.height - 8)
        }
        setFrameOrigin(NSPoint(x: x, y: y))
        if !UnderlineOverlay.globallySilent {
            Audit.show()
            orderFrontRegardless()
        }
    }
}

// MARK: - 卡片

struct CardView: View {
    @ObservedObject var model: AppModel
    let panel: NSPanel?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().opacity(0.25)
            content
            Divider().opacity(0.25)
            footer
        }
        .padding(16)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor).opacity(0.98)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.12), lineWidth: 1))
    }

    private var header: some View {
        HStack {
            Image(systemName: "pencil.and.outline").font(.system(size: 13, weight: .semibold))
            Text("英文写作助手").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { panel?.orderOut(nil) } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            Text("选中一段英文，点菜单栏「改选中文本」").foregroundStyle(.secondary)
        case .notConfigured:
            VStack(alignment: .leading, spacing: 6) {
                Text("还没配置模型接口").font(.system(size: 13, weight: .medium))
                Text("设置里填三项：base URL / API key / model（不预设默认值）")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("打开设置") { SettingsWindowController.shared.show(model: model) }
            }
        case .noPermission:
            VStack(alignment: .leading, spacing: 6) {
                Text("没有辅助功能权限").font(.system(size: 13, weight: .medium))
                Text("系统设置 → 隐私与安全性 → 辅助功能 → 勾上「英文写作助手」").font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Button("申请授权") { _ = AXPermission.request() }
                    Button("打开系统设置") { AXPermission.openSettingsPane() }
                }
            }
        case .info(let msg):
            Text(msg).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case .loading(let orig):
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("原句")
                Text(orig).font(.system(size: 12).monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在看…").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        case .result(let orig, let sugg, let reason):
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("原句")
                Text(orig).font(.system(size: 12).monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                sectionTitle("建议")
                Text(sugg).font(.system(size: 12).monospaced()).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                sectionTitle("为什么")
                Text(reason).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
        case .failure(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg).font(.system(size: 12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                HStack { Button("重试") { model.trigger() }; Button("设置") { SettingsWindowController.shared.show(model: model) } }
            }
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if case .result(_, let sugg, _) = model.phase {
                Button("应用并替换") { model.apply(snapshotText: "", suggestion: sugg) }
                    .keyboardShortcut(.defaultAction)
                Button("复制建议") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sugg, forType: .string)
                }
            }
            Spacer()
            if model.canUndo {
                Button("撤销上次替换") { model.undo() }.buttonStyle(.link)
            }
            Text(Diag.shared.applyMethod).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}
