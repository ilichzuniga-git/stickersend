import Foundation
import Darwin
import CoreGraphics
import ImageIO

/// Write a PNG whose top half is opaque red and whose bottom half is clear.
///
/// Used to pin the row order of the alpha mask the cutter traces.
func writeHalfOpaquePNG(path: String, width: Int, height: Int) -> Bool {
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    // User space grows upwards, so the upper half of the rectangle is the
    // top half of the image.
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                           "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

/// Self-test: exercise the protocol end to end against the mock printer.
///
/// This proves the framing, the Diffie–Hellman handshake, the AES key
/// derivation, the encrypted JSON requests and the file upload — everything
/// except the Bluetooth radio itself.
/// Write a PNG holding an opaque square ring: a `size` square with a
/// transparent `hole` square in the middle.
func writeRingPNG(path: String, size: Int, hole: Int) -> Bool {
    guard let context = CGContext(data: nil, width: size, height: size,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: size, height: size))
    context.clear(CGRect(x: (size - hole) / 2, y: (size - hole) / 2, width: hole, height: hole))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                           "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

func runSelfTest() -> Int32 {
    var failures = 0

    func check(_ label: String, _ condition: Bool) {
        if condition {
            print("  ✓ \(label)")
        } else {
            print("  ✗ \(label)")
            failures += 1
        }
    }

    // --- modular arithmetic ---
    print("modular arithmetic")
    check("modexp matches Python for the printer's modulus",
          modexp(2, 12_345_678_901_234_567_890, 0xE6969D3D495BE32C) == 0x3E36EB079FA7F5F8)
    check("mulmod reduces a full-width product",
          mulmod(0xFFFF_FFFF_FFFF_FFFF, 0xFFFF_FFFF_FFFF_FFFF, 0xE6969D3D495BE32C) == 0x73BF71034F11AE51)
    check("hex formatting does not truncate a 64-bit value",
          hexString(0xE6969D3D495BE32C, width: 16) == "E6969D3D495BE32C")
    check("hex formatting pads short values",
          hexString(2, width: 4) == "0002")

    // --- framing ---
    print("\nframing")
    let frame = Frame.build(command: 0x10, body: Data("hello".utf8))
    var buffer = frame
    guard let parsed = Frame.parse(&buffer) else {
        print("  ✗ could not parse a frame we just built")
        return 1
    }
    check("round-trips the payload", parsed.body == Data("hello".utf8))
    check("keeps the command", parsed.command == 0x10)
    check("keeps the channel", parsed.channel == Frame.Channel.control)
    check("computes the payload length", parsed.payloadLength == 5)

    var split = Data(frame.prefix(17))
    check("waits for a complete frame", Frame.parse(&split) == nil)
    split.append(Data(frame.suffix(10)))
    check("reassembles a split frame", Frame.parse(&split) != nil)

    var corrupt = frame
    corrupt[corrupt.count - 3] ^= 0xFF
    var corruptBuffer = corrupt
    let corruptParsed = Frame.parse(&corruptBuffer)
    check("rejects a bad checksum", corruptParsed == nil || corruptParsed!.body != Data("hello".utf8))

    // --- handshake and requests ---
    print("\nhandshake and encrypted requests")
    let printer = MockPrinter()
    let session = PrinterSession(transport: printer)

    do {
        try session.handshake(timeout: 10)
        check("printer accepts the handshake", true)
    } catch {
        check("printer accepts the handshake — \(error)", false)
        return Int32(failures == 0 ? 1 : failures)
    }

    check("a session key was derived", session.sessionKey != nil)
    check("the key is 16 bytes", session.sessionKey?.count == 16)

    do {
        let state = try session.properties(["printer-state", "printer-sub-state"])
        check("reads printer state", (state as? [Any])?.first as? String == "20")
    } catch {
        check("reads printer state — \(error)", false)
    }

    do {
        let firmware = try session.properties(["firmware-revision"])
        check("reads the firmware version", (firmware as? [Any])?.first as? String == "1.0.31_0033")
    } catch {
        check("reads the firmware version — \(error)", false)
    }

    check("the request method was get-prop",
          printer.requests.first?.method == "get-prop")

    // --- upload framing ---
    print("\nupload framing")
    let sheet = PrintSheet(image: Data(repeating: 0x41, count: 3000),
                           cut: Data(repeating: 0x42, count: 500),
                           cutCount: 1,
                           name: "test")
    check("splits into 892-byte fragments", sheet.fragmentCount == 4)
    check("puts the cut file before the image", sheet.transferData.count == 3500)
    check("the cut file comes first", sheet.transferData.prefix(500) == Data(repeating: 0x42, count: 500))

    guard let key = session.sessionKey else { return 1 }
    let frames = sheet.uploadFrames(key: key, jobID: 30)
    check("produces one frame per fragment", frames.count == sheet.fragmentCount)

    var reassembled = Data()
    for f in frames {
        var parsedBuffer = f
        guard let parsed = Frame.parse(&parsedBuffer) else { continue }
        check("fragments use the file-transfer channel", parsed.channel == Frame.Channel.fileTransfer)
        var body = parsed.body
        if parsed.isEncrypted { body = AES.ecb(key, body, decrypt: true) }
        reassembled.append(body[4...])
    }
    // The last fragment carries zero padding to the AES block size; the
    // printer trims it using the file size declared in the job.
    let expected = sheet.transferData.count
    check("the uploaded bytes reassemble to the payload",
          reassembled.prefix(expected) == sheet.transferData)

    // --- job submission ---
    print("\njob submission")
    do {
        let info = try JobRunner.submit(session: session,
                                        sheet: sheet,
                                        copies: 2,
                                        maxWait: 10,
                                        progress: { _ in })
        let state = info["job-state"] as? Int
        check("the job reaches a terminal state", state == 9)
        check("the printer received a combo-job",
              printer.requests.contains { $0.method == "combo-job" })
        check("the printer received the file data",
              printer.uploadedTrimmed.count == sheet.transferData.count)
    } catch {
        check("the job completes — \(error)", false)
    }

    // --- geometry ---
    print("\ngeometry")
    let profile = SheetProfile.standard
    let corner = profile.cutterPoint(xMM: 0, yMM: 0)
    let opposite = profile.cutterPoint(xMM: profile.designWidthMM, yMM: profile.designHeightMM)
    check("the cutter transform is not degenerate", corner != opposite)
    check("the cutter X range is sane", opposite.x > corner.x || opposite.x < corner.x)
    check("the cutter Y range is sane", opposite.y > corner.y || opposite.y < corner.y)

    // --- orientation ---
    //
    // The cutter axes are reversed relative to the design axes, so a shape in
    // the top-left of the design has to land in a specific corner of the
    // cutter's travel. Getting this wrong is a 180-degree error that still
    // produces plausible-looking coordinates, so it is pinned by this test.
    print("\norientation")
    let triangle = [(x: 10.0, y: 6.0), (x: 17.0, y: 6.0), (x: 11.0, y: 14.0)]
    let mapped = triangle.map { profile.cutterPoint(xMM: $0.x, yMM: $0.y) }
    check("a top-left shape lands in the far cutter quadrant",
          mapped.allSatisfy { $0.x > 6000 && $0.y < 1000 })
    check("moving right in the design raises the cutter Y",
          mapped[1].y > mapped[0].y)
    check("moving down in the design lowers the cutter X",
          mapped[2].x < mapped[0].x)

    // The uncorrected orientation must be the corrected one turned through
    // 180 degrees about the centre of the canvas.
    var legacy = profile
    legacy.reverseCutterAxes = false
    let centre = profile.cutterPoint(xMM: profile.designWidthMM / 2, yMM: profile.designHeightMM / 2)
    var mirroredMatches = true
    for (index, point) in triangle.enumerated() {
        let legacyPoint = legacy.cutterPoint(xMM: point.x, yMM: point.y)
        let expectedX = 2 * centre.x - legacyPoint.x
        let expectedY = 2 * centre.y - legacyPoint.y
        if abs(mapped[index].x - expectedX) > 1 || abs(mapped[index].y - expectedY) > 1 {
            mirroredMatches = false
        }
    }
    check("the uncorrected orientation is the corrected one rotated 180 degrees", mirroredMatches)

    // --- silhouette orientation ---
    //
    // The alpha mask has to come out of the image in reading order. If the
    // rows are flipped while the mask is built, every sticker is cut out
    // upside down: the outline is still a plausible closed shape, so nothing
    // else in the pipeline complains.
    print("\nsilhouette orientation")
    let testPNG = NSTemporaryDirectory() + "cricut-bt-selftest-half.png"
    if writeHalfOpaquePNG(path: testPNG, width: 40, height: 80),
       let (maskWidth, maskHeight, mask) = try? SheetBuilder.silhouette(of: testPNG) {
        check("the mask keeps the image width", maskWidth == 40)
        check("the mask keeps the image height", maskHeight == 80)
        let topOpaque = mask[(10 * maskWidth) + 20]
        let bottomOpaque = mask[(70 * maskWidth) + 20]
        check("the top of the image is at the top of the mask", topOpaque)
        check("the bottom of the image is at the bottom of the mask", !bottomOpaque)

        let contours = SheetBuilder.traceContours(width: maskWidth, height: maskHeight, mask: mask)
        let minY = contours.flatMap { $0.points.map(\.1) }.min() ?? -1
        let maxY = contours.flatMap { $0.points.map(\.1) }.max() ?? -1
        check("the traced outline sits in the upper half of the image", minY >= 0 && maxY <= 41)
    } else {
        check("the silhouette could be measured", false)
    }

    // --- hand-arranged layouts ---
    //
    // A layout file must place stickers exactly where the automatic column
    // layout would for the same rectangles, so free arrangement cannot drift
    // the print away from the cut.
    print("\nlayout files")
    let layoutPNG = NSTemporaryDirectory() + "cricut-bt-selftest-layout.png"
    if writeHalfOpaquePNG(path: layoutPNG, width: 40, height: 80),
       let auto = try? SheetRenderer.layout(stickerPNGs: [layoutPNG, layoutPNG]) {
        let file = SheetLayoutFile(name: nil, copies: nil, background: nil, items: auto.map {
            .init(path: $0.png, x: $0.placement.designRect.minX, y: $0.placement.designRect.minY,
                  width: $0.placement.designRect.width, height: $0.placement.designRect.height, rotation: nil, outline: nil)
        })
        let manual = try? SheetRenderer.placements(for: file)
        check("a layout file reproduces the automatic raster placement",
              manual.map { zip($0, auto).allSatisfy { $0.1.placement.rasterRect == $0.0.placement.rasterRect } } ?? false)
        var outside = file
        outside.items[0].x = 90
        check("a sticker hanging off the sheet is rejected",
              (try? SheetRenderer.placements(for: outside)) == nil)
    } else {
        check("the layout test image could be written", false)
    }

    // --- rotation ---
    //
    // A rotated sticker is drawn into the JPEG and traced into the PLT by two
    // different pieces of code. If they disagree about the direction or the
    // pivot, the cut misses the print, so pin both against one asymmetric
    // shape: the top half is opaque, and a 90° clockwise turn must put it on
    // the right.
    print("\nrotation")
    let rotPNG = NSTemporaryDirectory() + "cricut-bt-selftest-rot.png"
    let rotJPG = NSTemporaryDirectory() + "cricut-bt-selftest-rot.jpg"
    let rotPLT = NSTemporaryDirectory() + "cricut-bt-selftest-rot.plt"
    if writeHalfOpaquePNG(path: rotPNG, width: 40, height: 80) {
        // Frame 20 × 40 mm centred on (40, 60); turned 90° it spans x 20…60, y 50…70.
        let layout = SheetLayoutFile(name: nil, copies: nil, background: nil, items: [
            .init(path: rotPNG, x: 30, y: 40, width: 20, height: 40, rotation: 90, outline: nil)])
        do {
            let placed = try SheetRenderer.placements(for: layout)
            try SheetRenderer.renderJPEG(placements: placed, to: rotJPG)
            _ = try SheetRenderer.writeCutFile(for: placed, to: rotPLT)
            let cut = try SheetRenderer.readContours(pltPath: rotPLT).flatMap(\.points)
            let xs = cut.map(\.x), ys = cut.map(\.y)
            check("the rotated cut sits on the right half (x 40…60 mm)",
                  (xs.min() ?? 0) > 39.4 && (xs.max() ?? 0) < 60.6)
            check("the rotated cut keeps the turned height (y 50…70 mm)",
                  (ys.min() ?? 0) > 49.4 && (ys.max() ?? 0) < 70.6)

            // Read the print back, rows top-down, and look either side of the pivot.
            if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: rotJPG) as CFURL, nil),
               let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                let w = img.width, h = img.height
                var px = [UInt8](repeating: 0, count: w * h * 4)
                let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                func isRed(_ xMM: Double, _ yMM: Double) -> Bool {
                    let p = SheetProfile.standard.rasterPoint(xMM: xMM, yMM: yMM)
                    let i = (p.y * w + p.x) * 4
                    return px[i] > 200 && px[i + 1] < 80 && px[i + 2] < 80
                }
                check("the print is red right of the pivot", isRed(50, 60))
                check("the print is blank left of the pivot", !isRed(30, 60))
            } else {
                check("the rotated print could be read back", false)
            }

            var tooBig = layout
            tooBig.items[0].x = 70   // turned, the opaque half spans x 80…100: off the sheet
            check("a rotated sticker hanging off the sheet is rejected",
                  (try? SheetRenderer.placements(for: tooBig)) == nil)

            // Only the opaque part counts: turned 90°, the clear bottom half
            // of the frame lands on the left, so the frame may hang off the
            // left edge as long as the opaque half stays on the sheet.
            var clearOverEdge = layout
            clearOverEdge.items[0].x = -8   // frame turned spans x -18…22; opaque half x 2…22
            check("transparent corners may hang off the sheet",
                  (try? SheetRenderer.placements(for: clearOverEdge)) != nil)
        } catch {
            check("a rotated sheet builds — \(error)", false)
        }
    } else {
        check("the rotation test image could be written", false)
    }

    // --- outlines ---
    //
    // An outline is grown into a generated PNG that both the print and the
    // cut are made from. Pin its geometry: a 2 mm outline must push the cut
    // out by 2 mm, leave the artwork where it was, and fill holes on request.
    print("\noutlines")
    let outlinePNG = NSTemporaryDirectory() + "cricut-bt-selftest-outline.png"
    let ringPNG = NSTemporaryDirectory() + "cricut-bt-selftest-ring.png"
    let outlinePLT = NSTemporaryDirectory() + "cricut-bt-selftest-outline.plt"
    if writeHalfOpaquePNG(path: outlinePNG, width: 40, height: 80),
       writeRingPNG(path: ringPNG, size: 60, hole: 30) {
        do {
            // 20 × 40 mm frame at (30, 40): the opaque top half covers x 30…50, y 40…60.
            let outlined = SheetLayoutFile(name: nil, copies: nil, background: nil, items: [
                .init(path: outlinePNG, x: 30, y: 40, width: 20, height: 40, rotation: nil,
                      outline: OutlineSpec(widthMM: 2, color: "#ffffff", fillGaps: true))])
            let placed = try SheetRenderer.placements(for: outlined)
            _ = try SheetRenderer.writeCutFile(for: placed, to: outlinePLT)
            let pts = try SheetRenderer.readContours(pltPath: outlinePLT).flatMap(\.points)
            let xs = pts.map(\.x), ys = pts.map(\.y)
            check("a 2 mm outline pushes the cut out 2 mm (x 28…52)",
                  abs((xs.min() ?? 0) - 28) < 0.6 && abs((xs.max() ?? 0) - 52) < 0.6)
            check("a 2 mm outline pushes the cut out 2 mm (y 38…62)",
                  abs((ys.min() ?? 0) - 38) < 0.6 && abs((ys.max() ?? 0) - 62) < 0.6)
            let frame = placed[0].placement.designRect
            check("the outline grows the frame about the same centre",
                  abs(frame.midX - 40) < 0.01 && abs(frame.midY - 60) < 0.01)

            // A ring is two cut loops; filling gaps makes it one.
            func loops(fill: Bool, width: Double) throws -> Int {
                let ring = SheetLayoutFile(name: nil, copies: nil, background: nil, items: [
                    .init(path: ringPNG, x: 20, y: 20, width: 30, height: 30, rotation: nil,
                          outline: OutlineSpec(widthMM: width, color: "#ff0000", fillGaps: fill))])
                return try SheetRenderer.writeCutFile(for: try SheetRenderer.placements(for: ring), to: outlinePLT)
            }
            check("a ring with a thin outline still has its hole", try loops(fill: false, width: 0.5) == 2)
            check("filling gaps turns the ring into one cut", try loops(fill: true, width: 0.5) == 1)
            check("filling gaps works with no extra width", try loops(fill: true, width: 0) == 1)

            // Decorative styles: the outer edge must reach the chosen width and
            // no further (collision checks rely on it). Scallops and teeth
            // still cut as one shape; lace adds its eyelets as extra loops.
            func styled(_ style: OutlineStyle) throws -> (loops: Int, minX: Double, maxX: Double) {
                let file = SheetLayoutFile(name: nil, copies: nil, background: nil, items: [
                    .init(path: ringPNG, x: 30, y: 30, width: 30, height: 30, rotation: nil,
                          outline: OutlineSpec(widthMM: 5, color: "#ffffff", fillGaps: true, style: style))])
                let n = try SheetRenderer.writeCutFile(for: try SheetRenderer.placements(for: file), to: outlinePLT)
                let xs = try SheetRenderer.readContours(pltPath: outlinePLT).flatMap(\.points).map(\.x)
                return (n, xs.min() ?? 0, xs.max() ?? 0)
            }
            for style in [OutlineStyle.scalloped, .pinked, .stitched, .lace] {
                let r = try styled(style)
                // The ring spans x 30…60 mm, so a 5 mm border reaches 25…65.
                check("\(style.label) border reaches 5 mm out and no further",
                      r.minX > 24.4 && r.minX < 26 && r.maxX < 65.6 && r.maxX > 64)
                if style == .lace {
                    check("Lace cuts its eyelets (\(r.loops - 1) holes)", r.loops > 10)
                } else {
                    check("\(style.label) border cuts as one shape", r.loops == 1)
                }
            }
        } catch {
            check("an outlined sheet builds — \(error)", false)
        }
    } else {
        check("the outline test images could be written", false)
    }

    print("")
    if failures == 0 {
        print("all checks passed")
    } else {
        print("\(failures) check(s) failed")
    }
    return failures == 0 ? 0 : 1
}
