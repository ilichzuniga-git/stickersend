import Foundation
import CoreGraphics
import ImageIO

/// A hand-arranged sheet: every sticker at an explicit position and size on
/// the 96 × 170 mm design canvas. This is the `.stickersheet` file StickerSend
/// saves, and what `cricut-bt sheet-layout` reads.
///
/// ```json
/// { "name": "Cats", "copies": 1,
///   "items": [ { "path": "/abs/Tabby Sticker.png", "x": 4, "y": 6, "width": 40, "height": 52 } ] }
/// ```
struct SheetLayoutFile: Codable {
    struct Item: Codable {
        var path: String
        /// Top-left corner and size, in design millimetres.
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        /// Clockwise degrees about the centre of the frame above. Optional so
        /// sheets saved before rotation existed still load.
        var rotation: Double?
        /// Extra outline grown around the sticker, printed and cut.
        var outline: OutlineSpec?
    }

    var name: String?
    var copies: Int?
    /// Printed behind everything, never cut.
    var background: SheetBackground?
    var items: [Item]

    static func load(_ path: String) throws -> SheetLayoutFile {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(SheetLayoutFile.self, from: data)
    }
}

/// A sheet background: a solid colour, an image, or both (colour underneath).
struct SheetBackground: Codable {
    /// `#rrggbb`.
    var color: String?
    /// Image file, scaled to fill the whole print raster (cropping the overflow).
    var path: String?

    func draw(in context: CGContext, width: Int, height: Int) throws {
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        if let color, let rgb = Self.parse(color) {
            context.setFillColor(CGColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
            context.fill(full)
        }
        if let path {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CutFileError.unreadableImage(path)
            }
            // Aspect fill, centred.
            let scale = max(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
        }
    }

    static func parse(_ hex: String) -> (CGFloat, CGFloat, CGFloat)? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
    }
}

extension SheetRenderer {

    /// Turn a layout file into placements. Only the layout step differs from
    /// `layout(stickerPNGs:)`: the millimetre → raster mapping, the JPEG
    /// render and the cut tracing are the same code.
    static func placements(for layout: SheetLayoutFile,
                           profile: SheetProfile = .standard) throws -> [(png: String, placement: PlacedSticker)] {
        guard !layout.items.isEmpty else { throw CutFileError.badPlacement("the layout has no stickers") }
        let tolerance = 0.01
        return try layout.items.map { original in
            guard original.width > 0, original.height > 0 else {
                throw CutFileError.badPlacement("\(original.path): size must be positive")
            }
            guard FileManager.default.isReadableFile(atPath: original.path) else {
                throw CutFileError.unreadableImage(original.path)
            }
            // An outline swaps in a generated PNG and grows the frame about its
            // centre, so the artwork keeps its size and place. Print and cut
            // both come from that one PNG, so they cannot disagree.
            let item = try applyOutline(to: original)
            let topLeft = profile.rasterPoint(xMM: item.x, yMM: item.y)
            let bottomRight = profile.rasterPoint(xMM: item.x + item.width, yMM: item.y + item.height)
            let placed = PlacedSticker(
                rasterRect: CGRect(x: topLeft.x, y: topLeft.y,
                                   width: bottomRight.x - topLeft.x,
                                   height: bottomRight.y - topLeft.y),
                designRect: CGRect(x: item.x, y: item.y, width: item.width, height: item.height),
                rotationDegrees: item.rotation ?? 0)
            // What gets printed and cut has to stay on the sheet. That is the
            // sticker's opaque shape (outline included), not its rectangle:
            // the transparent corners of a rotated frame may hang off the page,
            // since nothing there is printed or cut.
            let bounds = try contentBounds(png: item.path, placement: placed) ?? placed.rotatedDesignBounds
            guard bounds.minX >= -tolerance, bounds.minY >= -tolerance,
                  bounds.maxX <= profile.designWidthMM + tolerance,
                  bounds.maxY <= profile.designHeightMM + tolerance else {
                throw CutFileError.badPlacement("\(item.path): placed outside the \(Int(profile.designWidthMM))×\(Int(profile.designHeightMM)) mm sheet")
            }
            return (item.path, placed)
        }
    }
}

