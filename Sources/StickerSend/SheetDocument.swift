import Foundation
import CoreGraphics

/// Sheet geometry, in design millimetres. Must agree with `SheetProfile` in
/// the CLI (`Sources/CricutBT/CutFile.swift`).
enum SheetGeometry {
    /// The design canvas that stickers are placed on.
    static let width = 96.0
    static let height = 170.0
    /// Keep stickers this far inside the canvas, like the CLI's column layout.
    static let margin = 2.0

    /// The whole 1200 × 2100 print raster expressed in design millimetres,
    /// using `SheetProfile.rasterXFromMM` / `rasterYFromMM`. A background fills
    /// the whole raster, so it reaches slightly beyond the design canvas.
    static let paper: CGRect = {
        let sx = 11.695795937647613, ox = 34.6017949929146
        let sy = 11.674659518087138, oy = 57.134652123004514
        let x0 = (0 - ox) / sx, x1 = (1200 - ox) / sx
        let y0 = (0 - oy) / sy, y1 = (2100 - oy) / sy
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }()

    static var printable: CGRect {
        CGRect(x: margin, y: margin, width: width - 2 * margin, height: height - 2 * margin)
    }
}

/// One sticker on the sheet. Position and size are in design millimetres,
/// top-left origin. Aspect ratio always matches the PNG.
struct PlacedItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var path: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Clockwise degrees about the centre. Optional so older sheets load.
    var rotation: Double?
    /// Extra outline grown around the sticker (shared with `cricut-bt`).
    var outline: OutlineSpec?

    var outlineMM: Double { outline?.widthMM ?? 0 }
    /// The frame including the outline.
    var outerRect: CGRect { rect.insetBy(dx: -outlineMM, dy: -outlineMM) }

    init(id: UUID = UUID(), path: String, x: Double, y: Double, width: Double, height: Double,
         rotation: Double? = nil, outline: OutlineSpec? = nil) {
        self.id = id; self.path = path; self.x = x; self.y = y
        self.width = width; self.height = height; self.rotation = rotation; self.outline = outline
    }

    /// `id` is optional on disk, so layouts written by hand or for the CLI open too.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        path = try c.decode(String.self, forKey: .path)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation)
        outline = try c.decodeIfPresent(OutlineSpec.self, forKey: .outline)
    }

    var url: URL { URL(fileURLWithPath: path) }
    /// The unrotated frame.
    var rect: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }
    var angle: Double {
        get { rotation ?? 0 }
        set {
            var a = newValue.truncatingRemainder(dividingBy: 360)
            if a > 180 { a -= 360 }
            if a <= -180 { a += 360 }
            rotation = abs(a) < 0.001 ? nil : a
        }
    }
    var center: CGPoint {
        get { CGPoint(x: x + width / 2, y: y + height / 2) }
        set { x = newValue.x - width / 2; y = newValue.y - height / 2 }
    }

    /// Rotate a point of the unrotated frame about the centre (y-down, so
    /// positive is clockwise — the same convention as `cricut-bt`).
    func rotated(_ p: CGPoint) -> CGPoint {
        let a = angle * .pi / 180
        let c = center
        let dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    /// Axis-aligned bounds of a sub-rectangle of the frame after rotation.
    func rotatedBounds(of r: CGRect) -> CGRect {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                   CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map(rotated)
        let xs = pts.map(\.x), ys = pts.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// What the sticker, outline included, occupies on the sheet once rotated.
    var bounds: CGRect { rotatedBounds(of: outerRect) }
}

struct SheetBackgroundSpec: Codable, Equatable {
    /// `#rrggbb`
    var color: String?
    /// Image file, aspect-filled across the whole print raster.
    var path: String?

    var isEmpty: Bool { color == nil && path == nil }
}

/// A saved sheet (`.stickersheet`). The same JSON is handed to
/// `cricut-bt sheet-layout`, which ignores the `id` fields.
struct SheetDocument: Codable, Equatable {
    var name = "Untitled Sheet"
    var copies = 1
    /// Locked behind the stickers; printed, never cut.
    var background: SheetBackgroundSpec?
    /// Back to front.
    var items: [PlacedItem] = []

    static let fileExtension = "stickersheet"

    init() {}

    /// Everything but `items` is optional on disk, matching `cricut-bt`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Sheet"
        copies = try c.decodeIfPresent(Int.self, forKey: .copies) ?? 1
        background = try c.decodeIfPresent(SheetBackgroundSpec.self, forKey: .background)
        items = try c.decode([PlacedItem].self, forKey: .items)
    }
}
