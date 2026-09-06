import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AnnotationModel

// MARK: - Color bridging

extension Color {
    init(_ c: RGBAColor) {
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}

func rgbaColor(from color: Color) -> RGBAColor {
    let ns = NSColor(color).usingColorSpace(.sRGB) ?? .red
    return RGBAColor(r: Double(ns.redComponent), g: Double(ns.greenComponent),
                     b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
}

// MARK: - Content

struct ContentView: View {
    var workspace: WorkspaceController

    var body: some View {
        VStack(spacing: 0) {
            TabBarView(workspace: workspace)
            CanvasPane(controller: workspace.active, openInNewTab: { workspace.openDroppedInNewTab($0) })
                // Fresh view tree per tab: resets CanvasNSView pan/drag state,
                // the inline text editor, and transient popover @State.
                .id(workspace.active.id)
        }
    }
}

// MARK: - Tab bar

struct TabBarView: View {
    var workspace: WorkspaceController
    @Environment(\.colorScheme) private var scheme

    private static let barHeight: CGFloat = 30

    var body: some View {
        HStack(spacing: 0) {
            ForEach(workspace.tabs) { tab in
                TabItem(
                    title: WorkspaceController.title(for: tab),
                    isDirty: tab.isDirty,
                    isActive: tab === workspace.active,
                    canRename: tab.hasDocument,
                    select: { workspace.activate(tab) },
                    close: { workspace.close(tab) },
                    closeAll: { workspace.closeAll() },
                    rename: { workspace.rename(tab, to: $0) }
                )
                Rectangle().fill(Color.miroDivider).frame(width: 1)
            }
            Button { workspace.newTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary(scheme))
                    .frame(width: 34, height: Self.barHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(TileButtonStyle())
            .help("New Tab (⌘T)")
        }
        .frame(height: Self.barHeight)
        .background(Theme.surface(scheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.miroDivider).frame(height: 1)
        }
    }
}

/// One tab: title with an unsaved dot, a close button on hover, tap to
/// select, and press-and-hold on the title to rename it in place.
private struct TabItem: View {
    let title: String
    let isDirty: Bool
    let isActive: Bool
    let canRename: Bool
    let select: () -> Void
    let close: () -> Void
    /// Option-click on the close button: every tab, each brought to the
    /// front for its own Save prompt.
    let closeAll: () -> Void
    let rename: (String) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var backgroundColor: Color {
        if isActive {
            Theme.board(scheme)
        } else if hovering {
            Color.miroSurfacePressed.opacity(scheme == .dark ? 0.3 : 1)
        } else {
            .clear
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            if isDirty {
                Circle()
                    .fill(Color.miroBlue)
                    .frame(width: 6, height: 6)
                    .help("Unsaved changes")
            }
            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.miroCaption)
        .foregroundStyle(isActive ? Theme.textPrimary(scheme) : Theme.textSecondary(scheme))
    }

    private var editor: some View {
        TextField("Name", text: $draft)
            .textFieldStyle(.plain)
            .font(.miroCaption)
            .focused($fieldFocused)
            .onSubmit { commit() }
            .onExitCommand { editing = false }
            .onChange(of: fieldFocused) { _, focused in
                if !focused { commit() }
            }
    }

    private func beginEditing() {
        guard canRename else { return }
        draft = title
        editing = true
        fieldFocused = true
    }

    private func commit() {
        guard editing else { return }
        editing = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != title { rename(name) }
    }

    var body: some View {
        Group {
            if editing { editor } else { label }
        }
            .padding(.horizontal, 28) // symmetric room for the close button
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor)
            .overlay(alignment: .leading) {
                if hovering || isActive {
                    Button {
                        if NSEvent.modifierFlags.contains(.option) { closeAll() } else { close() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textSecondary(scheme))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect(cornerRadius: 5))
                    }
                    .buttonStyle(TileButtonStyle())
                    .padding(.leading, 6)
                    .help("Close Tab (\u{2318}W). \u{2325}-click closes all tabs.")
                }
            }
            .contentShape(.rect)
            .onTapGesture(perform: select)
            .gesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in beginEditing() })
            .onHover { hovering = $0 }
            .help(canRename ? "\(title). Press and hold to rename." : title)
    }
}

