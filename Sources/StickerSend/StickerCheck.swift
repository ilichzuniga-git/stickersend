import Foundation
import CoreGraphics
import ImageIO

/// The pre-flight checks from MINIMAX-STICKER-PLAYBOOK.md §0 and §8, run on a
/// finished sticker PNG before it goes onto a print sheet.
///
/// Each check corresponds to a defect the playbook calls out because it showed
/// up on real stickers: a missing alpha channel, a border that is not white,
/// holes that make the cutter run extra loops, stray specks that become tiny
/// cuts, and artwork that touches the canvas edge.
struct StickerReport {
    enum Level: Int, Comparable {
        case pass = 0, info = 1, warn = 2, fail = 3
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    struct Check: Identifiable {
        let id: String
        let title: String
        let level: Level
        let detail: String
    }

    var width = 0
    var height = 0
    var checks: [Check] = []

    /// Number of separate cut loops the tracer will produce (outlines + holes + specks).
    var cutLoops = 0

    /// The opaque part of the image, as a fraction of its size (0…1). Used to
    /// spot stickers whose cut outlines overlap on the sheet.
    var opaqueBox = CGRect(x: 0, y: 0, width: 1, height: 1)

    var overall: Level { checks.map(\.level).max() ?? .fail }
}

enum StickerCheck {

    /// Analyse a sticker. Work is done on a downsampled copy (long side at
    /// most `analysisSize`) so a 2000px sticker checks in a few milliseconds.
    static func run(url: URL, analysisSize: Int = 640) -> StickerReport {
        var report = StickerReport()

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            report.checks.append(.init(id: "read", title: "Readable image", level: .fail,
                                       detail: "Could not open the file."))
            return report
        }
        report.width = image.width
        report.height = image.height

        // 1. Transparent PNG
        let alphaInfo = image.alphaInfo
        let hasAlpha = !(alphaInfo == .none || alphaInfo == .noneSkipFirst || alphaInfo == .noneSkipLast)
        let isPNG = url.pathExtension.lowercased() == "png"
        if !hasAlpha || !isPNG {
            report.checks.append(.init(id: "alpha", title: "Transparent PNG", level: .fail,
                                       detail: hasAlpha ? "Not a PNG file." : "No alpha channel — the whole rectangle would be cut."))
            return report
        }

        // Downsample into an RGBA buffer.
        let longSide = max(image.width, image.height)
        let scale = min(1.0, Double(analysisSize) / Double(longSide))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            report.checks.append(.init(id: "read", title: "Readable image", level: .fail, detail: "Could not decode pixels."))
            return report
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        // Same threshold the cutter uses (SheetBuilder.silhouette).
        var mask = [Bool](repeating: false, count: w * h)
        var opaqueCount = 0
        for i in 0..<(w * h) where px[i * 4 + 3] > 128 {
            mask[i] = true
            opaqueCount += 1
        }

        let cornersClear = [0, w - 1, (h - 1) * w, h * w - 1].allSatisfy { px[$0 * 4 + 3] < 16 }
        if opaqueCount == 0 {
            report.checks.append(.init(id: "alpha", title: "Transparent PNG", level: .fail, detail: "The image is fully transparent."))
            return report
        }
        report.checks.append(.init(
            id: "alpha", title: "Transparent PNG",
            level: cornersClear ? .pass : .fail,
            detail: cornersClear ? "Background is transparent."
                                 : "Corners are opaque — there is still a background or checkerboard."))

        // Connected components of the opaque mask (4-connected, like the tracer).
        let (labels, sizes) = components(of: mask, w: w, h: h, value: true)
        let mainSize = sizes.max() ?? 0
        // Anything under 0.05% of the main shape is a speck.
        let speckLimit = max(4, mainSize / 2000)
        let shapes = sizes.filter { $0 > speckLimit }.count
        let specks = sizes.filter { $0 <= speckLimit }.count

        // Holes: transparent components that do not touch the image edge.
        let (_, holeSizes, holeTouchesEdge) = transparentComponents(mask: mask, w: w, h: h)
        let holes = zip(holeSizes, holeTouchesEdge).filter { !$0.1 }.count
        report.cutLoops = sizes.count + holes

        // 2. White border: the outermost ring of the shape should be white.
        let dist = distanceToTransparent(mask: mask, w: w, h: h)
        let ringDepth = max(2, Int((10.0 * scale).rounded()))   // ~10px of the 20px border
        var ringTotal = 0, ringWhite = 0
        for i in 0..<(w * h) where mask[i] && dist[i] >= 1 && dist[i] <= ringDepth {
            // Only look at the main shape so specks don't skew it.
            if sizes[labels[i]] != mainSize { continue }
            ringTotal += 1
            let a = Int(px[i * 4 + 3])
            // Un-premultiply.
            let r = a > 0 ? Int(px[i * 4]) * 255 / a : 0
            let g = a > 0 ? Int(px[i * 4 + 1]) * 255 / a : 0
            let b = a > 0 ? Int(px[i * 4 + 2]) * 255 / a : 0
            if r >= 230 && g >= 230 && b >= 230 { ringWhite += 1 }
        }
        let whiteShare = ringTotal > 0 ? Double(ringWhite) / Double(ringTotal) : 0
        // A coloured border still cuts fine, so this is never a blocker.
        let borderLevel: StickerReport.Level = whiteShare >= 0.92 ? .pass : .warn
        report.checks.append(.init(
            id: "border", title: "White border",
            level: borderLevel,
            detail: String(format: "%.0f%% of the outer ring is white", whiteShare * 100)
                + (borderLevel == .pass ? "." : " — the playbook wants a solid 20px white border all the way round.")))

