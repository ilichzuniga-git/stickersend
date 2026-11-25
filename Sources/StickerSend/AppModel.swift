import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One sticker PNG in the library folder.
struct Sticker: Identifiable, Hashable {
    let url: URL
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }

    static func == (a: Sticker, b: Sticker) -> Bool { a.url == b.url }
    func hash(into h: inout Hasher) { h.combine(url) }
}

struct LogLine: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let isError: Bool
}

enum SheetMode: String, CaseIterable, Identifiable {
    case arrange = "Arrange"
    case preview = "Cut Preview"
    var id: String { rawValue }
}

enum InspectorTab: String, CaseIterable, Identifiable {
    case selected = "Selected"
    case sheet = "Sheet"
    case check = "Check"
    var id: String { rawValue }
}

@MainActor
final class AppModel: ObservableObject {

    // MARK: Settings

    static let defaultLibraryPath =
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/StickerSend/Stickers")
    static let defaultSheetsPath =
        (NSHomeDirectory() as NSString).appendingPathComponent("Documents/StickerSend/Sheets")

    @AppStorage("hasCompletedSetup") var hasCompletedSetup = false
    @AppStorage("libraryPath") var libraryPath = AppModel.defaultLibraryPath
    @AppStorage("sheetsPath") private var sheetsPath = AppModel.defaultSheetsPath
    @AppStorage("printerAddress") var printerAddress = ""
    @AppStorage("cliPath") var cliPath = ""

    /// Shown on first launch until the user picks or confirms their sticker folder.
    @Published var showWelcomeSetup = false

    // MARK: Library

    @Published var stickers: [Sticker] = []
    @Published var reports: [URL: StickerReport] = [:]
    @Published var thumbnails: [URL: NSImage] = [:]
    /// Larger renders for the sheet canvas.
    @Published var canvasImages: [URL: NSImage] = [:]
    @Published var selection: Sticker.ID?

    // MARK: Sheet document

    @Published var doc = SheetDocument() {
        didSet {
            if doc != oldValue { invalidateSheet() }
            if doc.items != oldValue.items { recomputeOverlaps() }
        }
    }
    @Published private(set) var docURL: URL?
    @Published private var savedDoc = SheetDocument()
    @Published var savedSheets: [URL] = []
    @Published var selectedItem: PlacedItem.ID? {
        didSet {
            if let id = selectedItem, let item = doc.items.first(where: { $0.id == id }) {
                if stickers.contains(where: { $0.url == item.url }) {
                    selection = item.url
                }
                inspectorTab = .selected
            } else if selectedItem == nil && inspectorTab == .selected {
                inspectorTab = .sheet
            }
        }
    }
    @Published var mode: SheetMode = .arrange
    @Published var inspectorTab: InspectorTab = .sheet
    @Published var showLog = false
    @Published var backgroundImage: NSImage?

    // General undo / redo history for sheet edits.
    @Published private(set) var undoStack: [SheetDocument] = []
    @Published private(set) var redoStack: [SheetDocument] = []
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func recordUndo(_ snapshot: SheetDocument? = nil) {
        let state = snapshot ?? doc
        if undoStack.last == state { return }
        undoStack.append(state)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(doc)
        doc = prev
        if let sel = selectedItem, !doc.items.contains(where: { $0.id == sel }) {
            selectedItem = nil
        }
        loadBackgroundImage()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(doc)
        doc = next
        if let sel = selectedItem, !doc.items.contains(where: { $0.id == sel }) {
            selectedItem = nil
        }
        loadBackgroundImage()
    }

    /// Select a sticker in the library and open its dark-blue Check view.
    func inspectLibrarySticker(_ sticker: Sticker) {
        selection = sticker.id
        inspectorTab = .check
    }

    /// Switch Arrange / Cut Preview; auto-builds cut preview when entering Preview with no fresh build.
    func setMode(_ newMode: SheetMode) {
        mode = newMode
        if newMode == .preview, previewImage == nil, !doc.items.isEmpty, !busy {
            buildSheet()
        }
    }

    var isDirty: Bool { doc != savedDoc }
    var sheetsDir: URL { URL(fileURLWithPath: sheetsPath) }

    // MARK: Build / job

    @Published var previewImage: NSImage?
    @Published var sheetContours: Int?
    @Published var isBuilding = false
    @Published var isPrinting = false
    @Published var isQuerying = false
    @Published var uploadProgress: Double?
    @Published var jobStage: String?
    @Published var printerSummary: [String] = []
    @Published var log: [LogLine] = []

    private let runner = CLIRunner()

    var libraryURL: URL { URL(fileURLWithPath: libraryPath) }
    var busy: Bool { isBuilding || isPrinting || isQuerying }

    /// Where built sheets go.
    let workDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StickerSend", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    var sheetLayout: URL { workDir.appendingPathComponent("sheet.stickersheet") }
    var sheetJPEG: URL { workDir.appendingPathComponent("sheet.jpg") }
    var sheetPLT: URL { workDir.appendingPathComponent("sheet.plt") }
    var sheetPreview: URL { workDir.appendingPathComponent("sheet-preview.png") }

    var binary: URL? {
        if !cliPath.isEmpty, FileManager.default.isExecutableFile(atPath: cliPath) {
            return URL(fileURLWithPath: cliPath)
        }
        return CLIRunner.defaultBinary()
    }

