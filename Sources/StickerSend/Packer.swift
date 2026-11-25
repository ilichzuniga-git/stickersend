import Foundation
import CoreGraphics

/// Shape-aware packing for the sheet.
///
/// Every sticker is turned into a bitmap of the sheet cells its *cut area*
/// covers (opaque silhouette + outline + half the gap), at each allowed
/// rotation. Stickers are then dropped one at a time into the top-most,
/// then left-most, spot where their bitmap clashes with nothing already
/// placed ("bottom-left fill", top-down here). Because it works with real
/// silhouettes, a round sticker can tuck into the hollow beside a tall one,
/// which a box packer can't do.
///
/// Rows of the sheet are bit sets, so testing a position is a few word ANDs.
enum Packer {

    /// One sticker to place.
    struct Piece {
        var id: Int                         // caller's index
        var field: AppModel.SilhouetteField?
        var opaqueBox: CGRect               // fallback, 0…1 of the image
        var aspect: Double                  // image width / height
        var width: Double                   // mm, before `scale`
        var outlineMM: Double
        var baseAngle: Double               // degrees
    }

    struct Placed {
        var id: Int
        var center: CGPoint                 // mm, design space
        var angle: Double                   // degrees
    }

    struct Options {
        var cell = 0.5                      // mm per grid cell
        var gap = 1.0                       // mm between cut lines
        var allowRotation = true
        var area = SheetGeometry.printable
    }

    /// A piece's footprint at one size and angle.
    private struct Mask {
        var w: Int, h: Int
        var rows: [[UInt64]]                // h rows of ceil(w/64) words
        var origin: CGPoint                 // local mm of cell (0,0)'s corner, relative to the sticker centre
    }

    // MARK: Footprints

    private static func mask(_ p: Piece, scale: Double, angle: Double, o: Options) -> Mask? {
        let w = p.width * scale, h = w / p.aspect
        guard w > 0.5, h > 0.5 else { return nil }
        let reach = p.outlineMM + o.gap / 2
        let a = angle * .pi / 180
        let cosA = cos(a), sinA = sin(a)

        // Rotated frame bounds, grown by the reach, centred on (0, 0).
        let hw = w / 2, hh = h / 2
        let ex = abs(hw * cosA) + abs(hh * sinA) + reach + o.cell
        let ey = abs(hw * sinA) + abs(hh * cosA) + reach + o.cell
        let cw = Int((2 * ex / o.cell).rounded(.up)), ch = Int((2 * ey / o.cell).rounded(.up))
        var cells = [Bool](repeating: false, count: cw * ch)
        var minI = cw, maxI = -1, minJ = ch, maxJ = -1

        for j in 0..<ch {
            for i in 0..<cw {
                let lx = -ex + (Double(i) + 0.5) * o.cell, ly = -ey + (Double(j) + 0.5) * o.cell
                // Back into the unrotated frame.
                let fx = lx * cosA + ly * sinA, fy = -lx * sinA + ly * cosA
                let inside: Bool
                if let f = p.field {
                    let mmX = w / Double(f.width), mmY = h / Double(f.height)
                    let u = (fx + hw) / mmX, v = (fy + hh) / mmY
                    let cu = min(max(u, 0), Double(f.width - 1)), cv = min(max(v, 0), Double(f.height - 1))
                    let outside = hypot((u - cu) * mmX, (v - cv) * mmY)
                    let d = Double(f.distance[Int(cv) * f.width + Int(cu)]) * mmX + outside
                    // Half a cell of slack so sampling at cell centres can't miss contact.
                    inside = d <= reach + o.cell * 0.5
                } else {
                    let b = p.opaqueBox
                    let r = CGRect(x: -hw + b.minX * w, y: -hh + b.minY * h, width: b.width * w, height: b.height * h)
                    inside = r.insetBy(dx: -(reach + o.cell * 0.5), dy: -(reach + o.cell * 0.5)).contains(CGPoint(x: fx, y: fy))
                }
                if inside {
                    cells[j * cw + i] = true
                    minI = min(minI, i); maxI = max(maxI, i); minJ = min(minJ, j); maxJ = max(maxJ, j)
                }
            }
        }
        guard maxI >= 0 else { return nil }

        let mw = maxI - minI + 1, mh = maxJ - minJ + 1
        let words = (mw + 63) / 64
        var rows = [[UInt64]](repeating: [UInt64](repeating: 0, count: words), count: mh)
        for j in 0..<mh {
            for i in 0..<mw where cells[(j + minJ) * cw + (i + minI)] {
                rows[j][i / 64] |= 1 << UInt64(i % 64)
            }
        }
        return Mask(w: mw, h: mh, rows: rows,
                    origin: CGPoint(x: -ex + Double(minI) * o.cell, y: -ey + Double(minJ) * o.cell))
    }