/// One tab's content: board + grid + canvas/empty state plus all floating
/// overlays, all bound to that tab's controller.
private struct CanvasPane: View {
    var controller: CanvasController
    /// Option-drop: open the payload in a new tab rather than on this one.
    var openInNewTab: ([DroppedImage]) -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // swiftlint:disable:next redundant_discardable_let
        let _ = controller.exportBounds
        // swiftlint:disable:next redundant_discardable_let
        let _ = controller.document
        // swiftlint:disable:next redundant_discardable_let
        let _ = controller.selection
        // swiftlint:disable:next redundant_discardable_let
        let _ = controller.baseImage
        ZStack {
            Theme.board(scheme)
            DotGrid(color: Theme.grid(scheme))
            if controller.hasDocument {
                CanvasView(controller: controller)
                    .padding(.leading, 76)
                    .padding(.trailing, 24)
                    .padding(.vertical, 24)
            } else {
                EmptyState(controller: controller)
            }
        }
        // Drop lives on the whole pane so it works before an image is loaded
        // (the empty state invites it) as well as over a loaded canvas, where
        // a drop adds a layer like paste does. Holding Option opens the drop
        // in a new tab instead.
        .dropDestination(for: DroppedImage.self) { items, _ in
            if NSEvent.modifierFlags.contains(.option) {
                openInNewTab(items)
                return true
            }
            return controller.loadDroppedImage(items)
        }
        .overlay(alignment: .leading) {
            if controller.hasDocument {
                ToolPalette(controller: controller)
                    .padding(.leading, 16)
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.hasDocument {
                VStack(alignment: .trailing, spacing: 8) {
                    ActionBar(controller: controller)
                    if controller.showsTranscription { TranscriptionPanel(controller: controller) }
                }.padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            if controller.document?.crop != nil {
                CropActionBar(controller: controller)
                    .padding(.bottom, 20)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let doc = controller.document {
                HStack(spacing: 8) {
                    Button { controller.showsTranscription.toggle() } label: {
                        Label("Find Text", systemImage: "text.viewfinder")
                    }
                    .help("Find text and transcribe the image or zone")
                    GridToggleButton(controller: controller)
                    ZoomMenuButton(controller: controller)
                    ImageSizeBadge(document: doc, exportBounds: controller.exportBounds)
                }
                .padding(16)
            }
        }
        .overlay(alignment: .bottom) {
            if let message = controller.toastMessage {
                ToastView(message: message)
                    .padding(.bottom, 24)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: controller.document?.crop != nil)
        .animation(.easeOut(duration: 0.18), value: controller.toastMessage)
        // Multi-page PDF import: pick the page to rasterize.
        .sheet(item: Binding(get: { controller.pendingPDF }, set: { controller.pendingPDF = $0 })) { source in
            PDFPagePicker(source: source,
                          choose: { controller.choosePDFPage($0, from: source) },
                          cancel: { controller.cancelPDFImport() })
        }
    }
}

/// Bottom-center confirmation toast; purely informational, so it never
/// intercepts clicks meant for the canvas below.
struct ToastView: View {
    let message: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.miroSuccess)
            Text(message)
                .font(.miroControl)
                .foregroundStyle(Theme.textPrimary(scheme))
        }
        .padding(.vertical, 10).padding(.horizontal, 16)
        .miroFloatingPanel(shape: Capsule())
        .allowsHitTesting(false)
    }
}

