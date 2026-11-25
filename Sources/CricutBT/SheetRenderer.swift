import Foundation
import CoreGraphics
import ImageIO

/// Builds the print sheet: a 1200 × 2100 JPEG holding the sticker artwork,
/// plus the matching PLT cut file in cutter coordinates.
///
/// The printer prints the JPEG and then runs the blade along the PLT
/// contours. Both are derived from the same design-space rectangle, so the
/// cut stays registered to the printed image.
enum SheetRenderer {

    /// A sticker placed on the sheet.
    struct PlacedSticker {
        /// Position and size on the print raster, in pixels.
        var rasterRect: CGRect
        /// The same rectangle in design millimetres.
        var designRect: CGRect
        /// Clockwise rotation about the rectangle's centre, in degrees.
        /// The rectangles above are the sticker's unrotated frame.
        var rotationDegrees: Double = 0

        /// Map a design-space point inside the unrotated frame to where it
        /// lands once the sticker is rotated. Design space is y-down, so a
        /// positive angle turns clockwise on the page.
        func rotated(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
            guard rotationDegrees != 0 else { return (x, y) }
            let a = rotationDegrees * .pi / 180
            let cx = designRect.midX, cy = designRect.midY
            let dx = x - cx, dy = y - cy
            return (cx + dx * cos(a) - dy * sin(a), cy + dx * sin(a) + dy * cos(a))
        }

        /// Axis-aligned bounds of the rotated frame, in design millimetres.
        var rotatedDesignBounds: CGRect {
            let r = designRect
            let corners = [(r.minX, r.minY), (r.maxX, r.minY), (r.maxX, r.maxY), (r.minX, r.maxY)].map { rotated($0.0, $0.1) }
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
    }

    /// Fit one or more stickers onto the sheet.
    ///
    /// Artwork is scaled to fit the sheet minus a margin and centred, keeping
    /// its aspect ratio. Additional stickers are laid out in a column.
    static func layout(stickerPNGs: [String],
                       profile: SheetProfile = .standard,
                       marginMM: Double = 2,
                       gapMM: Double = 2) throws -> [(png: String, placement: PlacedSticker)] {
        guard !stickerPNGs.isEmpty else { throw CutFileError.badPlacement("no stickers given") }

        let availableWidthMM = profile.designWidthMM - 2 * marginMM
        let availableHeightMM = profile.designHeightMM - 2 * marginMM
        let columnHeightMM = (availableHeightMM - gapMM * Double(stickerPNGs.count - 1)) / Double(stickerPNGs.count)
        guard columnHeightMM > 0 else {
            throw CutFileError.badPlacement("\(stickerPNGs.count) stickers do not fit on the sheet")
        }

        var results: [(png: String, placement: PlacedSticker)] = []
        for (index, png) in stickerPNGs.enumerated() {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CutFileError.unreadableImage(png)
            }
            let aspect = Double(image.width) / Double(image.height)
            var widthMM = columnHeightMM * aspect
            var heightMM = columnHeightMM
            if widthMM > availableWidthMM {
                widthMM = availableWidthMM
                heightMM = availableWidthMM / aspect
            }

            let originXMM = marginMM + (availableWidthMM - widthMM) / 2
            let originYMM = marginMM + Double(index) * (columnHeightMM + gapMM) + (columnHeightMM - heightMM) / 2

            // Design millimetres -> print raster pixels.
            let topLeft = profile.rasterPoint(xMM: originXMM, yMM: originYMM)
            let bottomRight = profile.rasterPoint(xMM: originXMM + widthMM, yMM: originYMM + heightMM)

            results.append((png, PlacedSticker(
                rasterRect: CGRect(x: topLeft.x, y: topLeft.y,
                                   width: bottomRight.x - topLeft.x,
                                   height: bottomRight.y - topLeft.y),
                designRect: CGRect(x: originXMM, y: originYMM, width: widthMM, height: heightMM)
            )))
        }
        return results
    }

    /// Render the placed stickers into a JPEG print sheet.
    static func renderJPEG(placements: [(png: String, placement: PlacedSticker)],
                            profile: SheetProfile = .standard,
                            to path: String,
                            quality: CGFloat = 0.92,
                            background: SheetBackground? = nil) throws {
        let width = profile.rasterWidth
        let height = profile.rasterHeight

        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CutFileError.badPlacement("could not create the sheet bitmap")
        }

