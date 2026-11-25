import Foundation
import CoreGraphics
import ImageIO

/// An extra outline grown around a sticker's silhouette, behind the artwork.
///
/// This file is shared verbatim with StickerSend (symlinked into its target)
/// so the on-screen preview is drawn by the same code that builds the sheet.
struct OutlineSpec: Codable, Equatable {
    /// Outline thickness beyond the sticker's edge, in design millimetres.
    /// Decorative edges (scallops, teeth) reach exactly this far out.
    var widthMM: Double = 0
    /// `#rrggbb`
    var color: String = "#ffffff"
    /// Fill enclosed holes so the sticker cuts as one shape (playbook §0.3).
    var fillGaps: Bool = true
    /// Border style. Optional so sheets saved before styles existed still load.
    var style: OutlineStyle?

    var kind: OutlineStyle { style ?? .plain }
    var isActive: Bool { widthMM > 0.001 || fillGaps }
}

/// Preset decorative borders. Every style stays inside `widthMM`, and the
/// cut follows whatever is drawn, so the blade cuts scallops, teeth and lace
/// eyelets exactly as they print.
enum OutlineStyle: String, Codable, CaseIterable, Identifiable {
    case plain, scalloped, lace, pinked, stitched

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plain: return "Plain"
        case .scalloped: return "Scalloped"
        case .lace: return "Lace"
        case .pinked: return "Pinked"
        case .stitched: return "Stitched"
        }
    }

    var blurb: String {
        switch self {
        case .plain: return "A smooth, even border."
        case .scalloped: return "A wavy, bumpy edge."
        case .lace: return "Scallops plus a ring of cut-out eyelets, like a paper doily. Weed the little holes after cutting."
        case .pinked: return "A zigzag edge, like pinking shears."
        case .stitched: return "A printed dashed stitch line inside a plain border."
        }
    }

    /// Narrower than this and the pattern is too fine to cut cleanly.
    var minimumWidthMM: Double {
        switch self {
        case .plain: return 0
        case .scalloped: return 2.5
        case .lace: return 4
        case .pinked: return 2
        case .stitched: return 2.5
        }
    }

    /// The width picked when switching to this style from something narrower.
    var suggestedWidthMM: Double {
        switch self {
        case .plain: return 2
        case .scalloped: return 3.5
        case .lace: return 5
        case .pinked: return 3
        case .stitched: return 3.5
        }
    }
}

enum OutlineRenderer {

