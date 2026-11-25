import SwiftUI
import AppKit

// MARK: - Main Workspace (Center Sticker Canvas + Right Contextual Inspector)

struct SheetWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let showInspector: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SheetStageView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    Divider()
                    RightInspectorView()
                        .frame(width: 274)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Live job progress or error strip (only shown when active or an error occurs)
            if model.isPrinting || model.isBuilding || model.isArranging || model.showLog || hasRecentError {
                Divider()
                StatusAndLogBar()
            }
        }
    }

    private var hasRecentError: Bool {
        model.log.last?.isError == true
    }
}

// MARK: - Center Stage (Floating Canvas Bar + Sticker Window / Cut Preview)

struct SheetStageView: View {
    @EnvironmentObject var model: AppModel
    @State private var showBackgroundPopover = false

    var body: some View {
        VStack(spacing: 0) {
            // Subtle floating control strip above the sheet canvas
            if model.mode == .arrange {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Button { model.autoArrange() } label: {
                            Label("Auto-Arrange", systemImage: "square.grid.2x2")
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.doc.items.isEmpty || model.isArranging)
                        .help("Nest stickers tightly using their real shapes (⌥⌘A)")

                        Divider().frame(height: 14)

                        Menu {
                            Button("Biggest Possible") { model.fillBiggest() }
                                .disabled(model.doc.items.isEmpty)
                            Button("Most Copies") { model.fillCopies() }
                                .disabled(model.doc.items.isEmpty)
                            Divider()
                            Section("Pick Random Stickers") {
                                ForEach([2, 3, 4, 6, 8], id: \.self) { n in
                                    Button("\(n) random stickers") { model.pickRandom(n) }
                                }
                            }
                        } label: {
                            Label("Fill", systemImage: "rectangle.split.3x3")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(model.isArranging)
                        .help("Fill the sheet with larger stickers, more copies, or a random set")

                        Divider().frame(height: 14)

                        Button { showBackgroundPopover.toggle() } label: {
                            HStack(spacing: 4) {
                                BackgroundSwatchDot()
                                Text("Background")
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Set a printed sheet background colour or image (never cut)")
                        .popover(isPresented: $showBackgroundPopover, arrowEdge: .bottom) {
                            BackgroundPopover()
                                .environmentObject(model)
                        }

                        if model.canUndo {
                            Divider().frame(height: 14)
                            Button { model.undo() } label: {
                                Image(systemName: "arrow.uturn.backward")
                            }
                            .buttonStyle(.borderless)
                            .help("Undo (⌘Z)")
                        }
                    }
                    .font(.callout)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
                    Spacer(minLength: 0)
                }
                .padding(.top, 12)
                .padding(.horizontal, 14)
            }

            // Inline issue banner only when there's an overlap or cut blocker
            if !model.overlapping.isEmpty || !model.sheetBlockers.isEmpty {
                VStack(spacing: 4) {
                    if !model.overlapping.isEmpty {
                        Label(
                            "Red marks show cut lines closer than \(String(format: "%.1f", AppModel.cutClearanceMM)) mm — move overlapping stickers apart or tap Auto-Arrange.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    }
                    ForEach(model.sheetBlockers, id: \.self) { blocker in
                        Label(blocker, systemImage: "xmark.octagon.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(.top, 8)
                .padding(.horizontal, 16)
            }

            // The Sticker Window (Sheet Canvas) or Cut Preview
            Group {
                switch model.mode {
                case .arrange: SheetCanvas()
                case .preview: CutPreviewPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct BackgroundSwatchDot: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.doc.background?.path != nil {
                Image(systemName: "photo.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            } else if model.doc.background?.color != nil {
                Circle()
                    .fill(model.backgroundColor)
                    .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                    .frame(width: 12, height: 12)
            } else {
                Image(systemName: "checkerboard.rectangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Right Contextual Inspector (1 Clean Column)

struct RightInspectorView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                Group {
                    switch model.inspectorTab {
                    case .selected:
                        SelectedStickerInspector()
                    case .sheet:
                        SheetInspector()
                    case .check:
                        StickerCheckInspector()
                    }
                }
                .padding(14)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: Inspector Tab 1: Selected Sticker on Sheet

struct SelectedStickerInspector: View {
    @EnvironmentObject var model: AppModel

    var selected: PlacedItem? { model.doc.items.first { $0.id == model.selectedItem } }

    var body: some View {
        if let item = selected {
            let report = model.reports[item.url]
            let displayName = item.url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: " Sticker", with: "")

            VStack(alignment: .leading, spacing: 14) {
                // Header + clickable quality status pill
                HStack(alignment: .center, spacing: 8) {
                    Text(displayName)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if let level = report?.overall {
                        Button {
                            model.selection = item.url
                            model.inspectorTab = .check
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: level.symbol)
                                Text(level.label)
                            }
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(level.color.opacity(0.15)))
                            .foregroundStyle(level.color)
                        }
                        .buttonStyle(.plain)
                        .help("View dark-blue border preview & playbook checks")
                    }
                }

                // Transform: Size & Rotation
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Size").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.1f × %.1f mm", item.width, item.height))
                                .font(.callout.monospacedDigit())
                        }
                        Slider(
                            value: Binding(
                                get: { item.width },
                                set: { model.resize(item.id, width: $0) }
                            ),
                            in: 8...(SheetGeometry.printable.width),
                            onEditingChanged: { editing in
                                if editing { model.recordUndo() }
                            }
                        )

                        Divider()

                        HStack {
                            Text("Rotation").font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.0f°", item.angle))
                                .font(.callout.monospacedDigit())
                        }
                        HStack(spacing: 6) {
                            Button { model.rotate(item.id, by: -90) } label: {
                                Image(systemName: "rotate.left")
                            }
                            .help("Rotate 90° left (⌘[)")

                            Slider(
                                value: Binding(
                                    get: { item.angle },
                                    set: { model.rotate(item.id, to: $0.rounded()) }
                                ),
                                in: -180...180,
                                onEditingChanged: { editing in
                                    if editing { model.recordUndo() }
                                }
                            )

                            Button { model.rotate(item.id, by: 90) } label: {
                                Image(systemName: "rotate.right")
                            }
                            .help("Rotate 90° right (⌘])")
                        }
                    }
                    .padding(2)
                } label: {
                    Label("Transform", systemImage: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                // Outline (progressive disclosure: clean toggle when off)
                OutlineInspectorBox(item: item)

                // Quick Actions
                HStack(spacing: 6) {
                    Button { model.duplicate(item.id) } label: {
                        Image(systemName: "plus.square.on.square")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Duplicate (⌘D)")

                    Button { model.bringToFront(item.id) } label: {
                        Image(systemName: "square.3.layers.3d.top.filled")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Bring to front")

                    Button {
                        model.recordUndo()
                        let p = SheetGeometry.printable
                        model.move(item.id, to: CGPoint(x: p.midX - item.width / 2, y: item.y))
                    } label: {
                        Image(systemName: "align.horizontal.center")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Centre horizontally")

                    Button(role: .destructive) { model.remove(item.id) } label: {
                        Image(systemName: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Remove from sheet (⌫)")
                }
                .controlSize(.regular)

                // Shortcut to inspect border on dark blue
                Button {
                    model.selection = item.url
                    model.inspectorTab = .check
                } label: {
                    HStack {
                        Image(systemName: "eye")
                        Text("Inspect white border & checks")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "cursorarrow.click")
                    .font(.title)
                    .foregroundStyle(.tertiary)
                Text("No sticker selected")
                    .font(.headline)
                Text("Click any sticker on the sheet to resize, rotate, or add a decorative outline.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Sheet Settings") { model.inspectorTab = .sheet }
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 44)
        }
    }
}

struct OutlineInspectorBox: View {
    @EnvironmentObject var model: AppModel
    let item: PlacedItem

    var body: some View {
        let spec = model.outline(for: item.id)
        let isOn = spec.isActive

        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: Binding(
                    get: { isOn },
                    set: { enabled in
                        model.recordUndo()
                        if enabled {
                            var s = spec
                            if s.widthMM < 0.5 { s.widthMM = 2.0 }
                            model.setOutline(item.id, s)
                        } else {
                            model.setOutline(item.id, OutlineSpec(widthMM: 0, color: spec.color, fillGaps: false))
                        }
                    }
                )) {
                    HStack {
                        Text("Add Outline")
                            .font(.callout.weight(.medium))
                        Spacer()
                        if isOn && spec.widthMM > 0 {
                            Text(String(format: "+%.1f mm", spec.widthMM))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if isOn {
                    Divider()

                    HStack(spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { spec.widthMM },
                                set: { v in
                                    var s = spec
                                    s.widthMM = (v * 2).rounded() / 2
                                    model.setOutline(item.id, s)
                                }
                            ),
                            in: 0...6,
                            onEditingChanged: { editing in
                                if editing { model.recordUndo() }
                            }
                        )
                        ColorPicker(
                            "",
                            selection: Binding(
                                get: { AppModel.color(hex: spec.color) },
                                set: { c in
                                    var s = spec
                                    s.color = AppModel.hex(c) ?? s.color
                                    model.setOutline(item.id, s)
                                }
                            ),
                            supportsOpacity: false
                        )
                        .labelsHidden()
                        .help("Outline colour")
                    }

                    HStack {
                        Text("Style").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { spec.kind },
                            set: { newStyle in
                                model.recordUndo()
                                var s = spec
                                s.style = newStyle == .plain ? nil : newStyle
                                if s.widthMM < newStyle.minimumWidthMM { s.widthMM = newStyle.suggestedWidthMM }
                                model.setOutline(item.id, s)
                            }
                        )) {
                            ForEach(OutlineStyle.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }

                    if spec.kind != .plain {
                        Text(spec.kind.blurb)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if spec.widthMM < spec.kind.minimumWidthMM {
                            Label(
                                String(format: "Use at least %.1f mm for %@.", spec.kind.minimumWidthMM, spec.kind.label),
                                systemImage: "exclamationmark.triangle"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { spec.fillGaps },
                        set: { v in
                            model.recordUndo()
                            var s = spec
                            s.fillGaps = v
                            model.setOutline(item.id, s)
                        }
                    )) {
                        Text("Fill gaps (cut as one shape)").font(.caption)
                    }
                    .toggleStyle(.checkbox)
                    .help("Fills holes inside the sticker with the outline colour so the blade cuts one clean loop")

                    if model.doc.items.count > 1 {
                        Button("Apply Outline to All Stickers") {
                            model.applyOutlineToAll(spec)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                } else if let r = model.reports[item.url], r.cutLoops > 1 {
                    Divider()
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "scissors")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(r.cutLoops) cut loops detected.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Button("Fix: Fill Gaps") {
                                model.recordUndo()
                                var s = spec
                                s.fillGaps = true
                                model.setOutline(item.id, s)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            .padding(2)
        } label: {
            Label("Outline", systemImage: "circle.dashed")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Inspector Tab 2: Sheet Overview & Background

struct SheetInspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Stickers currently on the sheet
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    if model.doc.items.isEmpty {
                        Text("No stickers on this sheet yet. Click + in the library or drag stickers directly onto the sheet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(model.doc.items.reversed()) { item in
                            SheetItemRow(item: item)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(2)
            } label: {
                HStack {
                    Label("On Sheet (\(model.doc.items.count))", systemImage: "square.on.square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !model.doc.items.isEmpty {
                        Button("Clear") { model.clearSheet() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }

            // Sheet Background
            GroupBox {
                BackgroundControlsContent()
                    .padding(2)
            } label: {
                Label("Background", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            // Quick Fill / Layout actions
            GroupBox {
                VStack(spacing: 6) {
                    Button { model.autoArrange() } label: {
                        Label("Auto-Arrange", systemImage: "square.grid.2x2")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(model.doc.items.isEmpty || model.isArranging)

                    HStack(spacing: 6) {
                        Button("Biggest") { model.fillBiggest() }
                            .frame(maxWidth: .infinity)
                            .help("Scale stickers up together until the sheet is full")
                        Button("Most Copies") { model.fillCopies() }
                            .frame(maxWidth: .infinity)
                            .help("Fill the sheet with copies at current sizes")
                    }
                    .disabled(model.doc.items.isEmpty || model.isArranging)

                    if model.isArranging {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Arranging…").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(2)
            } label: {
                Label("Layout", systemImage: "rectangle.3.group")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SheetItemRow: View {
    @EnvironmentObject var model: AppModel
    let item: PlacedItem

    var body: some View {
        let isSelected = model.selectedItem == item.id
        let name = item.url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: " Sticker", with: "")

        HStack(spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(darkCheck)
                if let img = model.thumbnails[item.url] {
                    Image(nsImage: img).resizable().scaledToFit().padding(2)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                Text(String(format: "%.0f × %.0f mm", item.width, item.height))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 2)

            if model.overlapping.contains(item.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .help("Overlaps another sticker's cut line")
            }

            Button {
                model.remove(item.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from sheet")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.accentColor.opacity(0.2) : .clear))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedItem = item.id
            model.mode = .arrange
        }
    }
}

// MARK: - Background Controls (Shared by Inspector & Floating Canvas Popover)

struct BackgroundControlsContent: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ColorPicker(
                    "Colour",
                    selection: Binding(
                        get: { model.backgroundColor },
                        set: { model.backgroundColor = $0 }
                    ),
                    supportsOpacity: false
                )
                Spacer()
                if model.doc.background?.color != nil {
                    Button("Clear") { model.clearBackgroundColor() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }

            HStack {
                if let path = model.doc.background?.path {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text((path as NSString).lastPathComponent)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Remove") { model.clearBackgroundImage() }
                        .buttonStyle(.link)
                        .font(.caption)
                } else {
                    Button {
                        model.chooseBackgroundImage()
                    } label: {
                        Label("Choose Image…", systemImage: "photo")
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Text("Prints edge-to-edge behind stickers. Never cut.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct BackgroundPopover: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Sheet Background", systemImage: "lock.fill")
                .font(.headline)
            BackgroundControlsContent()
        }
        .padding(14)
        .frame(width: 240)
    }
}

// MARK: - Toolbar Popovers (Printer & Print)

struct PrinterPopover: View {
    @EnvironmentObject var model: AppModel
    @State private var showConnectionSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("StickerPix Print+Cut", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                if model.isQuerying {
                    ProgressView().controlSize(.small)
                }
            }

            if !model.printerSummary.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(model.printerSummary.prefix(8), id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("Make sure the StickerPix is awake, then check connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                model.queryStatus()
            } label: {
                HStack {
                    if model.isQuerying { ProgressView().controlSize(.small) }
                    Text("Check Printer")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(model.busy || model.binary == nil)

            if model.binary == nil {
                Label("cricut-bt binary not found. Run `./make-app.sh`.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            DisclosureGroup("Bluetooth Address", isExpanded: $showConnectionSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Auto-detect (or enter MAC)", text: $model.printerAddress)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                    Text("Leave blank to auto-detect your paired StickerPix, or enter its MAC address manually.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 6)
            }
            .font(.caption)

            HStack {
                Spacer()
                Button(model.showLog ? "Hide Activity Log" : "Show Activity Log") {
                    model.showLog.toggle()
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

struct PrintPopover: View {
    @EnvironmentObject var model: AppModel
    @Binding var showPopover: Bool
    @Binding var confirmPrint: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Print & Cut Sheet")
                .font(.headline)

            // Step 1: Preview status
            if model.isBuilding {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Building sheet & cut lines…").font(.callout)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            } else if model.previewImage != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Cut preview ready").font(.callout.weight(.medium))
                        if let n = model.sheetContours {
                            Text("\(n) cut contour\(n == 1 ? "" : "s") verified")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.mode != .preview {
                        Button("View") {
                            model.mode = .preview
                            showPopover = false
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .padding(8)
                .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Build the cut preview first so you can verify every magenta cut line before spending a cartridge sheet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button {
                        model.buildSheet()
                    } label: {
                        Label("Build & Preview Cuts", systemImage: "scissors")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.doc.items.isEmpty || model.busy)
                }
            }

            if !model.overlapping.isEmpty {
                Label("Some sticker cut lines overlap — check before printing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.sheetBlockers.isEmpty {
                Label("\(model.sheetBlockers.count) sticker check blocker(s) on this sheet.", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // Step 2: Copies & Send
            Stepper("Copies: \(model.doc.copies)", value: $model.doc.copies, in: 1...36)

            if model.isPrinting {
                VStack(alignment: .leading, spacing: 4) {
                    if let p = model.uploadProgress, p < 1 {
                        ProgressView(value: p)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(model.jobStage ?? "Sending to printer…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Button {
                    showPopover = false
                    confirmPrint = true
                } label: {
                    Label("Print & Cut \(model.doc.copies == 1 ? "1 Sheet" : "\(model.doc.copies) Sheets")…",
                          systemImage: "printer.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.previewImage == nil || model.busy)
                .help(model.previewImage == nil ? "Build the cut preview first" : "Send to StickerPix")
            }
        }
        .padding(14)
        .frame(width: 280)
    }
}

// MARK: - Sticker Window (Sheet Canvas)

struct SheetCanvas: View {
    @EnvironmentObject var model: AppModel
    /// The item as it was when a gesture began, so gestures are relative to it.
    @State private var gestureStart: PlacedItem?
    @State private var didMoveDuringDrag = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
            let paper = SheetGeometry.paper
            let s = min(geo.size.width / paper.width, geo.size.height / paper.height)
            let origin = CGPoint(x: (geo.size.width - paper.width * s) / 2, y: (geo.size.height - paper.height * s) / 2)
            // mm -> view points
            let toView = { (r: CGRect) -> CGRect in
                CGRect(x: origin.x + (r.minX - paper.minX) * s, y: origin.y + (r.minY - paper.minY) * s,
                       width: r.width * s, height: r.height * s)
            }
            let pointToView = { (p: CGPoint) -> CGPoint in
                CGPoint(x: origin.x + (p.x - paper.minX) * s, y: origin.y + (p.y - paper.minY) * s)
            }
            let paperRect = toView(paper)
            let printable = toView(SheetGeometry.printable)

            ZStack(alignment: .topLeading) {
                // Empty-canvas taps deselect.
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { model.selectedItem = nil }

                // Paper + locked background
                ZStack {
                    if model.doc.background == nil {
                        // No background: show transparency, so white sticker
                        // borders stand out. Prints on plain white paper.
                        Checkerboard()
                    } else {
                        Rectangle().fill(model.doc.background?.color != nil ? model.backgroundColor : .white)
                    }
                    if let bg = model.backgroundImage {
                        Image(nsImage: bg).resizable().interpolation(.high).scaledToFill()
                    }
                }
                .frame(width: paperRect.width, height: paperRect.height)
                .clipped()
                .shadow(color: .black.opacity(0.32), radius: 8, y: 3)
                .offset(x: paperRect.minX, y: paperRect.minY)
                .allowsHitTesting(false)

                // Printable safe area
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.gray.opacity(0.65))
                    .frame(width: printable.width, height: printable.height)
                    .offset(x: printable.minX, y: printable.minY)
                    .allowsHitTesting(false)

                // Empty sheet gentle prompt
                if model.doc.items.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "plus.square.dashed")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("Drop stickers here\nor click + in the library")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .position(x: paperRect.midX, y: paperRect.midY)
                    .allowsHitTesting(false)
                }

                // Stickers, back to front. Each is laid out in its unrotated
                // frame and turned about its centre, like the print.
                ForEach(model.doc.items) { item in
                    let preview = model.outlinePreview(for: item)
                    let grow = preview.map { Double($0.pad) * item.width / Double($0.sourceWidth) } ?? 0
                    let r = toView(item.rect.insetBy(dx: -grow, dy: -grow))
                    ZStack {
                        if let preview {
                            Image(nsImage: preview.image).resizable().interpolation(.high)
                        } else if let img = model.canvasImages[item.url] ?? model.thumbnails[item.url] {
                            Image(nsImage: img).resizable().interpolation(.high)
                        } else {
                            Rectangle().fill(Color.gray.opacity(0.3))
                        }
                        if model.selectedItem == item.id {
                            Rectangle().stroke(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                    .task(id: model.outlineKey(item)) { await model.renderOutlinePreview(item) }
                    .frame(width: r.width, height: r.height)
                    .contentShape(Rectangle())
                    .rotationEffect(.degrees(item.angle))
                    .offset(x: r.minX, y: r.minY)
                    .contextMenu {
                        Button("Duplicate") { model.duplicate(item.id) }
                        Button("Bring to Front") { model.bringToFront(item.id) }
                        Button("Centre Horizontally") {
                            model.recordUndo()
                            let p = SheetGeometry.printable
                            model.move(item.id, to: CGPoint(x: p.midX - item.width / 2, y: item.y))
                        }
                        Divider()
                        Button("Rotate Left 90°") { model.rotate(item.id, by: -90) }
                        Button("Rotate Right 90°") { model.rotate(item.id, by: 90) }
                        Divider()
                        Button("Inspect Border & Checks") {
                            model.selection = item.url
                            model.inspectorTab = .check
                        }
                        Button("Remove", role: .destructive) { model.remove(item.id) }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                            .onChanged { g in
                                if gestureStart == nil {
                                    gestureStart = item
                                    didMoveDuringDrag = false
                                    if model.selectedItem != item.id {
                                        model.selectedItem = item.id
                                    }
                                }
                                guard let start = gestureStart else { return }
                                if !didMoveDuringDrag {
                                    guard hypot(g.translation.width, g.translation.height) > 1.5 else { return }
                                    didMoveDuringDrag = true
                                    model.recordUndo()
                                }
                                model.move(item.id, to: CGPoint(x: start.x + g.translation.width / s,
                                                                y: start.y + g.translation.height / s))
                            }
                            .onEnded { _ in
                                gestureStart = nil
                                didMoveDuringDrag = false
                            }
                    )
                }

                // Where cut lines collide, marked on the real shapes.
                if let overlay = model.overlapImage {
                    let canvas = toView(CGRect(x: 0, y: 0, width: SheetGeometry.width, height: SheetGeometry.height))
                    Image(nsImage: overlay).resizable().interpolation(.none)
                        .frame(width: canvas.width, height: canvas.height)
                        .offset(x: canvas.minX, y: canvas.minY)
                        .allowsHitTesting(false)
                }

                // Handles for the selected sticker.
                if let item = model.doc.items.first(where: { $0.id == model.selectedItem }) {
                    let corner = pointToView(item.rotated(CGPoint(x: item.outerRect.maxX, y: item.outerRect.maxY)))
                    let topMid = item.rotated(CGPoint(x: item.center.x, y: item.outerRect.minY))
                    let a = item.angle * .pi / 180
                    let stalk = 22.0 / s   // 22 points, in mm
                    let knob = pointToView(CGPoint(x: topMid.x + stalk * sin(a), y: topMid.y - stalk * cos(a)))
                    let top = pointToView(topMid)

                    Path { p in p.move(to: top); p.addLine(to: knob) }
                        .stroke(Color.accentColor, lineWidth: 1.5)
                        .allowsHitTesting(false)

                    // Rotate handle
                    Circle()
                        .fill(Color.accentColor)
                        .overlay(Image(systemName: "arrow.clockwise").font(.system(size: 8, weight: .bold)).foregroundStyle(.white))
                        .frame(width: 16, height: 16)
                        .position(knob)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                                .onChanged { g in
                                    if gestureStart == nil {
                                        gestureStart = item
                                        model.recordUndo()
                                    }
                                    let c = pointToView(gestureStart?.center ?? item.center)
                                    var deg = atan2(g.location.y - c.y, g.location.x - c.x) * 180 / .pi + 90
                                    if NSEvent.modifierFlags.contains(.shift) {
                                        deg = (deg / 15).rounded() * 15
                                    } else if abs(deg - (deg / 90).rounded() * 90) < 3 {
                                        deg = (deg / 90).rounded() * 90
                                    } else {
                                        deg = deg.rounded()
                                    }
                                    model.rotate(item.id, to: deg)
                                }
                                .onEnded { _ in gestureStart = nil }
                        )
                        .help("Drag to rotate (⇧ snaps to 15°)")

                    // Resize handle
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: 14, height: 14)
                        .position(corner)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                                .onChanged { g in
                                    if gestureStart == nil {
                                        gestureStart = item
                                        model.recordUndo()
                                    }
                                    guard let start = gestureStart else { return }
                                    let c = pointToView(start.center)
                                    let startCorner = pointToView(start.rotated(CGPoint(x: start.outerRect.maxX, y: start.outerRect.maxY)))
                                    let d0 = hypot(startCorner.x - c.x, startCorner.y - c.y)
                                    let d1 = hypot(g.location.x - c.x, g.location.y - c.y)
                                    guard d0 > 0 else { return }
                                    model.resize(item.id, width: start.width * d1 / d0)
                                }
                                .onEnded { _ in gestureStart = nil }
                        )
                        .help("Drag to resize")
                }
            }
            .coordinateSpace(name: "canvas")
            // Drop PNGs from Finder, or stickers from the library, to place
            // them right where they land.
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers, location in
                let mm = CGPoint(x: (location.x - origin.x) / s + paper.minX,
                                 y: (location.y - origin.y) / s + paper.minY)
                loadFileURLs(providers) { model.dropOnSheet($0, at: mm) }
                return true
            }
            .overlay {
                if dropTargeted {
                    Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 5]))
                        .frame(width: paperRect.width, height: paperRect.height)
                        .position(x: paperRect.midX, y: paperRect.midY)
                        .allowsHitTesting(false)
                }
            }
            }

            Text(model.doc.background == nil
                 ? "96 × 170 mm · Dashed safe area · Prints on white"
                 : "96 × 170 mm · Dashed safe area")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// GPU-tiled transparent checkerboard (cached once as a 16×16 tile).
struct Checkerboard: View {
    private static let tile: NSImage = {
        let s = 8
        let size = s * 2
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: size, height: size).fill()
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(x: s, y: 0, width: s, height: s).fill()
        NSRect(x: 0, y: s, width: s, height: s).fill()
        img.unlockFocus()
        return img
    }()

    var body: some View {
        Image(nsImage: Self.tile)
            .resizable(resizingMode: .tile)
    }
}

// MARK: - Cut Preview Pane

struct CutPreviewPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                if let n = model.sheetContours {
                    Label("\(n) cut contour\(n == 1 ? "" : "s")", systemImage: "scissors")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.doc.items.isEmpty {
                    Button {
                        model.buildSheet()
                    } label: {
                        Label("Rebuild", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.busy)
                }
                if model.previewImage != nil {
                    Button("Show Files") { model.revealSheet() }
                        .buttonStyle(.link)
                        .font(.callout)
                }
            }

            ZStack {
                if model.isBuilding {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Generating sheet & cut lines…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let img = model.previewImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.32), radius: 8, y: 3)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "scissors")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text(model.doc.items.isEmpty
                             ? "Add stickers to the sheet to preview cuts"
                             : "Build the sheet to see where the blade will cut")
                            .foregroundStyle(.secondary)
                        if !model.doc.items.isEmpty {
                            Button("Build Cut Preview") { model.buildSheet() }
                                .buttonStyle(.borderedProminent)
                                .disabled(model.busy)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if model.previewImage != nil {
                Text("Magenta = blade path. Check every outline sits on its sticker's border, right way up.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Compact Status Bar & Optional Activity Log

struct StatusAndLogBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.isPrinting {
                    if let p = model.uploadProgress, p < 1 {
                        ProgressView(value: p).frame(width: 90)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.jobStage ?? "Printing…")
                        .font(.caption.weight(.medium))
                } else if model.isBuilding {
                    ProgressView().controlSize(.small)
                    Text("Building cut preview…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.isArranging {
                    ProgressView().controlSize(.small)
                    Text("Arranging stickers…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let last = model.log.last {
                    Image(systemName: last.isError ? "exclamationmark.circle.fill" : "terminal")
                        .font(.caption)
                        .foregroundStyle(last.isError ? Color.red : Color.secondary)
                    Text(last.text)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .foregroundStyle(last.isError ? Color.red : Color.secondary)
                }

                Spacer()

                Button {
                    model.showLog.toggle()
                } label: {
                    Text(model.showLog ? "Hide Log" : "Activity Log")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor))

            if model.showLog {
                Divider()
                LogView().frame(height: 120)
            }
        }
    }
}

struct LogView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.log) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.isError ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: model.log.count) { _ in
                if let last = model.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
