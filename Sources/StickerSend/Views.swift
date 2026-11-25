import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Shared styling & badges

extension StickerReport.Level {
    var color: Color {
        switch self {
        case .pass: return .green
        case .info: return .secondary
        case .warn: return .orange
        case .fail: return .red
        }
    }
    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }
    var label: String {
        switch self {
        case .pass: return "Ready"
        case .info: return "Ready"
        case .warn: return "Check"
        case .fail: return "Fix first"
        }
    }
}

/// The playbook's "dark check layer" (#3366aa): a white border is invisible on
/// white, so stickers are always shown on this blue.
let darkCheck = Color(red: 0x33 / 255, green: 0x66 / 255, blue: 0xaa / 255)

struct LevelBadge: View {
    let level: StickerReport.Level?
    var quietWhenPass: Bool = false

    var body: some View {
        if let level {
            if !quietWhenPass || level >= .warn {
                Image(systemName: level.symbol)
                    .foregroundStyle(level.color)
                    .help(level.label)
            }
        } else {
            ProgressView().controlSize(.mini)
        }
    }
}

// MARK: - Root (Clean 3-Zone Workspace)

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var showInspector = true
    @State private var showPrinterPopover = false
    @State private var showPrintPopover = false
    @State private var confirmPrint = false
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationSplitView {
            LibraryView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 300)
        } detail: {
            SheetWorkspaceView(showInspector: showInspector)
        }
        .navigationTitle("")
        .toolbar {
            // Leading: Sheet document menu + quick save
            ToolbarItemGroup(placement: .navigation) {
                SheetDocumentMenu()
                Button { model.save() } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Save sheet (⌘S)")
                .disabled(!model.isDirty && model.docURL != nil)
            }

            // Center: Arrange / Cut Preview mode switch
            ToolbarItem(placement: .principal) {
                Picker("Mode", selection: Binding(
                    get: { model.mode },
                    set: { model.setMode($0) }
                )) {
                    ForEach(SheetMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 196)
                .help("Switch between arranging stickers and previewing cut lines")
            }

            // Trailing: Printer status popover, Print & Cut primary action, Inspector toggle
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showPrinterPopover.toggle()
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(printerDotColor)
                            .frame(width: 7, height: 7)
                        Text("StickerPix")
                    }
                }
                .help("Printer connection & Bluetooth settings")
                .popover(isPresented: $showPrinterPopover, arrowEdge: .bottom) {
                    PrinterPopover()
                        .environmentObject(model)
                }

                Button {
                    showPrintPopover.toggle()
                } label: {
                    Label("Print & Cut", systemImage: "printer.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.doc.items.isEmpty)
                .help(model.doc.items.isEmpty ? "Add stickers to the sheet first" : "Preview cuts and send to StickerPix")
                .popover(isPresented: $showPrintPopover, arrowEdge: .bottom) {
                    PrintPopover(showPopover: $showPrintPopover, confirmPrint: $confirmPrint)
                        .environmentObject(model)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { showInspector.toggle() }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .confirmationDialog(
            "Print and cut \(model.doc.copies) sheet\(model.doc.copies == 1 ? "" : "s")?",
            isPresented: $confirmPrint
        ) {
            Button("Print \(model.doc.copies == 1 ? "1 sheet" : "\(model.doc.copies) sheets")") {
                model.printSheet()
            }
        } message: {
            Text("This uses \(model.doc.copies) print\(model.doc.copies == 1 ? "" : "s") from the cartridge. Don't quit the app while the job runs — killing a session mid-job can leave the printer refusing connections for a while.")
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
        .sheet(isPresented: $model.showWelcomeSetup) {
            WelcomeSetupSheet()
                .environmentObject(model)
                .interactiveDismissDisabled(true)
        }
    }

    private var printerDotColor: Color {
        if model.binary == nil { return .red }
        if model.isPrinting || model.isQuerying { return .orange }
        if !model.printerSummary.isEmpty { return .green }
        return .secondary.opacity(0.6)
    }

    /// Allow Backspace/Delete to remove the selected canvas sticker and Escape to deselect,
    /// without interfering with text fields or the library search bar.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.isEmpty else { return event }
            if (event.keyCode == 51 || event.keyCode == 117), let id = model.selectedItem, model.mode == .arrange {
                model.remove(id)
                return nil
            }
            if event.keyCode == 53, model.selectedItem != nil {
                model.selectedItem = nil
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

// MARK: - Sheet Document Menu (Toolbar)

struct SheetDocumentMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            Button("New Sheet") { model.newSheet() }
            Button("Open Sheet…") { model.openWithPanel() }
            Divider()
            Button("Save") { model.save() }
            Button("Save As…") { model.saveAs() }
            if !model.savedSheets.isEmpty {
                Divider()
                Section("Saved Sheets") {
                    ForEach(model.savedSheets, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.open(url) }
                    }
                }
                Menu("Delete Saved Sheet") {
                    ForEach(model.savedSheets, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) { model.deleteSheet(url) }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack")
                Text(model.doc.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if model.isDirty {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
            }
        }
        .help("Switch, save, or create sticker sheets")
    }
}

// MARK: - Library (Left Sidebar)

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter = ""
    @State private var dropTargeted = false

    var filtered: [Sticker] {
        filter.isEmpty ? model.stickers : model.stickers.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        let listSelection = Binding<Sticker.ID?>(
            get: { model.selection },
            set: { newID in
                guard let newID, let sticker = model.stickers.first(where: { $0.id == newID }) else { return }
                model.inspectLibrarySticker(sticker)
            }
        )

        VStack(spacing: 0) {
            List(selection: listSelection) {
                Section {
                    ForEach(filtered) { sticker in
                        LibraryRow(sticker: sticker)
                            .tag(sticker.id)
                            .contextMenu {
                                Button("Add to Sheet") { model.add(sticker.url) }
                                if model.isOnSheet(sticker) {
                                    Button("Remove All Copies from Sheet", role: .destructive) {
                                        model.removeAllFromSheet(sticker)
                                    }
                                }
                                Divider()
                                Button("Inspect Quality Checks") { model.inspectLibrarySticker(sticker) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([sticker.url]) }
                            }
                    }
                } header: {
                    HStack {
                        Text("Stickers")
                        Spacer()
                        Text("\(filtered.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $filter, placement: .sidebar, prompt: "Filter stickers")
            // Drop PNGs from Finder to copy them into the sticker folder.
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
                loadFileURLs(providers) { model.importFiles($0) }
                return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 3)
                        .padding(3)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if model.stickers.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No sticker PNGs in this folder")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button("Choose Folder…") { model.chooseFolder() }
                    }
                    .padding()
                }
            }

            Divider()

            // Compact folder footer (keeps toolbar uncluttered)
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.libraryURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button { model.chooseFolder() } label: {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Choose sticker folder (⇧⌘O)")

                Button { model.reload() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Rescan sticker folder (⌘R)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
    }
}

struct LibraryRow: View {
    @EnvironmentObject var model: AppModel
    let sticker: Sticker

    var body: some View {
        let count = model.sheetCount(for: sticker)
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(darkCheck)
                if let img = model.thumbnails[sticker.url] {
                    Image(nsImage: img).resizable().scaledToFit().padding(3)
                }
            }
            .frame(width: 36, height: 36)

            Text(sticker.name.replacingOccurrences(of: " Sticker", with: ""))
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Quiet: only surface warnings & failures so ready rows stay calm.
            LevelBadge(level: model.reports[sticker.url]?.overall, quietWhenPass: true)

            Button {
                model.add(sticker.url)
            } label: {
                if count > 0 {
                    Text("×\(count)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "plus.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            .help(count > 0 ? "\(count) on sheet — click to add another copy" : "Add to sheet")
        }
        .padding(.vertical, 2)
        // Native Transferable drag: integrates with NSTableView without adding click delay.
        .draggable(sticker.url)
    }
}

// MARK: - Sticker Check View (Dark-blue border preview + smart playbook checks)

struct StickerCheckInspector: View {
    @EnvironmentObject var model: AppModel
    @State private var showPassingDetails = false

    /// Prefer the currently selected canvas sticker if no library selection overrides it,
    /// otherwise the library selection.
    var sticker: Sticker? {
        if let sel = model.selection, let found = model.stickers.first(where: { $0.id == sel }) {
            return found
        }
        if let itemID = model.selectedItem,
           let item = model.doc.items.first(where: { $0.id == itemID }) {
            return Sticker(url: item.url)
        }
        return model.stickers.first
    }

    var body: some View {
        if let sticker {
            let count = model.sheetCount(for: sticker)
            VStack(alignment: .leading, spacing: 14) {
                // Dark-blue (#3366aa) border preview — uses cached 900px canvasImage directly (0 ms)
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 10).fill(darkCheck)
                    if let img = model.canvasImages[sticker.url] ?? model.thumbnails[sticker.url] {
                        Image(nsImage: img)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(14)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Text("Dark check")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.32)))
                        .padding(7)
                }
                .frame(height: 195)
                .help("Shown on the playbook's dark check colour (#3366aa) so the white border is visible")

                VStack(alignment: .leading, spacing: 4) {
                    Text(sticker.name.replacingOccurrences(of: " Sticker", with: ""))
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if let r = model.reports[sticker.url] {
                        Text("\(r.width)×\(r.height) px · \(r.cutLoops) cut loop\(r.cutLoops == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        model.add(sticker.url)
                    } label: {
                        Label(count > 0 ? "Add Another (\(count))" : "Add to Sheet", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    if count > 0 {
                        Button(role: .destructive) {
                            model.removeAllFromSheet(sticker)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .help("Remove all copies from sheet")
                    }
                }

                // Smart playbook checks: highlight warnings/errors, fold passing checks
                if let report = model.reports[sticker.url] {
                    let issues = report.checks.filter { $0.level >= .warn }
                    let passed = report.checks.filter { $0.level < .warn }

                    if issues.isEmpty {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("Ready to print")
                                            .font(.callout.weight(.semibold))
                                        Text("All \(report.checks.count) playbook checks passed.")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                DisclosureGroup("View details", isExpanded: $showPassingDetails) {
                                    VStack(alignment: .leading, spacing: 8) {
                                        ForEach(report.checks) { check in
                                            CheckDetailRow(check: check)
                                        }
                                        Divider()
                                        Text("Sharpening can't be measured from the file — check it by eye in print.")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.top, 6)
                                }
                                .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(issues) { check in
                                    CheckDetailRow(check: check)
                                }
                                if !passed.isEmpty {
                                    Divider()
                                    DisclosureGroup("\(passed.count) passing check\(passed.count == 1 ? "" : "s")",
                                                    isExpanded: $showPassingDetails) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ForEach(passed) { check in
                                                CheckDetailRow(check: check)
                                            }
                                        }
                                        .padding(.top, 6)
                                    }
                                    .font(.caption)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        } label: {
                            Label("\(issues.count) item\(issues.count == 1 ? "" : "s") to check",
                                  systemImage: report.overall.symbol)
                                .foregroundStyle(report.overall.color)
                        }
                    }
                } else {
                    GroupBox {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Running sticker checks…").font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .onChange(of: sticker.url) { _ in
                showPassingDetails = false
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("Select a sticker in the library to inspect its white border and cut checks.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        }
    }
}

private struct CheckDetailRow: View {
    let check: StickerReport.Check

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: check.level.symbol)
                .font(.caption)
                .foregroundStyle(check.level.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(check.title)
                    .font(.caption.weight(.semibold))
                Text(check.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - First-Run Setup Sheet

struct WelcomeSetupSheet: View {
    @EnvironmentObject var model: AppModel

    private var displayPath: String {
        (model.libraryPath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(darkCheck)
                    .frame(width: 64, height: 64)
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 6) {
                Text("Welcome to StickerSend")
                    .font(.title2.weight(.semibold))
                Text("Choose your default sticker folder. StickerSend loads PNG stickers from here and copies any files you drag into the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default folder")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color.accentColor)
                    Text(displayPath)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1), lineWidth: 1))
            }

            HStack(spacing: 10) {
                Button("Use Default Folder") {
                    model.completeSetup(useDefault: true)
                }
                .controlSize(.large)

                Button {
                    model.completeSetup(useDefault: false)
                } label: {
                    Label("Choose Sticker Folder…", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("You can change this anytime from the bottom of the sidebar or with ⇧⌘O.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(26)
        .frame(width: 440)
    }
}

/// Resolve dropped items to file URLs, then hand them over on the main actor.
func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
    let group = DispatchGroup()
    var urls = [URL?](repeating: nil, count: providers.count)
    let lock = NSLock()
    for (i, provider) in providers.enumerated()
    where provider.canLoadObject(ofClass: URL.self) || provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        group.enter()
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            lock.lock(); urls[i] = url; lock.unlock()
            group.leave()
        }
    }
    group.notify(queue: .main) {
        let found = urls.compactMap { $0 }.filter(\.isFileURL)
        MainActor.assumeIsolated { completion(found) }
    }
}