/// Bounds, in design mm, of the opaque part of a placed sticker (what the
/// cutter traces), after rotation. Nil if the image has no opaque pixels.
func contentBounds(png: String, placement: SheetRenderer.PlacedSticker) throws -> CGRect? {
    let (w, h, mask) = try SheetBuilder.silhouette(of: png)
    let d = placement.designRect
    let sx = d.width / Double(w), sy = d.height / Double(h)
    var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
    func solid(_ x: Int, _ y: Int) -> Bool { x >= 0 && x < w && y >= 0 && y < h && mask[y * w + x] }
    for y in 0..<h {
        for x in 0..<w where mask[y * w + x] {
            // Only edge pixels can be extreme.
            guard !solid(x - 1, y) || !solid(x + 1, y) || !solid(x, y - 1) || !solid(x, y + 1) else { continue }
            for (cx, cy) in [(x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)] {
                let p = placement.rotated(d.minX + Double(cx) * sx, d.minY + Double(cy) * sy)
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
    }
    guard minX.isFinite else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

/// Render a layout item's outline into a temporary PNG and return the item
/// pointing at it, with its frame grown to match. Items without an outline
/// come back unchanged.
func applyOutline(to item: SheetLayoutFile.Item) throws -> SheetLayoutFile.Item {
    guard let spec = item.outline, spec.isActive else { return item }
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw CutFileError.unreadableImage(item.path)
    }
    let mmPerPixel = item.width / Double(image.width)
    guard let (outlined, pad) = OutlineRenderer.render(image, radius: spec.widthMM / mmPerPixel,
                                                       rgb: OutlineRenderer.parse(spec.color),
                                                       fillGaps: spec.fillGaps,
                                                       style: spec.kind) else {
        throw CutFileError.badPlacement("\(item.path): could not draw the outline")
    }

    let dir = NSTemporaryDirectory() + "cricut-bt-outlines/"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + UUID().uuidString + ".png"
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                           "public.png" as CFString, 1, nil) else {
        throw CutFileError.badPlacement("could not write \(path)")
    }
    CGImageDestinationAddImage(destination, outlined, nil)
    guard CGImageDestinationFinalize(destination) else { throw CutFileError.badPlacement("could not write \(path)") }

    var grown = item
    grown.path = path
    grown.outline = nil
    // Grow each axis by the padding at that axis's own scale.
    let growX = Double(pad) * mmPerPixel
    let growY = Double(pad) * item.height / Double(image.height)
    grown.x -= growX
    grown.y -= growY
    grown.width += 2 * growX
    grown.height += 2 * growY
    return grown
}

/// `cricut-bt sheet-layout <layout.stickersheet> <out.jpg> <out.plt>`
func sheetFromLayout(_ options: Options) {
    guard options.inputs.count == 3 else {
        print("usage: cricut-bt sheet-layout <layout.stickersheet> <out.jpg> <out.plt>")
        exit(2)
    }
    var profile = SheetProfile.standard
    if let reversed = options.reverseCutterAxes { profile.reverseCutterAxes = reversed }
    do {
        let layout = try SheetLayoutFile.load(options.inputs[0])
        let placements = try SheetRenderer.placements(for: layout, profile: profile)
        try SheetRenderer.renderJPEG(placements: placements, profile: profile, to: options.inputs[1],
                                     background: layout.background)
        let count = try SheetRenderer.writeCutFile(for: placements, profile: profile, to: options.inputs[2])
        print("wrote \(options.inputs[1]) and \(options.inputs[2]) with \(count) contour(s)")
    } catch {
        print("error: \(error)")
        exit(1)
    }
}