    /// Grow an outline around `image`.
    ///
    /// The silhouette is the cutter's (alpha > 128). Every transparent pixel
    /// within `radius` pixels of it is painted in `rgb`, antialiased on the
    /// outer edge; with `fillGaps`, enclosed transparent regions are filled
    /// too. The artwork is composited on top, unchanged.
    ///
    /// - Returns: the new image, `pad` pixels larger on every side than the
    ///   input, so the original sits at the same place relative to the centre.
    static func render(_ image: CGImage, radius: Double,
                       rgb: (r: Double, g: Double, b: Double),
                       fillGaps: Bool,
                       style: OutlineStyle = .plain) -> (image: CGImage, pad: Int)? {
        let r = max(0, radius)
        // Decorations need room; below a few pixels fall back to plain.
        let style: OutlineStyle = r >= 4 ? style : .plain
        // `a` is the decoration size; the smooth base band stops at `rb` and
        // the decoration reaches from there out to exactly `r`.
        let a: Double
        switch style {
        case .scalloped: a = 0.4 * r
        case .lace: a = 0.3 * r
        case .pinked: a = 0.35 * r
        case .plain, .stitched: a = 0
        }
        let rb = r - a
        let pad = r > 0 ? Int(r.rounded(.up)) + 2 : 0
        let w = image.width + 2 * pad, h = image.height + 2 * pad
        guard w > 0, h > 0 else { return nil }

        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Symmetric padding, so the bitmap's y direction does not matter here.
        ctx.draw(image, in: CGRect(x: pad, y: pad, width: image.width, height: image.height))

        // Outline coverage, 0…1 per pixel.
        var cover = [Double](repeating: 0, count: w * h)
        if r > 0 {
            let d2 = squaredDistanceToOpaque(px: px, w: w, h: h)
            for i in 0..<(w * h) {
                cover[i] = min(1, max(0, rb + 0.5 - d2[i].squareRoot()))
            }
        } else {
            for i in 0..<(w * h) where px[i * 4 + 3] > 128 { cover[i] = 1 }
        }

        if fillGaps {
            // Solid = outline or artwork. Flood the empty space from the
            // border; anything empty that the flood can't reach is a hole.
            // "Solid" must mean exactly what the cutter will see: final
            // alpha above 128. A pixel at 50% coverage composites to 128 and
            // is empty to the cutter, so counting it solid here would leave a
            // one-pixel sliver ring between the artwork and the filled hole.
            let solid = (0..<(w * h)).map { i -> Bool in
                let sa = Double(px[i * 4 + 3]) / 255
                return ((sa + cover[i] * (1 - sa)) * 255).rounded() > 128
            }
            var outside = [Bool](repeating: false, count: w * h)
            var stack: [Int] = []
            func seed(_ i: Int) { if !solid[i] && !outside[i] { outside[i] = true; stack.append(i) } }
            for x in 0..<w { seed(x); seed((h - 1) * w + x) }
            for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
            while let i = stack.popLast() {
                let x = i % w, y = i / w
                if x > 0 { seed(i - 1) }
                if x < w - 1 { seed(i + 1) }
                if y > 0 { seed(i - w) }
                if y < h - 1 { seed(i + w) }
            }
            for i in 0..<(w * h) where !solid[i] && !outside[i] { cover[i] = 1 }
        }

        // Decorations, drawn along the base band's outer edge.
        var stitch = [UInt8](repeating: 0, count: w * h)
        if style != .plain, r > 0 {
            let solid = (0..<(w * h)).map { cover[$0] >= 0.5 || px[$0 * 4 + 3] > 128 }
            let loops = outerLoops(solid, w: w, h: h).map {
                resample(smooth($0, window: max(2, Int(max(a, r * 0.3) * 0.8))), step: style == .stitched ? 2 : 2 * a * 0.92)
            }.filter { $0.count >= 3 }

            var add = [UInt8](repeating: 0, count: w * h)
            var holes = [UInt8](repeating: 0, count: w * h)
            draw(into: &add, w: w, h: h) { ctx in
                for loop in loops {
                    for (i, p) in loop.enumerated() {
                        switch style {
                        case .scalloped, .lace:
                            ctx.fillEllipse(in: CGRect(x: p.x - a, y: p.y - a, width: 2 * a, height: 2 * a))
                        case .pinked:
                            let q = loop[(i + 1) % loop.count]
                            let n = normal(loop, (i + 1) % loop.count, between: i)
                            let mid = CGPoint(x: (p.x + q.x) / 2 + n.x * a, y: (p.y + q.y) / 2 + n.y * a)
                            ctx.move(to: p); ctx.addLine(to: mid); ctx.addLine(to: q); ctx.closePath()
                            ctx.fillPath()
                        default: break
                        }
                    }
                }
            }
            if style == .lace {
                // Oval eyelets in the middle of the base band, one per scallop,
                // long axis pointing outward.
                draw(into: &holes, w: w, h: h) { ctx in
                    for loop in loops {
                        for i in loop.indices {
                            let n = normal(loop, i)
                            let c = CGPoint(x: loop[i].x - n.x * rb * 0.5, y: loop[i].y - n.y * rb * 0.5)
                            ctx.saveGState()
                            ctx.translateBy(x: c.x, y: c.y)
                            ctx.rotate(by: atan2(n.y, n.x))
                            let ry = rb * 0.28, rx = a * 0.42
                            ctx.fillEllipse(in: CGRect(x: -ry, y: -rx, width: 2 * ry, height: 2 * rx))
                            ctx.restoreGState()
                        }
                    }
                }
            }
            if style == .stitched {
                draw(into: &stitch, w: w, h: h) { ctx in
                    ctx.setLineWidth(max(1.5, 0.09 * r))
                    ctx.setLineCap(.round)
                    ctx.setLineDash(phase: 0, lengths: [0.45 * r, 0.32 * r])
                    for loop in loops {
                        for (i, p) in loop.enumerated() {
                            let n = normal(loop, i)
                            let q = CGPoint(x: p.x - n.x * rb * 0.5, y: p.y - n.y * rb * 0.5)
                            if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) }
                        }
                        ctx.closePath()
                    }
                    ctx.strokePath()
                }
            }
            for i in 0..<(w * h) {
                var c = max(cover[i], Double(add[i]) / 255)
                if holes[i] > 0 { c *= 1 - Double(holes[i]) / 255 }
                cover[i] = c
            }
        }

        // A stitch line contrasts with the band: grey on light bands, white on dark.
        let light = 0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b > 0.6
        let stitchRGB = light ? (r: 0.55, g: 0.55, b: 0.55) : (r: 1.0, g: 1.0, b: 1.0)

        // Outline underneath, artwork on top (premultiplied source-over).
        for i in 0..<(w * h) {
            let c = cover[i]
            guard c > 0 else { continue }
            let t = Double(stitch[i]) / 255
            let br = rgb.r + (stitchRGB.r - rgb.r) * t
            let bg = rgb.g + (stitchRGB.g - rgb.g) * t
            let bb = rgb.b + (stitchRGB.b - rgb.b) * t
            let sa = Double(px[i * 4 + 3]) / 255
            let k = c * (1 - sa) * 255
            px[i * 4] = UInt8(min(255, Double(px[i * 4]) + br * k).rounded())
            px[i * 4 + 1] = UInt8(min(255, Double(px[i * 4 + 1]) + bg * k).rounded())
            px[i * 4 + 2] = UInt8(min(255, Double(px[i * 4 + 2]) + bb * k).rounded())
            px[i * 4 + 3] = UInt8(min(255, Double(px[i * 4 + 3]) + k).rounded())
        }

        guard let out = ctx.makeImage() else { return nil }
        return (out, pad)
    }

    // MARK: Decoration geometry
    //
    // Points are in the bitmap's user space: x right, y UP, so pixel row r
    // (row 0 at the top) spans y = h-r-1 … h-r. Drawing helpers use the same.

    /// Run `body` on an 8-bit grey context over `buffer` (0 = empty, 255 = full).
    private static func draw(into buffer: inout [UInt8], w: Int, h: Int, _ body: (CGContext) -> Void) {
        buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setShouldAntialias(true)
            body(ctx)
        }
    }

    /// Outer boundaries of the solid regions, as closed polygons in user space.
    ///
    /// Crack following: each solid pixel side facing empty space becomes a
    /// directed edge with the solid side on its right (in y-down terms), and
    /// edges are chained into loops. Outer boundaries then have positive
    /// shoelace area in y-down coordinates; holes are negative and skipped.
    static func outerLoops(_ solid: [Bool], w: Int, h: Int) -> [[CGPoint]] {
        func filled(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y < h && solid[y * w + x] }
        var next: [Int: [Int]] = [:]       // start vertex -> end vertices
        func key(_ x: Int, _ y: Int) -> Int { y * (w + 2) + x }
        var edges: [(Int, Int, Int, Int)] = []
        for y in 0..<h {
            for x in 0..<w where solid[y * w + x] {
                if !filled(x, y - 1) { edges.append((x, y, x + 1, y)) }
                if !filled(x + 1, y) { edges.append((x + 1, y, x + 1, y + 1)) }
                if !filled(x, y + 1) { edges.append((x + 1, y + 1, x, y + 1)) }
                if !filled(x - 1, y) { edges.append((x, y + 1, x, y)) }
            }
        }
        for (i, e) in edges.enumerated() { next[key(e.0, e.1), default: []].append(i) }
        var used = [Bool](repeating: false, count: edges.count)
        var loops: [[CGPoint]] = []
        for start in edges.indices where !used[start] {
            var loop: [(Int, Int)] = []
            var i = start
            while !used[i] {
                used[i] = true
                let e = edges[i]
                loop.append((e.0, e.1))
                guard let cands = next[key(e.2, e.3)], let n = cands.first(where: { !used[$0] }) else { break }
                i = n
            }
            guard loop.count > 8 else { continue }
            var area = 0.0
            for k in loop.indices {
                let p = loop[k], q = loop[(k + 1) % loop.count]
                area += Double(p.0 * q.1 - q.0 * p.1)
            }
            guard area > 0 else { continue }   // a hole
            loops.append(loop.map { CGPoint(x: Double($0.0), y: Double(h - $0.1)) })
        }
        return loops
    }

    /// Circular moving average, to take the stair-steps out of a pixel outline.
    static func smooth(_ loop: [CGPoint], window: Int) -> [CGPoint] {
        let n = loop.count
        guard n > 2 * window + 1 else { return loop }
        return (0..<n).map { i in
            var sx = 0.0, sy = 0.0
            for k in -window...window { let p = loop[(i + k + n) % n]; sx += p.x; sy += p.y }
            let c = Double(2 * window + 1)
            return CGPoint(x: sx / c, y: sy / c)
        }
    }

    /// Evenly spaced points along a closed polygon, about `step` apart.
    static func resample(_ loop: [CGPoint], step: Double) -> [CGPoint] {
        let n = loop.count
        guard n > 2, step > 0 else { return loop }
        var lengths = [0.0]
        for i in 0..<n {
            let p = loop[i], q = loop[(i + 1) % n]
            lengths.append(lengths.last! + hypot(q.x - p.x, q.y - p.y))
        }
        let total = lengths.last!
        let count = max(3, Int((total / step).rounded()))
        let spacing = total / Double(count)
        var out: [CGPoint] = []
        var seg = 0
        for k in 0..<count {
            let target = Double(k) * spacing
            while seg < n - 1 && lengths[seg + 1] < target { seg += 1 }
            let p = loop[seg], q = loop[(seg + 1) % n]
            let len = lengths[seg + 1] - lengths[seg]
            let t = len > 0 ? (target - lengths[seg]) / len : 0
            out.append(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t))
        }
        return out
    }

    /// Outward unit normal at point `i` (or between two points). The loops
    /// run with the solid on the right in y-down terms, i.e. clockwise on
    /// screen; in y-up user space the outward side of travel (dx, dy) is
    /// (-dy, dx).
    private static func normal(_ loop: [CGPoint], _ i: Int, between j: Int? = nil) -> CGPoint {
        let n = loop.count
        let a = loop[((j ?? i) - 1 + n) % n], b = loop[(i + 1) % n]
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1e-9, hypot(dx, dy))
        return CGPoint(x: -dy / len, y: dx / len)
    }

    static func parse(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let v = UInt32(text, radix: 16) else { return (1, 1, 1) }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    /// Exact squared Euclidean distance from every pixel to the nearest pixel
    /// with alpha > 128 (Felzenszwalb & Huttenlocher, two separable passes).
    static func squaredDistanceToOpaque(px: [UInt8], w: Int, h: Int) -> [Double] {
        let inf = 1e20
        var grid = [Double](repeating: inf, count: w * h)
        for i in 0..<(w * h) where px[i * 4 + 3] > 128 { grid[i] = 0 }

        let n = max(w, h)
        var f = [Double](repeating: 0, count: n)
        var d = [Double](repeating: 0, count: n)
        var v = [Int](repeating: 0, count: n)
        var z = [Double](repeating: 0, count: n + 1)

        func transform(_ count: Int) {
            var k = 0
            v[0] = 0; z[0] = -inf; z[1] = inf
            if count > 1 {
                for q in 1..<count {
                    func intersection(_ p: Int) -> Double {
                        ((f[q] + Double(q * q)) - (f[p] + Double(p * p))) / Double(2 * q - 2 * p)
                    }
                    var s = intersection(v[k])
                    // z[0] is -inf, so this always stops at k == 0.
                    while s <= z[k] { k -= 1; s = intersection(v[k]) }
                    k += 1; v[k] = q; z[k] = s; z[k + 1] = inf
                }
            }
            k = 0
            for q in 0..<count {
                while z[k + 1] < Double(q) { k += 1 }
                let p = v[k]
                d[q] = Double((q - p) * (q - p)) + f[p]
            }
        }

        for x in 0..<w {
            for y in 0..<h { f[y] = grid[y * w + x] }
            transform(h)
            for y in 0..<h { grid[y * w + x] = d[y] }
        }
        for y in 0..<h {
            for x in 0..<w { f[x] = grid[y * w + x] }
            transform(w)
            for x in 0..<w { grid[y * w + x] = d[x] }
        }
        return grid
    }
}