    // MARK: Grid

    private struct Grid {
        let w: Int, h: Int, words: Int
        var rows: [[UInt64]]
        init(w: Int, h: Int) {
            self.w = w; self.h = h; words = (w + 63) / 64 + 1
            rows = [[UInt64]](repeating: [UInt64](repeating: 0, count: (w + 63) / 64 + 1), count: h)
        }

        func fits(_ m: Mask, _ gx: Int, _ gy: Int) -> Bool {
            let shift = UInt64(gx % 64), base = gx / 64
            for j in 0..<m.h {
                let occ = rows[gy + j]
                for (k, bits) in m.rows[j].enumerated() where bits != 0 {
                    if occ[base + k] & (bits << shift) != 0 { return false }
                    if shift > 0, occ[base + k + 1] & (bits >> (64 - shift)) != 0 { return false }
                }
            }
            return true
        }

        mutating func place(_ m: Mask, _ gx: Int, _ gy: Int) {
            let shift = UInt64(gx % 64), base = gx / 64
            for j in 0..<m.h {
                for (k, bits) in m.rows[j].enumerated() where bits != 0 {
                    rows[gy + j][base + k] |= bits << shift
                    if shift > 0 { rows[gy + j][base + k + 1] |= bits >> (64 - shift) }
                }
            }
        }

        /// Top-most, then left-most, position where `m` fits.
        func firstFit(_ m: Mask) -> (Int, Int)? {
            guard m.w <= w, m.h <= h else { return nil }
            for gy in 0...(h - m.h) {
                for gx in 0...(w - m.w) where fits(m, gx, gy) { return (gx, gy) }
            }
            return nil
        }
    }

    // MARK: Packing

    /// Upright and sideways only: 180° would print the sticker upside down
    /// on the sheet, which reads badly even though it cuts fine.
    private static func angles(_ p: Piece, _ o: Options) -> [Double] {
        o.allowRotation ? [0, 90, -90].map { p.baseAngle + $0 } : [p.baseAngle]
    }

    /// The grid covers the safe area plus half a gap all round: the footprint
    /// includes half the gap, and nothing needs a gap to the sheet edge.
    private static func makeGrid(_ o: Options) -> (Grid, CGPoint) {
        let origin = CGPoint(x: o.area.minX - o.gap / 2, y: o.area.minY - o.gap / 2)
        let gw = Int(((o.area.width + o.gap) / o.cell).rounded(.down))
        let gh = Int(((o.area.height + o.gap) / o.cell).rounded(.down))
        return (Grid(w: gw, h: gh), origin)
    }

    /// Place `order` pieces in turn. `stopAtFirstMiss` makes it all-or-nothing.
    private static func run(_ pieces: [Piece], order: [Int], scale: Double, o: Options,
                            stopAtFirstMiss: Bool, masks: inout [String: Mask?]) -> [Placed]? {
        var (grid, origin) = makeGrid(o)
        var out: [Placed] = []
        for idx in order {
            let p = pieces[idx]
            var best: (gx: Int, gy: Int, angle: Double, m: Mask)?
            for angle in angles(p, o) {
                let key = "\(idx)|\(angle)"
                if masks[key] == nil { masks[key] = mask(p, scale: scale, angle: angle, o: o) }
                guard let m = masks[key] ?? nil, let (gx, gy) = grid.firstFit(m) else { continue }
                if best == nil || better(gx, gy, than: best!.gx, best!.gy, turned: angle != p.baseAngle, o: o) {
                    best = (gx, gy, angle, m)
                }
            }
            guard let b = best else {
                if stopAtFirstMiss { return nil }
                continue
            }
            grid.place(b.m, b.gx, b.gy)
            let center = CGPoint(x: origin.x + Double(b.gx) * o.cell - b.m.origin.x,
                                 y: origin.y + Double(b.gy) * o.cell - b.m.origin.y)
            out.append(Placed(id: p.id, center: center, angle: b.angle))
        }
        return out
    }

