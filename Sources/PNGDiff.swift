// PNGDiff.swift — 视觉基线逐像素比对（离屏，不需要人眼）
//
// 为什么需要：--settings-snapshot / --ball-snapshot 以前只判「文件非空」，
// CSS 改了到底有没有跑版、跑了多少，全靠眼看。爹地说过「毛坯」，这一项不可复跑。
//
// 用法：
//   ./build/英文写作助手 --pngdiff <基线.png> <当前.png> [--threshold 0.005] [--out <差异.png>]
// 判定：
//   变更像素占比 > threshold → FAIL（exit 1），并把差异图写出来（变红 = 不一样的地方）
//   尺寸不同 → 直接 FAIL（尺寸都不一致，比像素没意义）

import Foundation
import AppKit

enum PNGDiff {
    static func run(_ argv: [String]) -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        let args = Array(argv)
        guard let i = args.firstIndex(of: "--pngdiff") else {
            print("用法：--pngdiff <基线.png> <当前.png> [--threshold 0.005] [--out 差异.png]")
            return 2
        }
        // 位置参数 = --pngdiff 之后、下一个以 -- 开头之前的两个
        let rest = args.dropFirst(i + 1)
        let pos = rest.prefix { !$0.hasPrefix("--") }
        guard pos.count >= 2 else {
            print("用法：--pngdiff <基线.png> <当前.png> [--threshold 0.005] [--out 差异.png]")
            return 2
        }
        let basePath = pos[pos.startIndex]
        let curPath = pos[pos.index(after: pos.startIndex)]
        var threshold = 0.005
        if let t = args.firstIndex(of: "--threshold"), t + 1 < args.count, let v = Double(args[t + 1]) { threshold = v }
        var outPath: String? = nil
        if let o = args.firstIndex(of: "--out"), o + 1 < args.count { outPath = args[o + 1] }

        guard let a = load(basePath), let b = load(curPath) else {
            print("FAIL  pngdiff 读不到图片（基线：\(basePath) 当前：\(curPath)）")
            return 1
        }
        if a.pixelsWide != b.pixelsWide || a.pixelsHigh != b.pixelsHigh {
            print("FAIL  pngdiff 尺寸不一致：基线 \(a.pixelsWide)×\(a.pixelsHigh) / 当前 \(b.pixelsWide)×\(b.pixelsHigh)")
            return 1
        }

        let w = a.pixelsWide, h = a.pixelsHigh
        let total = w * h
        guard total > 0 else { print("FAIL  pngdiff 空图"); return 1 }

        var changed = 0
        let diffRep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        let ctxA = NSGraphicsContext(bitmapImageRep: a)
        let ctxB = NSGraphicsContext(bitmapImageRep: b)
        NSGraphicsContext.saveGraphicsState()
        if let ca = ctxA { NSGraphicsContext.current = ca }
        let imgA = NSImage(size: NSSize(width: w, height: h))
        imgA.addRepresentation(a)
        NSGraphicsContext.restoreGraphicsState()

        // 直接用位图数据比：每像素 4 通道，容差 2/255 防压缩噪声
        guard let dA = a.bitmapData, let dB = b.bitmapData else { print("FAIL  pngdiff 取不到位图数据"); return 1 }
        let spp = max(1, a.samplesPerPixel)
        let rowA = a.bytesPerRow, rowB = b.bytesPerRow
        let dd = diffRep?.bitmapData
        for y in 0..<h {
            for x in 0..<w {
                let oa = y * rowA + x * spp, ob = y * rowB + x * spp
                let da = abs(Int(dA[oa]) - Int(dB[ob]))
                let d1 = abs(Int(dA[oa + 1]) - Int(dB[ob + 1]))
                let d2 = abs(Int(dA[oa + 2]) - Int(dB[ob + 2]))
                if da > 2 || d1 > 2 || d2 > 2 {
                    changed += 1
                    if let dd = dd {
                        let o = y * (diffRep?.bytesPerRow ?? 0) + x * max(1, diffRep?.samplesPerPixel ?? 4)
                        dd[o] = 255; dd[o + 1] = 40; dd[o + 2] = 70; dd[o + 3] = 255
                    }
                } else if let dd = dd {
                    let o = y * (diffRep?.bytesPerRow ?? 0) + x * max(1, diffRep?.samplesPerPixel ?? 4)
                    // 未变区域压成浅灰，红色才一眼能看出来是哪儿动了
                    dd[o] = 210; dd[o + 1] = 210; dd[o + 2] = 210; dd[o + 3] = 255
                }
            }
        }
        _ = ctxA; _ = ctxB

        let ratio = Double(changed) / Double(total)
        let pct = String(format: "%.3f%%", ratio * 100)
        if let outPath, let rep = diffRep, let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: outPath))
            print("  差异图：\(outPath)（红=变了，灰=没变）")
        }
        if ratio > threshold {
            print("FAIL  pngdiff 变更像素 \(changed)/\(total) = \(pct) > 阈值 \(String(format: "%.3f%%", threshold * 100))")
            return 1
        }
        print("PASS  pngdiff 变更像素 \(changed)/\(total) = \(pct) ≤ 阈值 \(String(format: "%.3f%%", threshold * 100))")
        return 0
    }

    private static func load(_ path: String) -> NSBitmapImageRep? {
        guard let data = FileManager.default.contents(atPath: path),
              let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep
    }
}
