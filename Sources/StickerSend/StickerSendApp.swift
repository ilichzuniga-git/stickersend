import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched as a bare SwiftPM binary there is no bundle to make this a
        // regular app, so promote it and bring the window forward.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct StickerSendApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    init() {
        // `StickerSend --check a.png b.png` prints the playbook checks and exits.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--check") {
            var worst = StickerReport.Level.pass
            for path in args[(i + 1)...] {
                let r = StickerCheck.run(url: URL(fileURLWithPath: path))
                worst = max(worst, r.overall)
                print("\((path as NSString).lastPathComponent)  [\(r.overall)]  \(r.cutLoops) cut loop(s)")
                for c in r.checks { print("  \(c.level)\t\(c.title): \(c.detail)") }
            }
            exit(worst == .fail ? 1 : 0)
        }
        // `StickerSend --import-test <library> <file>...` runs the drag-and-drop
        // copy logic against a scratch folder.
        if let i = args.firstIndex(of: "--import-test"), i + 1 < args.count {
            let library = URL(fileURLWithPath: args[i + 1])
            let files = args[(i + 2)...].map { URL(fileURLWithPath: $0) }
            let outcome = AppModel.copyIntoLibrary(files, library: library)
            for (text, isError) in outcome.messages { print((isError ? "! " : "  ") + text) }
            print("result: " + outcome.urls.map(\.lastPathComponent).joined(separator: ", "))
            exit(0)
        }
        // `StickerSend --clamp-test sheet.stickersheet`: drag the first sticker
        // far past each edge and report where it stops.
        if let i = args.firstIndex(of: "--clamp-test"), i + 1 < args.count {
            MainActor.assumeIsolated {
                let model = AppModel()
                model.loadForTesting(URL(fileURLWithPath: args[i + 1]))
                guard let item = model.doc.items.first else { print("no items"); return }
                for (name, target) in [("left", CGPoint(x: -200, y: item.y)), ("right", CGPoint(x: 300, y: item.y)),
                                       ("top", CGPoint(x: item.x, y: -200)), ("bottom", CGPoint(x: item.x, y: 400))] {
                    model.move(item.id, to: target)
                    let moved = model.doc.items[0]
                    let e = model.extent(moved), f = moved.bounds
                    print(String(format: "%@: content x %.1f…%.1f y %.1f…%.1f | frame x %.1f…%.1f y %.1f…%.1f",
                                 name, e.minX, e.maxX, e.minY, e.maxY, f.minX, f.maxX, f.minY, f.maxY))
                }
            }
            exit(0)
        }
        // `StickerSend --pack-test biggest|copies|arrange in.stickersheet out.stickersheet`
        if let i = args.firstIndex(of: "--pack-test"), i + 3 < args.count {
            MainActor.assumeIsolated {
                let model = AppModel()
                model.loadForTesting(URL(fileURLWithPath: args[i + 2]))
                let start = Date()
                switch args[i + 1] {
                case "biggest": model.fillBiggest()
                case "copies": model.fillCopies()
                default: model.autoArrange()
                }
                while model.isArranging { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                print(String(format: "%.2fs, %d stickers", Date().timeIntervalSince(start), model.doc.items.count))
                for line in model.log { print("  " + line.text) }
                print("collisions: \(model.overlapping.count)")
                let data = try! JSONEncoder().encode(model.doc)
                try! data.write(to: URL(fileURLWithPath: args[i + 3]))
            }
            exit(0)
        }
        // `StickerSend --overlaps sheet.stickersheet` prints which stickers' cut lines collide.
        if let i = args.firstIndex(of: "--overlaps"), i + 1 < args.count {
            MainActor.assumeIsolated {
                let model = AppModel()
                model.loadForTesting(URL(fileURLWithPath: args[i + 1]))
                let names = model.doc.items.filter { model.overlapping.contains($0.id) }
                    .map { $0.url.deletingPathExtension().lastPathComponent }
                print(names.isEmpty ? "no collisions" : "collisions: " + names.joined(separator: ", "))
            }
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("StickerSend") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Sheet") { model.newSheet() }.keyboardShortcut("n")
                Button("Open Sheet…") { model.openWithPanel() }.keyboardShortcut("o")
                Divider()
                Button("Choose Sticker Folder…") { model.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Rescan Folder") { model.reload() }.keyboardShortcut("r")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save Sheet") { model.save() }.keyboardShortcut("s")
                Button("Save Sheet As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z")
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandMenu("Sheet") {
                Button("Duplicate Sticker") { if let id = model.selectedItem { model.duplicate(id) } }
                    .keyboardShortcut("d")
                    .disabled(model.selectedItem == nil)
                Button("Remove Sticker") { if let id = model.selectedItem { model.remove(id) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(model.selectedItem == nil)
                Button("Rotate Left 90°") { if let id = model.selectedItem { model.rotate(id, by: -90) } }
                    .keyboardShortcut("[")
                    .disabled(model.selectedItem == nil)
                Button("Rotate Right 90°") { if let id = model.selectedItem { model.rotate(id, by: 90) } }
                    .keyboardShortcut("]")
                    .disabled(model.selectedItem == nil)
                Divider()
                Button("Auto-Arrange") { model.autoArrange() }.keyboardShortcut("a", modifiers: [.command, .option])
                Button("Fill Sheet: Biggest Possible") { model.fillBiggest() }
                Button("Fill Sheet: Most Copies") { model.fillCopies() }
                Button("Undo Arrange") { model.undoArrange() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
                    .disabled(model.arrangeHistory.isEmpty)
                Divider()
                Button("Build Sheet & Cut Preview") { model.buildSheet() }.keyboardShortcut("b")
                    .disabled(model.doc.items.isEmpty || model.busy)
                Button(model.showLog ? "Hide Activity Log" : "Show Activity Log") { model.showLog.toggle() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