struct EmptyState: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56))
                .foregroundStyle(Theme.textSecondary(scheme))
            Text("Open or drop an image to start annotating")
                .font(.miroBody)
                .foregroundStyle(Theme.textSecondary(scheme))
            HStack(spacing: 12) {
                PrimaryButton(title: "Open Image…") { SaveService.openPanel(into: controller) }
                SecondaryButton(title: "Paste from Clipboard") { ExportService.confirmAndPasteImage(controller) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Icon tiles

/// Shared icon-in-tile label used by the palette and action-bar buttons; the
/// content shape matches `TileButtonStyle`'s 11pt hover/pressed fill.
func tileIcon(_ symbol: String, tint: Color,
              iconSize: CGFloat = 20, tile: CGFloat = 40) -> some View {
    Image(systemName: symbol)
        .font(.system(size: iconSize, weight: .medium))
        .foregroundStyle(tint)
        .frame(width: tile, height: tile)
        .contentShape(.rect(cornerRadius: 11))
}

/// Horizontal hairline separating groups inside a floating panel.
func paletteDivider(width: CGFloat, verticalPadding: CGFloat) -> some View {
    Rectangle()
        .fill(Color.miroDivider)
        .frame(width: width, height: 1)
        .padding(.vertical, verticalPadding)
}

// MARK: - Floating tool palette

struct ToolPalette: View {
    @Bindable var controller: CanvasController
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsStrokeWidth = false
    @State private var showsColorPresets = false
    @State private var showsTextStyle = false
    @State private var showsTextLayout = false
    @State private var showsImageLayer = false
    @State private var showsPenOpacity = false

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            palette
            if showsColorPresets {
                ColorPresetPanel(controller: controller)
                    .miroFloatingPanel()
                    .transition(.scale(scale: 0.95, anchor: .leading).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: showsColorPresets)
    }

    /// One tool button. Split out of `palette` so the type checker can cope
    /// with the accessory chain below it. Picking the active one-shot tool
    /// again locks it, shown by a "+" badge: it keeps creating instead of
    /// handing back to Select after each placement.
    private func toolTile(_ tool: Tool) -> some View {
        let locked = controller.isLocked(tool)
        return Button {
            if reduceMotion {
                controller.selectTool(tool)
            } else {
                withAnimation(.easeOut(duration: 0.12)) { controller.selectTool(tool) }
            }
        } label: {
            tileIcon(tool.symbol,
                     tint: controller.tool == tool ? Color.miroInk : Theme.textSecondary(scheme))
                .background(
                    RoundedRectangle(cornerRadius: 11)
                        .fill(controller.tool == tool ? Color.miroYellow : .clear)
                )
                .overlay(alignment: .bottomTrailing) {
                    if locked {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.miroInk)
                            .offset(x: -4, y: -4)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(toolHelp(tool, locked: locked))
        .keyboardShortcut(.none)
    }

    private func toolHelp(_ tool: Tool, locked: Bool) -> String {
        let name = "\(tool.label) (\(String(tool.shortcutKey).uppercased()))"
        guard tool.isOneShot else { return name }
        return locked ? "\(name). Locked: keeps creating. Click again to unlock."
                      : "\(name). Click again to lock it for repeated use."
    }

    private var palette: some View {
        let editsPixelate = controller.sliderEditsPixelateAmount
        let editsTextSize = controller.sliderEditsTextSize
        // The one slider drives stroke width, pixel size, or font size; its
        // icon and label say which.
        let sliderSymbol = editsPixelate ? Tool.pixelate.symbol : (editsTextSize ? "textformat.size" : "lineweight")
        let sliderHelp = editsPixelate ? "Pixel size" : (editsTextSize ? "Font size" : "Stroke width")
        return VStack(spacing: 4) {
            ForEach(Tool.allCases) { tool in
                toolTile(tool)
                    .anchorPreference(key: ToolRowAnchors.self, value: .bounds) { [tool: $0] }
            }

            paletteDivider(width: 28, verticalPadding: 4)

            Button { controller.setShadow(!controller.displayedShadow) } label: {
                tileIcon("shadow", tint: controller.displayedShadow ? Color.miroInk : Theme.textSecondary(scheme))
            }
            .buttonStyle(TileButtonStyle())
            .help("Shadow: selected object and default for new annotations")
            .accessibilityLabel("Toggle annotation shadow")

            Button {
                showsColorPresets.toggle()
            } label: {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(controller.strokeColor))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.miroDivider, lineWidth: 1))
                    .frame(width: 22, height: 22)
                    .frame(width: 40, height: 40)
                    .contentShape(.rect(cornerRadius: 11))
            }
            .buttonStyle(TileButtonStyle())
            .help("Stroke color")

            Button {
                showsStrokeWidth.toggle()
            } label: {
                tileIcon(sliderSymbol, tint: Theme.textSecondary(scheme))
            }
            .buttonStyle(TileButtonStyle())
            .help(sliderHelp)
            .popover(isPresented: $showsStrokeWidth, arrowEdge: .trailing) {
                HStack(spacing: 8) {
                    Image(systemName: sliderSymbol)
                        .foregroundStyle(Theme.textSecondary(scheme))
                    PanelSlider(
                        value: editsPixelate ? $controller.pixelateAmount : $controller.strokeWidth,
                        range: editsPixelate ? RedactionElement.amountRange : DefaultStrokeWidth.range,
                        onEditingChanged: { editing in
                            if editing { controller.beginInteraction() } else { controller.commitInteraction() }
                        },
                        width: 140
                    )
                }
                .padding(12)
            }

            if controller.editsPenOpacity {
                Button {
                    showsPenOpacity.toggle()
                } label: {
                    tileIcon("circle.lefthalf.filled", tint: Theme.textSecondary(scheme))
                }
                .buttonStyle(TileButtonStyle())
                .help("Opacity (lower for highlighting)")
                .popover(isPresented: $showsPenOpacity, arrowEdge: .trailing) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(Theme.textSecondary(scheme))
                        PanelSlider(
                            value: $controller.penOpacity,
                            range: PenElement.opacityRange,
                            onEditingChanged: { editing in
                                if editing { controller.beginInteraction() } else { controller.commitInteraction() }
                            },
                            width: 140
                        )
                        Text("\(Int((controller.penOpacity * 100).rounded()))%")
                            .font(.miroCaption)
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary(scheme))
                            .frame(width: 36, alignment: .trailing)
                    }
                    .padding(12)
                }
            }

            if controller.editsTextStyle {
                Button {
                    showsTextStyle.toggle()
                } label: {
                    tileIcon(controller.textStyle.symbol, tint: Theme.textSecondary(scheme))
                }
                .buttonStyle(TileButtonStyle())
                .help("Text style")
                .popover(isPresented: $showsTextStyle, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Text style", selection: $controller.textStyle) {
                            ForEach(TextStyle.allCases, id: \.self) { style in
                                Label(style.label, systemImage: style.symbol).tag(style)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                        if controller.textStyle != .plain {
                            TextOutlineColorRow(controller: controller)
                        }
                    }
                    .padding(12)
                }
            }

            if controller.editsImageLayer {
                Button {
                    showsImageLayer.toggle()
                } label: {
                    tileIcon("photo", tint: Theme.textSecondary(scheme))
                }
                .buttonStyle(TileButtonStyle())
                .help("Image layer: mask, border, shadow")
                .popover(isPresented: $showsImageLayer, arrowEdge: .trailing) {
                    ImageLayerPanel(controller: controller)
                        .padding(12)
                }
            }

            if controller.editsTextAlignment {
                Button {
                    showsTextLayout.toggle()
                } label: {
                    tileIcon(controller.textAlignment.symbol, tint: Theme.textSecondary(scheme))
                }
                .buttonStyle(TileButtonStyle())
                .help("Text alignment")
                .popover(isPresented: $showsTextLayout, arrowEdge: .trailing) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextAlignmentRow(controller: controller)
                        if controller.editsCalloutShape {
                            TextOutlineColorRow(controller: controller, label: "Ink")
                        }
                        if controller.selectionIsText {
                            BubbleRow(controller: controller)
                        }
                    }
                    .padding(12)
                }
            }

        }
        .miroFloatingPanel()
        // Flyout beside the row of whichever tool has one showing (stamp
        // glyph, bubble shape, loupe shape). The rows' bounds arrive as an
        // anchor preference, resolved in this same layout pass, so the flyout
        // tracks its row exactly.
        .overlayPreferenceValue(ToolRowAnchors.self) { anchors in
            GeometryReader { proxy in
                if let tool = controller.flyoutTool, let anchor = anchors[tool] {
                    let row = proxy[anchor]
                    ToolFlyout(controller: controller, tool: tool)
                        .miroFloatingPanel()
                        // Both panels pad their tiles by 8, so top-aligning
                        // the flyout 8 above the row lines the tiles up.
                        .offset(x: proxy.size.width + 8, y: row.minY - 8)
                        .transition(.scale(scale: 0.95, anchor: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: controller.flyoutTool)
    }
}

// MARK: - Floating action bar (share / copy / export)

struct ActionBar: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            DragOutWell(controller: controller)
                .frame(width: 32, height: 32)
                .help("Drag out to share as PNG")

            // Copy confirmation comes from the shared toast that
            // copyToClipboard flashes (it also covers ⌘C, which has no button).
            actionTile("doc.on.clipboard", help: "Copy image to clipboard") {
                ExportService.copyToClipboard(controller)
            }
            actionTile("square.and.arrow.down", help: "Export image") {
                ExportService.exportPanel(controller)
            }
        }
        .miroFloatingPanel()
    }

    private func actionTile(_ symbol: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            tileIcon(symbol, tint: Theme.textSecondary(scheme), iconSize: 16, tile: 36)
        }
        .buttonStyle(TileButtonStyle())
        .help(help)
        .disabled(!controller.hasDocument)
    }
}