        // White paper.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Optional background, printed edge to edge behind the stickers. It is
        // never traced, so it is printed but not cut.
        if let background {
            try background.draw(in: context, width: width, height: height)
        }

        for item in placements {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: item.png) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw CutFileError.unreadableImage(item.png)
            }
            if item.placement.rotationDegrees != 0 {
                // Draw in design millimetres through the same affine map the
                // profile uses (mm -> raster, then the bitmap's y-up rows), so
                // the rotation is about exactly the point the cut rotates about.
                let d = item.placement.designRect
                context.saveGState()
                context.translateBy(x: CGFloat(profile.rasterXFromMM.offset),
                                    y: CGFloat(height - 1) - CGFloat(profile.rasterYFromMM.offset))
                context.scaleBy(x: CGFloat(profile.rasterXFromMM.scale), y: -CGFloat(profile.rasterYFromMM.scale))
                // Now in y-down millimetres: rotate clockwise about the centre.
                context.translateBy(x: d.midX, y: d.midY)
                context.rotate(by: CGFloat(item.placement.rotationDegrees * .pi / 180))
                // Images draw upright in a y-up space, so flip back locally.
                context.scaleBy(x: 1, y: -1)
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: -d.width / 2, y: -d.height / 2, width: d.width, height: d.height))
                context.restoreGState()
                continue
            }
            var rect = item.placement.rasterRect
            // The bitmap context keeps memory row 0 at the top of the image,
            // so the artwork's top edge has to sit at the raster row the
            // placement asked for.
            rect.origin.y = CGFloat(height - 1) - rect.origin.y - rect.height
            context.interpolationQuality = .high
            context.draw(image, in: rect)
        }

        guard let image = context.makeImage() else {
            throw CutFileError.badPlacement("could not finalise the sheet image")
        }
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw CutFileError.badPlacement("could not create \(path)")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CutFileError.badPlacement("could not write \(path)")
        }
    }

    /// Trace a sticker's outline and write the matching PLT cut file.
    static func writeCutFile(for placements: [(png: String, placement: PlacedSticker)],
                             profile: SheetProfile = .standard,
                             to path: String) throws -> Int {
        var contours: [Contour] = []
        for item in placements {
            let (width, height, mask) = try SheetBuilder.silhouette(of: item.png)
            let pixelContours = SheetBuilder.traceContours(width: width, height: height, mask: mask)
            let design = item.placement.designRect
            guard design.width > 0, design.height > 0 else { continue }

            // The traced points are in the SOURCE image's pixels; the design
            // rectangle is in millimetres, so scale by the source resolution.
            let mmPerSourcePixelX = design.width / Double(width)
            let mmPerSourcePixelY = design.height / Double(height)

            for contour in pixelContours {
                contours.append(Contour(points: contour.points.map { point in
                    // Rotation is the identity at 0°, so unrotated stickers
                    // map exactly as before.
                    item.placement.rotated(design.minX + Double(point.x) * mmPerSourcePixelX,
                                           design.minY + Double(point.y) * mmPerSourcePixelY)
                }))
            }
        }
        guard !contours.isEmpty else { throw CutFileError.noContours }
        try SheetBuilder.writePLT(contours: contours, profile: profile, to: path)
        return contours.count
    }

    /// Build both files for a set of stickers.
    @discardableResult
    static func build(stickerPNGs: [String],
                      jpegPath: String,
                      pltPath: String,
                      profile: SheetProfile = .standard,
                      marginMM: Double = 2) throws -> Int {
        let placements = try layout(stickerPNGs: stickerPNGs, profile: profile, marginMM: marginMM)
        try renderJPEG(placements: placements, profile: profile, to: jpegPath)
        let count = try writeCutFile(for: placements, profile: profile, to: pltPath)
        return count
    }

    /// Draw the cut file back over the print sheet as a preview.
    ///
    /// The cut contours are mapped from cutter units back into the print
    /// raster and stroked in magenta, so the cuts can be checked against the
    /// artwork before a sheet is fed through the printer.
    static func renderPreview(sheetJPEG: String,
                               pltPath: String,
                               pngPath: String,
                               profile: SheetProfile = .standard) throws -> Int {
        let contours = try readContours(pltPath: pltPath, profile: profile)

        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sheetJPEG) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CutFileError.unreadableImage(sheetJPEG)
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
            throw CutFileError.unreadableImage(sheetJPEG)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // The raster's row 0 is the top of the image, and the bitmap context
        // is top-down, so a raster row r is drawn at user-space y = h-1-r.
        context.setStrokeColor(CGColor(red: 1.0, green: 0.0, blue: 0.55, alpha: 1.0))
        context.setLineWidth(3)
        context.setLineJoin(.round)

        for contour in contours {
            guard let first = contour.points.first else { continue }
            let start = profile.rasterPoint(xMM: first.x, yMM: first.y)
            context.move(to: CGPoint(x: CGFloat(start.x), y: CGFloat(height - 1 - start.y)))
            for point in contour.points.dropFirst() {
                let p = profile.rasterPoint(xMM: point.x, yMM: point.y)
                context.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(height - 1 - p.y)))
            }
            context.strokePath()
        }

        guard let output = context.makeImage() else {
            throw CutFileError.badPlacement("could not rasterise the preview")
        }
        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: pngPath) as CFURL,
                                                                "public.png" as CFString,
                                                                1,
                                                                nil) else {
            throw CutFileError.badPlacement("could not write \(pngPath)")
        }
        CGImageDestinationAddImage(destination, output, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CutFileError.badPlacement("could not write \(pngPath)")
        }
        return contours.count
    }

    /// Read the cut file back and convert every outline into design space.
    static func readContours(pltPath: String, profile: SheetProfile = .standard) throws -> [Contour] {
        let text = try String(contentsOfFile: pltPath, encoding: .ascii)
        var contours: [Contour] = []
        var current: [(x: Double, y: Double)] = []

        // Each outline starts with an absolute travel (U) and continues with
        // cutting moves (D).
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" }) {
            guard let kind = token.first, kind == "U" || kind == "D" else { continue }
            let body = token.dropFirst()
            let parts = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let x = Double(parts[0]),
                  let y = Double(parts[1]) else { continue }
            let design = profile.designPoint(cutterX: x, cutterY: y)
            if kind == "U" {
                if current.count > 2 { contours.append(Contour(points: current)) }
                current = []
            }
            current.append((design.x, design.y))
        }
        if current.count > 2 { contours.append(Contour(points: current)) }
        return contours
    }

    /// Report what the tracer found for one sticker, for sanity-checking.
    static func describe(stickerPNG: String,
                          profile: SheetProfile = .standard,
                          marginMM: Double = 2) throws -> String {
        let placements = try layout(stickerPNGs: [stickerPNG], profile: profile, marginMM: marginMM)
        guard let item = placements.first else { return "no placement" }
        let (width, height, mask) = try SheetBuilder.silhouette(of: stickerPNG)
        let contours = SheetBuilder.traceContours(width: width, height: height, mask: mask)

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where mask[y * width + x] {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }

        let design = item.placement.designRect
        var lines: [String] = []
        lines.append("image: \(width)x\(height) px")
        if maxX >= 0 {
            lines.append("opaque bbox: x \(minX)...\(maxX), y \(minY)...\(maxY)")
        }
        lines.append("design rect: x \(String(format: "%.1f", design.minX))...\(String(format: "%.1f", design.maxX)) mm, "
                     + "y \(String(format: "%.1f", design.minY))...\(String(format: "%.1f", design.maxY)) mm")
        lines.append("contours: \(contours.count)")
        for (index, contour) in contours.enumerated() {
            let xs = contour.points.map(\.x)
            let ys = contour.points.map(\.y)
            let designX = design.minX + (xs.min() ?? 0) * (design.width / Double(width))
            let designXMax = design.minX + (xs.max() ?? 0) * (design.width / Double(width))
            let designY = design.minY + (ys.min() ?? 0) * (design.height / Double(height))
            let designYMax = design.minY + (ys.max() ?? 0) * (design.height / Double(height))
            let a = profile.cutterPoint(xMM: designX, yMM: designY)
            let b = profile.cutterPoint(xMM: designXMax, yMM: designYMax)
            lines.append("  [\(index)] \(contour.points.count) points, "
                         + "design x \(String(format: "%.1f", designX))...\(String(format: "%.1f", designXMax)) mm "
                         + "y \(String(format: "%.1f", designY))...\(String(format: "%.1f", designYMax)) mm "
                         + "-> cutter x \(min(a.x, b.x))...\(max(a.x, b.x)), y \(min(a.y, b.y))...\(max(a.y, b.y))")
        }
        return lines.joined(separator: "\n")
    }
}
