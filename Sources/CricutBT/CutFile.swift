import Foundation
import CoreGraphics
import ImageIO

/// Placement profile for the StickerPix Print+Cut.
///
/// Two independent coordinate systems are involved:
///
/// * the **design canvas** — 96 × 170 mm, what the artwork is authored in;
/// * the **print raster** — a 1200 × 2100 JPEG that the printer prints;
/// * the **cutter space** — the blade carriage's own units.
///
/// The profile below holds the empirically measured transforms between them.
/// They are measurements of one machine's registration, not universal
/// constants, so they are deliberately kept in one place and easy to swap.
struct SheetProfile {
    /// Design canvas in millimetres.
    var designWidthMM: Double = 96
    var designHeightMM: Double = 170

    /// Print raster size in pixels.
    var rasterWidth: Int = 1200
    var rasterHeight: Int = 2100

    /// design millimetres -> print raster pixels
    var rasterXFromMM: (scale: Double, offset: Double) = (11.695795937647613, 34.6017949929146)
    var rasterYFromMM: (scale: Double, offset: Double) = (11.674659518087138, 57.134652123004514)

    /// design millimetres -> cutter units
    ///
    /// These are the raw coefficients, as captured. The 180-degree correction
    /// for the cutter axes is applied by `reverseCutterAxes` below, exactly as
    /// the reference `stickerpix-v2` profile does — that profile applies *the
    /// original cutter transform* to (96-x, 170-y), which folds into
    /// X = -40.06691331923889 * y + 6961.794774992448 and
    /// Y = 40.14123760037788 * x + 92.97059518186143.
    ///
    /// Storing the corrected coefficients *and* flipping the axes here would
    /// cancel out and land on the old, uncorrected orientation.
    var cutterXFromMM: (scale: Double, offset: Double) = (40.06691331923889, 150.41951072183653)
    var cutterYFromMM: (scale: Double, offset: Double) = (-40.14123760037788, 3946.5294048181377)

    /// When true the design coordinates are flipped to (W-x, H-y) before the
    /// cutter transform is applied, reversing both axes about the canvas
    /// centre. This is the corrected orientation; leaving it off reproduces
    /// the 180-degree cut-layout error on asymmetric artwork.
    var reverseCutterAxes = true

    var pltHeader = "IN VER0.1.0 KP39"
    var pltTrailer = " U6476,0  @ "

    static let standard = SheetProfile()

    /// Map a design-space point (millimetres) into the cutter's units.
    func cutterPoint(xMM: Double, yMM: Double) -> (x: Int, y: Int) {
        var x = xMM, y = yMM
        if reverseCutterAxes {
            x = designWidthMM - x
            y = designHeightMM - y
        }
        let cx = cutterXFromMM.scale * y + cutterXFromMM.offset
        let cy = cutterYFromMM.scale * x + cutterYFromMM.offset
        return (Int(cx.rounded()), Int(cy.rounded()))
    }

    /// Map a design-space point (millimetres) into print-raster pixels.
    func rasterPoint(xMM: Double, yMM: Double) -> (x: Int, y: Int) {
        let px = rasterXFromMM.scale * xMM + rasterXFromMM.offset
        let py = rasterYFromMM.scale * yMM + rasterYFromMM.offset
        return (Int(px.rounded()), Int(py.rounded()))
    }

    /// Map a cutter coordinate back into the design canvas.
    ///
    /// This is the inverse of `cutterPoint`, so a cut file can be drawn back
    /// over the print sheet to check that the cuts and the artwork agree.
    func designPoint(cutterX: Double, cutterY: Double) -> (x: Double, y: Double) {
        let flippedY = (cutterX - cutterXFromMM.offset) / cutterXFromMM.scale
        let flippedX = (cutterY - cutterYFromMM.offset) / cutterYFromMM.scale
        if reverseCutterAxes {
            return (designWidthMM - flippedX, designHeightMM - flippedY)
        }
        return (flippedX, flippedY)
    }
}

/// A closed outline in design-space millimetres.
struct Contour {
    var points: [(x: Double, y: Double)] = []
}

/// Errors raised while turning artwork into a printable sheet.
enum CutFileError: Error, CustomStringConvertible {
    case unreadableImage(String)
    case noContours
    case badPlacement(String)

    var description: String {
        switch self {
        case .unreadableImage(let p): return "could not read image: \(p)"
        case .noContours: return "no printable contours found in the image"
        case .badPlacement(let m): return m
        }
    }
}

/// Builds the two files the printer needs for a print-and-cut sheet:
/// a print JPEG and a PLT cut file.
enum SheetBuilder {

    // MARK: Silhouette extraction