    /// Is (gx, gy) a better spot? Higher on the sheet wins, then further left.
    /// A turned sticker must win by at least 2 mm, so stickers stay upright
    /// unless turning them really saves space.
    private static func better(_ gx: Int, _ gy: Int, than bx: Int, _ by: Int, turned: Bool, o: Options) -> Bool {
        let margin = turned ? Int((2 / o.cell).rounded()) : 0
        if gy + margin < by { return true }
        if gy > by + margin { return false }
        return turned ? false : (gy < by || (gy == by && gx < bx))
    }

    /// Largest-first order, which packs best for bottom-left fill.
    private static func bigFirst(_ pieces: [Piece]) -> [Int] {
        pieces.indices.sorted { pieces[$0].width * pieces[$0].width / pieces[$0].aspect
                              > pieces[$1].width * pieces[$1].width / pieces[$1].aspect }
    }

    /// Place every piece at `scale`, or nil if they don't all fit.
    static func packAll(_ pieces: [Piece], scale: Double, o: Options) -> [Placed]? {
        var masks: [String: Mask?] = [:]
        return run(pieces, order: bigFirst(pieces), scale: scale, o: o, stopAtFirstMiss: true, masks: &masks)
    }

    /// The largest uniform scale (≤ `maxScale`) at which every piece fits,
    /// with its placements. Binary search; bottom-left fill isn't perfectly
    /// monotonic in scale, so the best feasible result seen is kept.
    static func packLargest(_ pieces: [Piece], maxScale: Double, o: Options,
                            steps: Int = 12) -> (scale: Double, placed: [Placed])? {
        var lo = 0.0, hi = maxScale
        var best: (Double, [Placed])?
        if let all = packAll(pieces, scale: hi, o: o) { return (hi, all) }
        for _ in 0..<steps {
            let mid = (lo + hi) / 2
            if let all = packAll(pieces, scale: mid, o: o) {
                best = (mid, all); lo = mid
            } else {
                hi = mid
            }
        }
        return best
    }

    /// Fill the sheet with copies of the pieces at their current size, taking
    /// them in turn, until a full round places nothing.
    static func packCopies(_ pieces: [Piece], o: Options, limit: Int = 300) -> [Placed] {
        var (grid, origin) = makeGrid(o)
        var masks: [String: Mask] = [:]
        var out: [Placed] = []
        var stuck = Set<Int>()
        while out.count < limit && stuck.count < pieces.count {
            for idx in pieces.indices where !stuck.contains(idx) {
                let p = pieces[idx]
                var best: (gx: Int, gy: Int, angle: Double, m: Mask)?
                for angle in angles(p, o) {
                    let key = "\(idx)|\(angle)"
                    if masks[key] == nil, let m = mask(p, scale: 1, angle: angle, o: o) { masks[key] = m }
                    guard let m = masks[key], let (gx, gy) = grid.firstFit(m) else { continue }
                    if best == nil || better(gx, gy, than: best!.gx, best!.gy, turned: angle != p.baseAngle, o: o) {
                        best = (gx, gy, angle, m)
                    }
                }
                guard let b = best else { stuck.insert(idx); continue }
                grid.place(b.m, b.gx, b.gy)
                out.append(Placed(id: p.id,
                                  center: CGPoint(x: origin.x + Double(b.gx) * o.cell - b.m.origin.x,
                                                  y: origin.y + Double(b.gy) * o.cell - b.m.origin.y),
                                  angle: b.angle))
                if out.count >= limit { break }
            }
        }
        return out
    }
}