    init() {
        let legacyPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Documents/stickers/Finalized Stickers")
        if !hasCompletedSetup {
            if UserDefaults.standard.string(forKey: "libraryPath") != nil {
                hasCompletedSetup = true
            } else {
                // Pre-suggest legacy folder if it already exists on this Mac,
                // while still letting the user confirm or pick a folder on first run.
                if FileManager.default.fileExists(atPath: legacyPath) {
                    libraryPath = legacyPath
                    let legacySheets = (NSHomeDirectory() as NSString)
                        .appendingPathComponent("Documents/stickers/Sheets")
                    if FileManager.default.fileExists(atPath: legacySheets) {
                        sheetsPath = legacySheets
                    }
                }
                showWelcomeSetup = true
            }
        }
        reload()
        refreshSavedSheets()
    }

    // MARK: Library actions

    /// Complete initial setup using the current (or newly chosen) sticker folder.
    func completeSetup(useDefault: Bool = false) {
        if useDefault {
            try? FileManager.default.createDirectory(at: libraryURL, withIntermediateDirectories: true)
            hasCompletedSetup = true
            showWelcomeSetup = false
            reload()
        } else if chooseFolder() {
            hasCompletedSetup = true
            showWelcomeSetup = false
        }
    }

    @discardableResult
    func chooseFolder() -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if FileManager.default.fileExists(atPath: libraryURL.path) {
            panel.directoryURL = libraryURL
        } else {
            panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        }
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            libraryPath = url.path
            hasCompletedSetup = true
            reload()
            return true
        }
        return false
    }

    func reload() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: libraryURL, includingPropertiesForKeys: nil)) ?? []
        // Same filter as the CLI's random picker: skip hidden and raw Gemini output.
        stickers = entries
            .filter { $0.pathExtension.lowercased() == "png" }
            .filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.lowercased().hasPrefix("gemini_generated") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map(Sticker.init)
        if selection == nil || !stickers.contains(where: { $0.id == selection }) {
            selection = stickers.first?.id
        }
        analyse(stickers.map(\.url))
    }

    /// Check and thumbnail any images we have not seen yet (library or sheet).
    private func analyse(_ urls: [URL]) {
        for url in urls where reports[url] == nil {
            Task.detached(priority: .userInitiated) {
                let report = StickerCheck.run(url: url)
                let thumb = Self.thumbnail(url: url, maxPixel: 256)
                let large = Self.thumbnail(url: url, maxPixel: 900)
                await MainActor.run {
                    self.reports[url] = report
                    if let thumb { self.thumbnails[url] = thumb }
                    if let large {
                        self.canvasImages[url] = large
                        self.silhouettes[url] = nil
                        self.hulls[url] = nil
                        if self.doc.items.contains(where: { $0.url == url }) { self.recomputeOverlaps() }
                    }
                }
            }
        }
    }

    nonisolated static func thumbnail(url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    nonisolated static func pixelSize(url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int, w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: Placing stickers

    func isOnSheet(_ sticker: Sticker) -> Bool { doc.items.contains { $0.path == sticker.url.path } }

    func sheetCount(for sticker: Sticker) -> Int {
        doc.items.filter { $0.path == sticker.url.path }.count
    }

    func removeAllFromSheet(_ sticker: Sticker) {
        guard isOnSheet(sticker) else { return }
        recordUndo()
        doc.items.removeAll { $0.path == sticker.url.path }
        if let sel = selectedItem, !doc.items.contains(where: { $0.id == sel }) {
            selectedItem = nil
        }
    }

    func clearSheet() {
        guard !doc.items.isEmpty else { return }
        recordUndo()
        doc.items = []
        selectedItem = nil
    }

    func toggleOnSheet(_ sticker: Sticker) {
        if isOnSheet(sticker) {
            removeAllFromSheet(sticker)
        } else {
            add(sticker.url)
        }
    }

    /// Add a sticker to the sheet: centred on `center` (design mm) when it was
    /// dropped somewhere, otherwise in the first free spot.
    func add(_ url: URL, centeredAt center: CGPoint? = nil, recordHistory: Bool = true) {
        guard let px = Self.pixelSize(url: url) else {
            append("could not read \(url.lastPathComponent)", error: true)
            return
        }
        if recordHistory { recordUndo() }
        analyse([url])
        let aspect = px.width / px.height
        var w = 40.0, h = w / aspect
        if h > 55 { h = 55; w = h * aspect }
        var item = PlacedItem(path: url.path, x: SheetGeometry.margin, y: SheetGeometry.margin, width: w, height: h)
        if let center {
            item.center = center
            item = clamped(item)
        } else if let spot = freeSpot(for: item) {
            item.x = spot.x; item.y = spot.y
        }
        doc.items.append(item)
        selectedItem = item.id
        mode = .arrange
    }

    // MARK: Drag and drop

    /// Bring dropped files into the sticker folder. PNGs already in the folder
    /// are used where they are; others are copied in (an identical file of the
    /// same name is reused, a different one gets " 2", " 3"… so nothing is
    /// overwritten). Returns the library URLs, in drop order.
    @discardableResult
    func importFiles(_ urls: [URL]) -> [URL] {
        let outcome = Self.copyIntoLibrary(urls, library: libraryURL)
        for (text, isError) in outcome.messages { append(text, error: isError) }
        if outcome.copied { reload() }
        if let last = outcome.urls.last { selection = last }
        return outcome.urls
    }

    /// The file side of `importFiles`, kept free of app state so it can be
    /// tested against a scratch folder (`StickerSend --import-test`).
    nonisolated static func copyIntoLibrary(_ urls: [URL], library: URL)
        -> (urls: [URL], copied: Bool, messages: [(String, Bool)]) {
        let fm = FileManager.default
        let library = library.standardizedFileURL
        try? fm.createDirectory(at: library, withIntermediateDirectories: true)
        var result: [URL] = []
        var messages: [(String, Bool)] = []
        var copied = false
        for url in urls.map(\.standardizedFileURL) {
            guard url.pathExtension.lowercased() == "png" else {
                messages.append(("\(url.lastPathComponent): only PNG stickers can be added — give it the sticker treatment first", true))
                continue
            }
            if url.deletingLastPathComponent().path == library.path {
                result.append(url)
                continue
            }
            var dest = library.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                if fm.contentsEqual(atPath: url.path, andPath: dest.path) {
                    result.append(dest)
                    continue
                }
                let stem = url.deletingPathExtension().lastPathComponent
                var n = 2
                repeat {
                    dest = library.appendingPathComponent("\(stem) \(n).png")
                    n += 1
                } while fm.fileExists(atPath: dest.path)
            }
            do {
                try fm.copyItem(at: url, to: dest)
                copied = true
                result.append(dest)
                messages.append(("added \(dest.lastPathComponent) to \(library.lastPathComponent)", false))
            } catch {
                messages.append(("could not copy \(url.lastPathComponent): \(error.localizedDescription)", true))
            }
        }
        return (result, copied, messages)
    }

    /// Files dropped on the sheet: import them, then place them at the drop
    /// point (several files fan out down and to the right).
    func dropOnSheet(_ urls: [URL], at point: CGPoint) {
        let imported = importFiles(urls)
        guard !imported.isEmpty else { return }
        recordUndo()
        for (i, url) in imported.enumerated() {
            add(url, centeredAt: CGPoint(x: point.x + Double(i) * 6, y: point.y + Double(i) * 6), recordHistory: false)
        }
    }

    /// Top-left for the item's frame such that it sits in the first free spot.
    private func freeSpot(for item: PlacedItem) -> CGPoint? {
        let p = SheetGeometry.printable
        let b = extent(item)
        // Offset from the content's corner to the frame's corner.
        let ox = item.x - b.minX, oy = item.y - b.minY
        var y = p.minY
        while y + b.height <= p.maxY + 0.001 {
            var x = p.minX
            while x + b.width <= p.maxX + 0.001 {
                var candidate = item
                candidate.x = x + ox; candidate.y = y + oy
                if !doc.items.contains(where: { cutBox($0).intersects(cutBox(candidate)) }) {
                    return CGPoint(x: candidate.x, y: candidate.y)
                }
                x += 2
            }
            y += 2
        }
        return nil
    }

    func duplicate(_ id: PlacedItem.ID) {
        guard let original = doc.items.first(where: { $0.id == id }) else { return }
        recordUndo()
        var copy = original
        copy.id = UUID()
        if let spot = freeSpot(for: copy) { copy.x = spot.x; copy.y = spot.y } else { copy.x += 4; copy.y += 4 }
        copy = clamped(copy)
        doc.items.append(copy)
        selectedItem = copy.id
    }

    func remove(_ id: PlacedItem.ID) {
        guard doc.items.contains(where: { $0.id == id }) else { return }
        recordUndo()
        doc.items.removeAll { $0.id == id }
        if selectedItem == id { selectedItem = doc.items.last?.id }
    }

    func bringToFront(_ id: PlacedItem.ID) {
        guard let i = doc.items.firstIndex(where: { $0.id == id }), i < doc.items.count - 1 else { return }
        recordUndo()
        doc.items.append(doc.items.remove(at: i))
    }

    /// Move an item so its frame's top-left lands at `origin`, kept on the sheet.
    func move(_ id: PlacedItem.ID, to origin: CGPoint) {
        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return }
        var item = doc.items[i]
        item.x = origin.x; item.y = origin.y
        doc.items[i] = clamped(item)
    }

    /// Resize about the centre, keeping aspect ratio, kept on the sheet.
    func resize(_ id: PlacedItem.ID, width: Double) {
        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return }
        var item = doc.items[i]
        let c = item.center
        let aspect = item.width / item.height
        item.width = max(width, 8)
        item.height = item.width / aspect
        item.center = c
        doc.items[i] = clamped(item)
    }

    /// Set the clockwise rotation in degrees, turning about the centre.
    func rotate(_ id: PlacedItem.ID, to degrees: Double) {
        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return }
        var item = doc.items[i]
        item.angle = degrees
        doc.items[i] = clamped(item)
    }

    func rotate(_ id: PlacedItem.ID, by degrees: Double) {
        guard let item = doc.items.first(where: { $0.id == id }) else { return }
        recordUndo()
        rotate(id, to: item.angle + degrees)
    }

    /// Shrink (about the centre) and then shift an item until what it prints
    /// and cuts sits inside the printable area. Transparent corners of its
    /// frame may hang past the edge.
    private func clamped(_ item: PlacedItem) -> PlacedItem {
        let p = SheetGeometry.printable
        var item = item
        var b = extent(item)
        for _ in 0..<4 where b.width > p.width + 0.001 || b.height > p.height + 0.001 {
            // The outline doesn't scale, so shrink the artwork part only.
            let r = item.outlineMM
            let fit = min((p.width - 2 * r) / max(0.01, b.width - 2 * r),
                          (p.height - 2 * r) / max(0.01, b.height - 2 * r))
            let c = item.center
            item.width *= max(0.05, fit * 0.999)
            item.height *= max(0.05, fit * 0.999)
            item.center = c
            b = extent(item)
        }
        var dx = 0.0, dy = 0.0
        if b.minX < p.minX { dx = p.minX - b.minX } else if b.maxX > p.maxX { dx = p.maxX - b.maxX }
        if b.minY < p.minY { dy = p.minY - b.minY } else if b.maxY > p.maxY { dy = p.maxY - b.maxY }
        item.x += dx; item.y += dy
        return item
    }

    /// The part of the sticker the blade will follow (its opaque area), in mm.
    func cutBox(_ item: PlacedItem) -> CGRect { extent(item) }

    /// What actually prints and cuts, in design mm: the sticker's opaque
    /// shape after rotation, grown by its outline. This, not the rotated
    /// rectangle, is what has to stay inside the safe area: the rectangle's
    /// transparent corners can stick out a long way on a turned sticker.
    func extent(_ item: PlacedItem) -> CGRect {
        let a = item.angle * .pi / 180
        let cosA = cos(a), sinA = sin(a)
        let c = item.center
        let points: [CGPoint]
        if let hull = hull(for: item.url) {
            points = hull
        } else {
            let box = reports[item.url]?.opaqueBox ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            points = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                      CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
        }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in points {
            let dx = item.x + p.x * item.width - c.x, dy = item.y + p.y * item.height - c.y
            let x = c.x + dx * cosA - dy * sinA, y = c.y + dx * sinA + dy * cosA
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }
        // An outline adds the same width in every direction.
        let r = item.outlineMM
        return CGRect(x: minX - r, y: minY - r, width: maxX - minX + 2 * r, height: maxY - minY + 2 * r)
    }

    private var hulls: [URL: [CGPoint]] = [:]

    /// Convex hull of the sticker's opaque pixels, as fractions of the image
    /// (0…1, y down). The bounds of a rotated shape are the bounds of its
    /// rotated hull, so this is exact for `extent` at any angle.
    private func hull(for url: URL) -> [CGPoint]? {
        if let h = hulls[url] { return h }
        guard let f = silhouette(for: url) else { return nil }
        var pts: [CGPoint] = []
        func solid(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && x < f.width && y >= 0 && y < f.height && f.distance[y * f.width + x] == 0
        }
        for y in 0..<f.height {
            for x in 0..<f.width where solid(x, y) {
                guard !solid(x - 1, y) || !solid(x + 1, y) || !solid(x, y - 1) || !solid(x, y + 1) else { continue }
                for (cx, cy) in [(x, y), (x + 1, y), (x, y + 1), (x + 1, y + 1)] {
                    pts.append(CGPoint(x: Double(cx) / Double(f.width), y: Double(cy) / Double(f.height)))
                }
            }
        }
        guard !pts.isEmpty else { return nil }
        // Andrew's monotone chain.
        pts.sort { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in pts {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in pts.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        let hull = Array(lower.dropLast() + upper.dropLast())
        hulls[url] = hull
        return hull
    }

    /// Load a sheet and its images synchronously (for `--overlaps`).
    func loadForTesting(_ url: URL) {
        guard let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode(SheetDocument.self, from: data) else { return }
        for item in loaded.items { canvasImages[item.url] = Self.thumbnail(url: item.url, maxPixel: 900) }
        doc = loaded
    }

    // MARK: Cut-line collisions

    /// A sticker's silhouette as a distance field: for each pixel of a small
    /// copy of the image, the distance (in those pixels) to the nearest pixel
    /// the cutter treats as solid (alpha > 128). 0 inside the sticker.
    struct SilhouetteField {
        let width: Int
        let height: Int
        let distance: [Float]
    }

    private var silhouettes: [URL: SilhouetteField] = [:]

    /// Items whose cut lines touch or cross another sticker's.
    @Published private(set) var overlapping: Set<PlacedItem.ID> = []
    /// Red marks where the collisions are, covering the 96 × 170 mm canvas.
    @Published private(set) var overlapImage: NSImage?

    /// Cut lines closer than this are flagged too: the blade would leave a
    /// sliver too thin to peel.
    static let cutClearanceMM = 0.5
    private static let overlapCellMM = 0.25

    private func silhouette(for url: URL) -> SilhouetteField? {
        if let f = silhouettes[url] { return f }
        guard let ns = canvasImages[url],
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 256 / Double(max(cg.width, cg.height)))
        let w = max(1, Int(Double(cg.width) * scale)), h = max(1, Int(Double(cg.height) * scale))
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Bitmap rows are top-down, matching the image (see SheetBuilder.silhouette).
        let d2 = OutlineRenderer.squaredDistanceToOpaque(px: px, w: w, h: h)
        let field = SilhouetteField(width: w, height: h, distance: d2.map { Float($0.squareRoot()) })
        silhouettes[url] = field
        return field
    }

    /// Paint every sticker's cut area (silhouette + outline + half the
    /// clearance) onto a 0.25 mm grid of the sheet; cells claimed by two
    /// stickers are collisions. This follows the real shapes, so stickers
    /// whose boxes overlap but whose outlines don't are fine.
    func recomputeOverlaps() {
        let cell = Self.overlapCellMM
        let gw = Int(SheetGeometry.width / cell), gh = Int(SheetGeometry.height / cell)
        var owner = [Int32](repeating: -1, count: gw * gh)
        var clash = [Bool](repeating: false, count: gw * gh)
        var ids = Set<PlacedItem.ID>()
        let items = doc.items
        let half = Self.cutClearanceMM / 2

        for (index, item) in items.enumerated() {
            let field = silhouette(for: item.url)
            let reach = item.outlineMM + half
            let a = -item.angle * .pi / 180           // inverse rotation
            let c = item.center
            let cosA = cos(a), sinA = sin(a)
            let b = extent(item).insetBy(dx: -half, dy: -half)
            let x0 = max(0, Int(b.minX / cell)), x1 = min(gw - 1, Int(b.maxX / cell))
            let y0 = max(0, Int(b.minY / cell)), y1 = min(gh - 1, Int(b.maxY / cell))
            guard x0 <= x1, y0 <= y1 else { continue }

            for gy in y0...y1 {
                for gx in x0...x1 {
                    // Cell centre -> the sticker's unrotated frame.
                    let px = (Double(gx) + 0.5) * cell - c.x, py = (Double(gy) + 0.5) * cell - c.y
                    let lx = c.x + px * cosA - py * sinA, ly = c.y + px * sinA + py * cosA
                    let inside: Bool
                    if let f = field {
                        let mmX = item.width / Double(f.width), mmY = item.height / Double(f.height)
                        let u = (lx - item.x) / mmX, v = (ly - item.y) / mmY
                        let cu = min(max(u, 0), Double(f.width - 1)), cv = min(max(v, 0), Double(f.height - 1))
                        // Beyond the image edge, add the distance to that edge.
                        let outside = hypot((u - cu) * mmX, (v - cv) * mmY)
                        let d = Double(f.distance[Int(cv) * f.width + Int(cu)]) * mmX + outside
                        inside = d <= reach
                    } else {
                        // Image not loaded yet: fall back to the frame.
                        inside = item.outerRect.insetBy(dx: -half, dy: -half).contains(CGPoint(x: lx, y: ly))
                    }
                    guard inside else { continue }
                    let k = gy * gw + gx
                    let prev = owner[k]
                    if prev >= 0 && Int(prev) != index {
                        clash[k] = true
                        ids.insert(item.id)
                        ids.insert(items[Int(prev)].id)
                    } else {
                        owner[k] = Int32(index)
                    }
                }
            }
        }

        overlapping = ids
        overlapImage = ids.isEmpty ? nil : Self.overlayImage(clash, gw: gw, gh: gh)
    }

    private static func overlayImage(_ clash: [Bool], gw: Int, gh: Int) -> NSImage? {
        var px = [UInt8](repeating: 0, count: gw * gh * 4)
        for i in 0..<(gw * gh) where clash[i] {
            px[i * 4] = 235; px[i * 4 + 1] = 20; px[i * 4 + 2] = 40; px[i * 4 + 3] = 235
        }
        guard let ctx = CGContext(data: &px, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: gw, height: gh))
    }

    // MARK: Arranging and filling

    @Published var isArranging = false
    /// Layouts from before each arrange/fill, newest last, for Undo Arrange.
    @Published private(set) var arrangeHistory: [SheetDocument] = []

    func undoArrange() {
        guard let last = arrangeHistory.popLast() else { return }
        doc = last
        selectedItem = nil
    }

    private func pieces(from items: [PlacedItem]) -> [Packer.Piece] {
        items.enumerated().map { (i, item) in
            Packer.Piece(id: i, field: silhouette(for: item.url),
                         opaqueBox: reports[item.url]?.opaqueBox ?? CGRect(x: 0, y: 0, width: 1, height: 1),
                         aspect: item.width / item.height, width: item.width,
                         outlineMM: item.outlineMM, baseAngle: item.angle)
        }
    }

    /// Run a packing job off the main thread, then apply it.
    private func arrange(_ label: String,
                         _ job: @escaping @Sendable () -> (items: [PlacedItem], note: String?)?) {
        guard !isArranging else { return }
        isArranging = true
        let before = doc
        Task.detached(priority: .userInitiated) {
            let result = job()
            await MainActor.run {
                self.isArranging = false
                guard let result else {
                    self.append("\(label): the stickers don't fit on one sheet", error: true)
                    return
                }
                self.arrangeHistory.append(before)
                if self.arrangeHistory.count > 20 { self.arrangeHistory.removeFirst() }
                self.recordUndo(before)
                self.doc.items = result.items
                self.selectedItem = nil
                self.mode = .arrange
                if let note = result.note { self.append(note) }
            }
        }
    }

    /// Nest the stickers at their current sizes and angles using their real
    /// shapes; shrink everything evenly only if they don't fit.
    func autoArrange() {
        let items = doc.items
        guard !items.isEmpty else { return }
        let pieces = pieces(from: items)
        let o: Packer.Options = { var o = Packer.Options(); o.allowRotation = false; return o }()
        arrange("Auto-Arrange") {
            if let placed = Packer.packAll(pieces, scale: 1, o: o) {
                return (Self.apply(placed, to: items, scale: 1), nil)
            }
            guard let (scale, placed) = Packer.packLargest(pieces, maxScale: 1, o: o) else { return nil }
            return (Self.apply(placed, to: items, scale: scale),
                    String(format: "Auto-Arrange shrank everything to %.0f%% to fit", scale * 100))
        }
    }

    /// Make the stickers on the sheet as large as possible together (same
    /// relative sizes), turning them in 90° steps where that packs better.
    func fillBiggest() {
        let items = doc.items
        guard !items.isEmpty else { return }
        let pieces = pieces(from: items)
        let o = Packer.Options()
        // Upper bound: the sheet's area over the stickers' current area.
        let used = items.reduce(0.0) { $0 + extent($1).width * extent($1).height }
        let maxScale = max(1, (o.area.width * o.area.height / max(used, 1)).squareRoot() * 1.6)
        arrange("Biggest possible") {
            guard let (scale, placed) = Packer.packLargest(pieces, maxScale: maxScale, o: o, steps: 14) else { return nil }
            return (Self.apply(placed, to: items, scale: scale),
                    String(format: "Biggest possible: everything scaled to %.0f%%", scale * 100))
        }
    }

    /// Fill the sheet with as many copies as fit of each different sticker
    /// on it, at its current size, taking them in turn.
    func fillCopies() {
        var seen = Set<String>()
        let types = doc.items.filter { seen.insert($0.path).inserted }
        guard !types.isEmpty else { return }
        let pieces = pieces(from: types)
        let o = Packer.Options()
        arrange("Most copies") {
            let placed = Packer.packCopies(pieces, o: o)
            guard !placed.isEmpty else { return nil }
            var items: [PlacedItem] = []
            for p in placed {
                var item = types[p.id]
                item.id = UUID()
                item.angle = p.angle
                item.center = p.center
                items.append(item)
            }
            return (items, "Most copies: \(items.count) stickers on the sheet")
        }
    }

    nonisolated private static func apply(_ placed: [Packer.Placed], to items: [PlacedItem], scale: Double) -> [PlacedItem] {
        placed.map { p in
            var item = items[p.id]
            item.width *= scale
            item.height *= scale
            item.angle = p.angle
            item.center = p.center
            return item
        }
    }

    func pickRandom(_ count: Int) {
        let good = stickers.filter { (reports[$0.url]?.overall ?? .fail) < .fail }
        recordUndo()
        doc.items = []
        for s in good.shuffled().prefix(count) { add(s.url, recordHistory: false) }
        autoArrange()
    }

    // MARK: Outlines

    /// A preview of an outlined sticker, drawn by the same `OutlineRenderer`
    /// the sheet build uses, from the canvas-resolution image.
    struct OutlinePreview {
        let image: NSImage
        /// Padding added on each side, in preview pixels.
        let pad: Int
        /// Width of the preview's source image, in pixels.
        let sourceWidth: Int
    }

    @Published var outlinePreviews: [String: OutlinePreview] = [:]
    /// The newest preview made for each item, shown while a fresher one renders.
    @Published var latestOutlineKey: [PlacedItem.ID: String] = [:]

    func outline(for id: PlacedItem.ID) -> OutlineSpec {
        doc.items.first { $0.id == id }?.outline ?? OutlineSpec(widthMM: 0, color: "#ffffff", fillGaps: false)
    }

    func setOutline(_ id: PlacedItem.ID, _ spec: OutlineSpec) {
        guard let i = doc.items.firstIndex(where: { $0.id == id }) else { return }
        var item = doc.items[i]
        item.outline = spec.isActive ? spec : nil
        doc.items[i] = clamped(item)
    }

    func applyOutlineToAll(_ spec: OutlineSpec) {
        recordUndo()
        for item in doc.items { setOutline(item.id, spec) }
    }

    /// Cache key for an item's outline preview, or nil if it has no outline.
    func outlineKey(_ item: PlacedItem) -> String? {
        guard let spec = item.outline, spec.isActive,
              let src = canvasImages[item.url] else { return nil }
        let radius = spec.widthMM / (item.width / Double(src.size.width))
        return "\(item.path)|\((radius * 4).rounded() / 4)|\(spec.color)|\(spec.fillGaps)|\(spec.kind.rawValue)"
    }

    func outlinePreview(for item: PlacedItem) -> OutlinePreview? {
        if let key = outlineKey(item), let p = outlinePreviews[key] { return p }
        if item.outline?.isActive == true, let key = latestOutlineKey[item.id] { return outlinePreviews[key] }
        return nil
    }

    func renderOutlinePreview(_ item: PlacedItem) async {
        guard let key = outlineKey(item), let spec = item.outline,
              let ns = canvasImages[item.url],
              let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        if outlinePreviews[key] != nil { latestOutlineKey[item.id] = key; return }
        // Debounce slider drags.
        try? await Task.sleep(nanoseconds: 80_000_000)
        if Task.isCancelled { return }
        let radius = spec.widthMM / (item.width / Double(cg.width))
        let rendered = await Task.detached(priority: .userInitiated) {
            OutlineRenderer.render(cg, radius: radius, rgb: OutlineRenderer.parse(spec.color),
                                   fillGaps: spec.fillGaps, style: spec.kind)
        }.value
        guard let rendered else { return }
        outlinePreviews[key] = OutlinePreview(
            image: NSImage(cgImage: rendered.image, size: NSSize(width: rendered.image.width, height: rendered.image.height)),
            pad: rendered.pad, sourceWidth: cg.width)
        latestOutlineKey[item.id] = key
        if outlinePreviews.count > 200 { outlinePreviews.removeAll() }
    }

    // MARK: Background

    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.directoryURL = libraryURL.deletingLastPathComponent()
        panel.prompt = "Use as Background"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recordUndo()
        var bg = doc.background ?? SheetBackgroundSpec()
        bg.path = url.path
        doc.background = bg
        loadBackgroundImage()
    }

    var backgroundColor: Color {
        get { Self.color(hex: doc.background?.color ?? "#ffffff") }
        set {
            guard let hex = Self.hex(newValue) else { return }
            var bg = doc.background ?? SheetBackgroundSpec()
            bg.color = hex
            doc.background = bg
        }
    }

    nonisolated static func color(hex: String) -> Color {
        let c = OutlineRenderer.parse(hex)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    nonisolated static func hex(_ color: Color) -> String? {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x", Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded()))
    }

    func clearBackgroundImage() {
        recordUndo()
        doc.background?.path = nil
        if doc.background?.isEmpty == true { doc.background = nil }
        backgroundImage = nil
    }

    func clearBackgroundColor() {
        recordUndo()
        doc.background?.color = nil
        if doc.background?.isEmpty == true { doc.background = nil }
    }

    private func loadBackgroundImage() {
        backgroundImage = nil
        guard let path = doc.background?.path else { return }
        let url = URL(fileURLWithPath: path)
        Task.detached {
            let img = Self.thumbnail(url: url, maxPixel: 1400)
            await MainActor.run { self.backgroundImage = img }
        }
    }

    // MARK: Saved sheets

    func refreshSavedSheets() {
        let entries = (try? FileManager.default.contentsOfDirectory(at: sheetsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        savedSheets = entries
            .filter { $0.pathExtension == SheetDocument.fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Ask before throwing away unsaved changes. Returns false to cancel.
    private func confirmDiscard() -> Bool {
        guard isDirty, !doc.items.isEmpty || doc.background != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(doc.name)”?"
        alert.informativeText = "Your arrangement will be lost if you don't save it."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func newSheet() {
        guard confirmDiscard() else { return }
        doc = SheetDocument()
        savedDoc = doc
        docURL = nil
        selectedItem = nil
        backgroundImage = nil
        undoStack = []
        redoStack = []
        arrangeHistory = []
        mode = .arrange
        inspectorTab = .sheet
    }

    func open(_ url: URL) {
        guard url != docURL || isDirty else { return }
        guard confirmDiscard() else { return }
        do {
            let data = try Data(contentsOf: url)
            var loaded = try JSONDecoder().decode(SheetDocument.self, from: data)
            let missing = loaded.items.filter { !FileManager.default.fileExists(atPath: $0.path) }
            for m in missing { append("missing sticker, removed from sheet: \(m.path)", error: true) }
            loaded.items.removeAll { item in missing.contains { $0.id == item.id } }
            if let bg = loaded.background?.path, !FileManager.default.fileExists(atPath: bg) {
                append("missing background image: \(bg)", error: true)
                loaded.background?.path = nil
            }
            doc = loaded
            savedDoc = missing.isEmpty ? loaded : SheetDocument()
            docURL = url
            selectedItem = nil
            undoStack = []
            redoStack = []
            arrangeHistory = []
            mode = .arrange
            inspectorTab = .sheet
            analyse(loaded.items.map(\.url))
            loadBackgroundImage()
            append("opened \(url.lastPathComponent)")
        } catch {
            append("could not open \(url.lastPathComponent): \(error.localizedDescription)", error: true)
        }
    }

    func openWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SheetDocument.fileExtension) ?? .json]
        panel.directoryURL = sheetsDir
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    @discardableResult
    func save() -> Bool {
        guard let docURL else { return saveAs() }
        return write(to: docURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        try? FileManager.default.createDirectory(at: sheetsDir, withIntermediateDirectories: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: SheetDocument.fileExtension) ?? .json]
        panel.directoryURL = sheetsDir
        panel.nameFieldStringValue = doc.name
        panel.prompt = "Save Sheet"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        doc.name = url.deletingPathExtension().lastPathComponent
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(doc).write(to: url, options: .atomic)
            docURL = url
            savedDoc = doc
            refreshSavedSheets()
            append("saved \(url.lastPathComponent)")
            return true
        } catch {
            append("could not save: \(error.localizedDescription)", error: true)
            return false
        }
    }

    /// Moves the sheet file to the Trash (recoverable).
    func deleteSheet(_ url: URL) {
        let alert = NSAlert()
        alert.messageText = "Move “\(url.deletingPathExtension().lastPathComponent)” to the Trash?"
        alert.informativeText = "Only the saved arrangement is removed — your sticker images are not touched."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if url == docURL { docURL = nil; savedDoc = SheetDocument() }
            refreshSavedSheets()
        } catch {
            append("could not delete: \(error.localizedDescription)", error: true)
        }
    }

    // MARK: Build & print

    private func invalidateSheet() {
        previewImage = nil
        sheetContours = nil
    }

    /// Stickers on the sheet that will produce a bad cut.
    var sheetBlockers: [String] {
        var seen = Set<String>()
        return doc.items.compactMap { item in
            guard let r = reports[item.url] else { return nil }
            let failed = r.checks.filter { check in
                guard check.level == .fail else { return false }
                // An outline fixes some failures: filled gaps make one shape,
                // and the outline's padding moves the edge off the canvas border.
                if check.id == "shape", item.outline?.fillGaps == true { return false }
                if check.id == "margin", item.outlineMM > 0 { return false }
                return true
            }.map(\.title)
            guard !failed.isEmpty, seen.insert(item.path + failed.joined()).inserted else { return nil }
            return "\(item.url.deletingPathExtension().lastPathComponent): \(failed.joined(separator: ", "))"
        }
    }

    func buildSheet() {
        guard !doc.items.isEmpty else { return }
        guard let binary else {
            append("cricut-bt binary not found — run `swift build -c release` first.", error: true)
            return
        }
        do {
            try JSONEncoder().encode(doc).write(to: sheetLayout, options: .atomic)
        } catch {
            append("could not write the layout: \(error.localizedDescription)", error: true)
            return
        }
        isBuilding = true
        invalidateSheet()
        append("$ cricut-bt sheet-layout … (\(doc.items.count) sticker\(doc.items.count == 1 ? "" : "s"))")
        run(binary, ["sheet-layout", sheetLayout.path, sheetJPEG.path, sheetPLT.path]) { [weak self] status in
            guard let self else { return }
            guard status == 0 else { self.isBuilding = false; return }
            self.run(binary, ["preview", self.sheetJPEG.path, self.sheetPLT.path, self.sheetPreview.path]) { status in
                self.isBuilding = false
                if status == 0 {
                    self.previewImage = NSImage(contentsOf: self.sheetPreview)
                    self.mode = .preview
                }
            }
        }
    }

    private var addressArgs: [String] {
        let trimmed = printerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? [] : ["--address", trimmed]
    }

    func queryStatus() {
        guard let binary else { return }
        isQuerying = true
        printerSummary = []
        append("$ cricut-bt status")
        run(binary, ["status", "--attempts", "3"] + addressArgs, collectSummary: true) { [weak self] _ in
            self?.isQuerying = false
        }
    }

    func printSheet() {
        guard let binary, previewImage != nil else { return }
        isPrinting = true
        uploadProgress = 0
        jobStage = "Connecting…"
        append("$ cricut-bt print --copies \(doc.copies)")
        run(binary, ["print", sheetJPEG.path, sheetPLT.path, "--copies", "\(doc.copies)"] + addressArgs) { [weak self] status in
            guard let self else { return }
            self.isPrinting = false
            self.uploadProgress = nil
            self.jobStage = status == 0 ? (self.jobStage ?? "Finished") : "Failed — see log"
        }
    }

    func revealSheet() {
        NSWorkspace.shared.activateFileViewerSelecting([sheetJPEG, sheetPLT, sheetPreview])
    }

    // MARK: Process plumbing

    private func run(_ binary: URL, _ args: [String], collectSummary: Bool = false, then: @escaping (Int32) -> Void) {
        do {
            try runner.run(binary: binary, arguments: args, onLine: { [weak self] line in
                self?.handle(line: line, collectSummary: collectSummary)
            }, onExit: { [weak self] status in
                if status != 0 { self?.append("exited with status \(status)", error: true) }
                then(status)
            })
        } catch {
            append("could not start cricut-bt: \(error.localizedDescription)", error: true)
            then(-1)
        }
    }

    private func handle(line: String, collectSummary: Bool) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let isError = trimmed.hasPrefix("error") || trimmed.contains("failed") || trimmed.hasPrefix("could not")
        append(trimmed, error: isError)

        if collectSummary, line.hasPrefix("  "), !trimmed.hasPrefix("error") {
            printerSummary.append(contentsOf: trimmed.components(separatedBy: ", "))
        }
        if let m = trimmed.firstMatch(of: #/uploading (\d+)\/(\d+)/#), let a = Double(m.1), let b = Double(m.2), b > 0 {
            uploadProgress = a / b
            jobStage = "Uploading"
        } else if trimmed.hasPrefix("upload complete") {
            uploadProgress = 1
        } else if let m = trimmed.firstMatch(of: #/job \d+: (.+)/#) {
            jobStage = String(m.1)
        } else if trimmed.hasPrefix("printer accepted job") || trimmed.hasPrefix("connected on") {
            jobStage = trimmed.prefix(1).uppercased() + trimmed.dropFirst()
        } else if let m = trimmed.firstMatch(of: #/with (\d+) contour/#) {
            sheetContours = Int(m.1)
        }
    }

    func append(_ text: String, error: Bool = false) {
        log.append(LogLine(text: text, isError: error))
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }
}