    /// Load an image and reduce it to a binary silhouette.
    ///
    /// Pixels with alpha above the threshold count as part of the sticker.
    static func silhouette(of path: String, alphaThreshold: UInt8 = 128) throws -> (width: Int, height: Int, mask: [Bool]) {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CutFileError.unreadableImage(path)
        }

        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CutFileError.unreadableImage(path)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // A CGBitmapContext stores its rows top-down: memory row 0 is the
        // image's top row, so the mask already comes out in reading order.
        //
        // Flipping it here would mirror every sticker vertically, and the
        // cut would come out upside down while still looking like a
        // plausible outline.
        var mask = [Bool](repeating: false, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4 + 3
                mask[y * width + x] = pixels[index] > alphaThreshold
            }
        }
        return (width, height, mask)
    }

    // MARK: Contour tracing

    /// Trace the boundary of every region in a binary mask.
    ///
    /// This is crack following: for each filled pixel, every side whose
    /// neighbour is empty becomes a directed edge along the pixel's border.
    /// The directed edges are then chained head-to-tail into closed loops.
    /// The result is an exact polygon of the region, and holes come out as
    /// separate loops.
    static func traceContours(width: Int, height: Int, mask: [Bool]) -> [Contour] {
        // Vertex coordinates live on the corner lattice: corner (x, y) is the
        // top-left corner of pixel (x, y).
        struct Edge {
            var from: (Int, Int)
            var to: (Int, Int)
        }

        var edges: [Edge] = []
        func filled(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            return mask[y * width + x]
        }

        for y in 0..<height {
            for x in 0..<width where filled(x, y) {
                if !filled(x, y - 1) { edges.append(Edge(from: (x, y), to: (x + 1, y))) }
                if !filled(x + 1, y) { edges.append(Edge(from: (x + 1, y), to: (x + 1, y + 1))) }
                if !filled(x, y + 1) { edges.append(Edge(from: (x + 1, y + 1), to: (x, y + 1))) }
                if !filled(x - 1, y) { edges.append(Edge(from: (x, y + 1), to: (x, y))) }
            }
        }

        // Chain the edges. Each vertex usually has exactly one outgoing edge;
        // a pinch point can have two, in which case the first one taken wins
        // and the other starts a separate loop.
        var outgoing: [Int: [Int]] = [:]
        for (index, edge) in edges.enumerated() {
            outgoing[edge.from.0 &* 100000 &+ edge.from.1, default: []].append(index)
        }
        var used = [Bool](repeating: false, count: edges.count)
        var contours: [Contour] = []

        for startIndex in edges.indices {
            guard !used[startIndex] else { continue }
            var loop: [(Int, Int)] = []
            var index = startIndex
            var guardCounter = 0

            while !used[index] && guardCounter < edges.count * 4 {
                used[index] = true
                let edge = edges[index]
                loop.append(edge.from)
                let key = edge.to.0 &* 100000 &+ edge.to.1
                guard let candidates = outgoing[key], let next = candidates.first(where: { !used[$0] }) else { break }
                index = next
                guardCounter += 1
                if edges[index].from == edges[startIndex].from { break }
            }

            if loop.count > 2 {
                contours.append(Contour(points: loop.map { (Double($0.0), Double($0.1)) }))
            }
        }

        return contours
    }

    // MARK: Placement

    /// Where the artwork sits on the design canvas, in millimetres.
    struct Placement {
        /// Top-left of the artwork on the canvas.
        var originXMM: Double
        var originYMM: Double
        /// Size of the artwork on the canvas.
        var widthMM: Double
        var heightMM: Double
    }

    /// Fit artwork into the design canvas with a margin, preserving aspect.
    static func fitPlacement(artworkWidth: Int,
                              artworkHeight: Int,
                              profile: SheetProfile,
                              marginMM: Double) throws -> Placement {
        guard artworkWidth > 0, artworkHeight > 0 else {
            throw CutFileError.badPlacement("artwork has no pixels")
        }
        let availableWidth = profile.designWidthMM - 2 * marginMM
        let availableHeight = profile.designHeightMM - 2 * marginMM
        guard availableWidth > 0, availableHeight > 0 else {
            throw CutFileError.badPlacement("margin \(marginMM)mm leaves no room on the canvas")
        }
        let scale = min(availableWidth / Double(artworkWidth),
                        availableHeight / Double(artworkHeight))
        let widthMM = Double(artworkWidth) * scale
        let heightMM = Double(artworkHeight) * scale
        return Placement(originXMM: marginMM + (availableWidth - widthMM) / 2,
                         originYMM: marginMM + (availableHeight - heightMM) / 2,
                         widthMM: widthMM,
                         heightMM: heightMM)
    }

    // MARK: PLT output

    /// Write contours as a PLT cut file.
    ///
    /// Each contour is an absolute travel (`U`) to its start point followed by
    /// a chain of cut moves (`D`) that returns to the start.
    static func writePLT(contours: [Contour], profile: SheetProfile = .standard, to path: String) throws {
        var text = profile.pltHeader + "\n"
        for contour in contours {
            guard let first = contour.points.first else { continue }
            let start = profile.cutterPoint(xMM: first.x, yMM: first.y)
            text += "U\(start.x),\(start.y)"
            for point in contour.points.dropFirst() {
                let p = profile.cutterPoint(xMM: point.x, yMM: point.y)
                text += " D\(p.x),\(p.y)"
            }
            text += " D\(start.x),\(start.y)\n"
        }
        text += profile.pltTrailer
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// One-shot: sticker PNG in, PLT cut file out.
    ///
    /// The sticker is placed on the design canvas the same way the print sheet
    /// places it, so the cut lines up with the printed image.
    static func buildCutFile(pngPath: String, pltPath: String, profile: SheetProfile = .standard) throws -> Int {
        try SheetRenderer.build(stickerPNGs: [pngPath],
                                jpegPath: NSTemporaryDirectory() + "cricut-bt-preview.jpg",
                                pltPath: pltPath,
                                profile: profile)
        return try SheetRenderer.describe(stickerPNG: pngPath, profile: profile)
            .components(separatedBy: "\n")
            .first(where: { $0.hasPrefix("contours:") })
            .flatMap { Int($0.dropFirst("contours: ".count)) } ?? 0
    }

    /// Report what the tracer found, for sanity-checking a build.
    static func describe(pngPath: String, profile: SheetProfile = .standard) throws -> String {
        try SheetRenderer.describe(stickerPNG: pngPath, profile: profile)
    }
}
