// SettingsSnapshot.swift — 设置面板离屏截图（一张 PNG，用来验收「面板长什么样」）
//
// 两条硬纪律：
//   1) 不上屏：窗口放在 (-6000,-6000)，不 orderFront、不 activate、不 screencapture（静默红线）。
//   2) 不碰用户真实配置：整个渲染过程跑在一个临时 suite 上（SettingsStore.override），
//      渲染完立刻抹掉；用户真实的 com.wanyi.englishwriter 一个键都不动。
//
// 截图内容按卡面要求造：模型三件套为空（不写任何值）、方言取默认 en-GB（不写）、词典两个词。

import AppKit
import SwiftUI

@MainActor
enum SettingsSnapshot {

    static func run(_ argv: [String]) -> Int32 {
        let out = value(after: "--settings-snapshot", in: argv)
            ?? (FileManager.default.currentDirectoryPath + "/out/settings-panel.png")

        let suite = "\(SettingsStore.bundleId).snapshot.\(getpid())"
        guard let iso = UserDefaults(suiteName: suite) else {
            print("FAIL 拿不到隔离域 \(suite)")
            return 2
        }
        iso.removePersistentDomain(forName: suite)
        SettingsStore.override = iso
        defer {
            SettingsStore.override = nil
            iso.removePersistentDomain(forName: suite)
        }

        // 只写词典两个词；三件套与方言都留空 → 读回来必须是空 / 默认 en-GB
        DictStore.add("FCL")
        DictStore.add("demurrage")

        let cfg = SettingsStore.load()
        let lang = EnginePrefs.language()
        let words = DictStore.words
        guard cfg.baseURL.isEmpty, cfg.apiKey.isEmpty, cfg.model.isEmpty, !cfg.isComplete else {
            print("FAIL 快照状态不对：三件套不是空的 \(cfg)")
            return 1
        }
        guard lang == "en-GB" else { print("FAIL 方言不是默认 en-GB：\(lang)"); return 1 }
        guard words.count == 2 else { print("FAIL 词典不是两个词：\(words)"); return 1 }
        print("状态：三件套为空 · 方言 \(lang) · 词典 \(words)")

        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)

        let model = AppModel()
        let hosting = NSHostingView(rootView: SettingsView(model: model, snapshot: true))
        hosting.layoutSubtreeIfNeeded()
        let fit = hosting.fittingSize
        let size = NSSize(width: max(560, fit.width), height: max(320, fit.height))

        // 屏幕外窗口：只为给 SwiftUI 一个真实的绘制环境，绝不显示
        let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.backgroundColor = .white
        // 快照固定浅色外观：证据图不随系统深色模式变，方便逐条比对
        hosting.appearance = NSAppearance(named: .aqua)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        hosting.frame = container.bounds
        container.addSubview(hosting)
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        hosting.display()
        container.displayIfNeeded()

        let scale: CGFloat = 2
        let pxW = Int(size.width * scale), pxH = Int(size.height * scale)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pxW, pixelsHigh: pxH,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else {
            print("FAIL 建不出位图")
            return 2
        }
        rep.size = size
        container.cacheDisplay(in: container.bounds, to: rep)

        var png = rep.representation(using: .png, properties: [:])
        if png == nil || isBlank(rep) {
            // 锁屏 / 无显示时 cacheDisplay 可能拿到空白：改走 PDF 绘制路径
            print("提示：cacheDisplay 空白，改走 PDF 合成")
            png = viaPDF(view: container, size: size)
        }
        guard let data = png else { print("FAIL 生不出 PNG"); return 2 }
        let url = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard (try? data.write(to: url)) != nil else { print("FAIL 写不进 \(out)"); return 2 }

        print("面板截图：\(out)")
        print("像素：\(pxW)x\(pxH)（\(Int(size.width))x\(Int(size.height))pt @2x）· 字节 \(data.count)")
        return 0
    }

    // MARK: 工具

    private static func value(after flag: String, in argv: [String]) -> String? {
        guard let i = argv.firstIndex(of: flag), i + 1 < argv.count else { return nil }
        return argv[i + 1]
    }

    /// 全白/全透明 = 没画出来（不靠肉眼判断「是不是空白图」）
    private static func isBlank(_ rep: NSBitmapImageRep) -> Bool {
        var colors = Set<String>()
        let stepX = max(1, rep.pixelsWide / 40), stepY = max(1, rep.pixelsHigh / 40)
        var y = 0
        while y < rep.pixelsHigh {
            var x = 0
            while x < rep.pixelsWide {
                if let c = rep.colorAt(x: x, y: y) {
                    colors.insert(String(format: "%.2f|%.2f|%.2f|%.2f",
                                         c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent))
                }
                x += stepX
            }
            y += stepY
        }
        return colors.count < 5
    }

    private static func viaPDF(view: NSView, size: NSSize) -> Data? {
        let pdf = view.dataWithPDF(inside: view.bounds)
        let tmp = NSTemporaryDirectory() + "ew-settings-panel.pdf"
        let pngPath = NSTemporaryDirectory() + "ew-settings-panel.png"
        guard (try? pdf.write(to: URL(fileURLWithPath: tmp))) != nil else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-s", "format", "png", "--resampleWidth", String(Int(size.width * 2)), tmp, "--out", pngPath]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: pngPath))
    }
}