        // 3. One shape, no holes.
        let shapeLevel: StickerReport.Level = (shapes == 1 && holes == 0) ? .pass : .fail
        var shapeDetail: String
        if shapes == 1 && holes == 0 {
            shapeDetail = "One connected outline — the cutter runs a single path."
        } else {
            var parts: [String] = []
            if shapes > 1 { parts.append("\(shapes) separate shapes") }
            if holes > 0 { parts.append("\(holes) hole\(holes == 1 ? "" : "s") inside the border") }
            shapeDetail = parts.joined(separator: ", ") + ". Each one becomes an extra cut; fill gaps white."
        }
        report.checks.append(.init(id: "shape", title: "One shape, no holes", level: shapeLevel, detail: shapeDetail))

        // 4. Clean edges: stray specks outside the border.
        report.checks.append(.init(
            id: "specks", title: "No stray specks",
            level: specks == 0 ? .pass : .warn,
            detail: specks == 0 ? "Nothing floating outside the outline."
                                : "\(specks) speck\(specks == 1 ? "" : "s") outside the outline — each would be cut as a tiny loop."))

        // 6. Breathing room: ~40px transparent margin.
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w where mask[y * w + x] {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        report.opaqueBox = CGRect(x: Double(minX) / Double(w), y: Double(minY) / Double(h),
                                  width: Double(maxX - minX + 1) / Double(w), height: Double(maxY - minY + 1) / Double(h))
        let marginPx = Double(min(minX, minY, w - 1 - maxX, h - 1 - maxY)) / scale
        let marginLevel: StickerReport.Level = marginPx >= 30 ? .pass : (marginPx >= 8 ? .warn : .fail)
        report.checks.append(.init(
            id: "margin", title: "Breathing room",
            level: marginLevel,
            detail: String(format: "≈%.0fpx transparent margin", marginPx)
                + (marginLevel == .pass ? "." : marginLevel == .warn ? " (playbook target is about 40px)." : " — the border touches the canvas edge and will be clipped.")))

        // Size guidance from §4c.
        let sizeLevel: StickerReport.Level = longSide < 700 ? .warn : ((1200...2200).contains(longSide) ? .pass : .info)
        report.checks.append(.init(
            id: "size", title: "Resolution",
            level: sizeLevel,
            detail: "\(image.width)×\(image.height)px"
                + (longSide < 700 ? " — small; may print soft." : longSide < 1200 ? " (target long side 1200–2200px)." : longSide > 2200 ? " (larger than needed, fine)." : ".")))

        return report
    }

    // MARK: Helpers

    /// Label 4-connected components where `mask == value`.
    private static func components(of mask: [Bool], w: Int, h: Int, value: Bool) -> (labels: [Int], sizes: [Int]) {
        var labels = [Int](repeating: -1, count: w * h)
        var sizes: [Int] = []
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] == value && labels[start] < 0 {
            let label = sizes.count
            var size = 0
            labels[start] = label
            stack.append(start)
            while let i = stack.popLast() {
                size += 1
                let x = i % w, y = i / w
                if x > 0, mask[i - 1] == value, labels[i - 1] < 0 { labels[i - 1] = label; stack.append(i - 1) }
                if x < w - 1, mask[i + 1] == value, labels[i + 1] < 0 { labels[i + 1] = label; stack.append(i + 1) }
                if y > 0, mask[i - w] == value, labels[i - w] < 0 { labels[i - w] = label; stack.append(i - w) }
                if y < h - 1, mask[i + w] == value, labels[i + w] < 0 { labels[i + w] = label; stack.append(i + w) }
            }
            sizes.append(size)
        }
        return (labels, sizes)
    }

    private static func transparentComponents(mask: [Bool], w: Int, h: Int) -> (labels: [Int], sizes: [Int], touchesEdge: [Bool]) {
        let (labels, sizes) = components(of: mask, w: w, h: h, value: false)
        var edge = [Bool](repeating: false, count: sizes.count)
        for x in 0..<w {
            if labels[x] >= 0 { edge[labels[x]] = true }
            let b = (h - 1) * w + x
            if labels[b] >= 0 { edge[labels[b]] = true }
        }
        for y in 0..<h {
            if labels[y * w] >= 0 { edge[labels[y * w]] = true }
            let r = y * w + w - 1
            if labels[r] >= 0 { edge[labels[r]] = true }
        }
        return (labels, sizes, edge)
    }

    /// City-block distance from each opaque pixel to the nearest transparent one.
    private static func distanceToTransparent(mask: [Bool], w: Int, h: Int) -> [Int] {
        let big = w + h
        var d = mask.map { $0 ? big : 0 }
        for y in 0..<h { for x in 0..<w {
            let i = y * w + x
            guard d[i] > 0 else { continue }
            let up = y > 0 ? d[i - w] + 1 : 1
            let left = x > 0 ? d[i - 1] + 1 : 1
            d[i] = min(d[i], up, left)
        } }
        for y in stride(from: h - 1, through: 0, by: -1) { for x in stride(from: w - 1, through: 0, by: -1) {
            let i = y * w + x
            guard d[i] > 0 else { continue }
            let down = y < h - 1 ? d[i + w] + 1 : 1
            let right = x < w - 1 ? d[i + 1] + 1 : 1
            d[i] = min(d[i], down, right)
        } }
        return d
    }
}