// MARK: - Drag-out well (NSFilePromiseProvider)

struct DragOutWell: NSViewRepresentable {
    var controller: CanvasController

    func makeNSView(context: Context) -> DragOutView {
        let v = DragOutView()
        v.controller = controller
        return v
    }
    func updateNSView(_ nsView: DragOutView, context: Context) {
        nsView.controller = controller
    }
}

final class DragOutView: NSView, NSDraggingSource {
    weak var controller: CanvasController?
    private let promiseWriter = DragOutPromiseWriter()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let enabled = controller?.hasDocument ?? false
        let symbol = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        symbol?.isTemplate = true
        NSColor.secondaryLabelColor.withAlphaComponent(enabled ? 1 : 0.3).set()
        if let tinted = symbol?.tinted(with: NSColor.secondaryLabelColor.withAlphaComponent(enabled ? 1 : 0.3)) {
            let r = NSRect(x: bounds.midX - 9, y: bounds.midY - 9, width: 18, height: 18)
            tinted.draw(in: r)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let controller, controller.hasDocument,
              let data = ExportService.pngData(controller) else { return }
        let base = controller.sourceURL?.deletingPathExtension().lastPathComponent ?? "annotated"
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: promiseWriter)
        provider.userInfo = DragOutPromise(data: data, fileName: "\(base).png")
        let item = NSDraggingItem(pasteboardWriter: provider)
        let preview = NSImage(data: data) ?? NSImage()
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Immutable state belongs to each provider, rather than to the view, so a
/// second drag cannot replace the bytes while the first promise is writing.
final class DragOutPromise: NSObject, @unchecked Sendable {
    let data: Data
    let fileName: String

    init(data: Data, fileName: String) {
        self.data = data
        self.fileName = fileName
    }
}

/// AppKit asks for the promise operation queue from a FileCoordination worker
/// on macOS 26, despite the SDK's UI-actor annotation. Keep this delegate off
/// the NSView and make the worker callbacks explicitly nonisolated.
final class DragOutPromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let ioQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.2b3pro.masume.drag-out"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? DragOutPromise)?.fileName ?? "annotated.png"
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                                         writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        do {
            guard let promise = filePromiseProvider.userInfo as? DragOutPromise else {
                throw CocoaError(.fileNoSuchFile)
            }
            try promise.data.write(to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { ioQueue }
}

extension NSImage {
    func tinted(with color: NSColor) -> NSImage {
        let image = self.copy() as! NSImage
        image.lockFocus()
        color.set()
        NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
