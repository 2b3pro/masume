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
            CanvasPane(controller: workspace.active)
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
                    isActive: tab === workspace.active,
                    select: { workspace.activate(tab) },
                    close: { workspace.close(tab) }
                )
                Rectangle().fill(Color.miroDivider).frame(width: 1)
            }
            Button { workspace.newTab() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(MiroTheme.textSecondary(scheme))
                    .frame(width: 34, height: Self.barHeight)
                    .contentShape(.rect)
            }
            .buttonStyle(MiroTileButtonStyle())
            .help("New Tab (⌘T)")
        }
        .frame(height: Self.barHeight)
        .background(MiroTheme.surface(scheme))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.miroDivider).frame(height: 1)
        }
    }
}

private struct TabItem: View {
    let title: String
    let isActive: Bool
    let select: () -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var backgroundColor: Color {
        if isActive {
            MiroTheme.board(scheme)
        } else if hovering {
            Color.miroSurfacePressed.opacity(scheme == .dark ? 0.3 : 1)
        } else {
            .clear
        }
    }

    var body: some View {
        Text(title)
            .font(.miroCaption)
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(isActive ? MiroTheme.textPrimary(scheme)
                                      : MiroTheme.textSecondary(scheme))
            .padding(.horizontal, 28) // symmetric room for the close button
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor)
            .overlay(alignment: .leading) {
                if hovering || isActive {
                    Button(action: close) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(MiroTheme.textSecondary(scheme))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect(cornerRadius: 5))
                    }
                    .buttonStyle(MiroTileButtonStyle())
                    .padding(.leading, 6)
                    .help("Close Tab (⌘W)")
                }
            }
            .contentShape(.rect)
            .onTapGesture(perform: select)
            .onHover { hovering = $0 }
            .help(title)
    }
}

/// One tab's content: board + grid + canvas/empty state plus all floating
/// overlays, all bound to that tab's controller.
private struct CanvasPane: View {
    var controller: CanvasController
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
            MiroTheme.board(scheme)
            MiroGrid(color: MiroTheme.grid(scheme))
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
        // a drop replaces the image.
        .dropDestination(for: DroppedImage.self) { items, _ in
            controller.loadDroppedImage(items)
        }
        .overlay(alignment: .leading) {
            if controller.hasDocument {
                ToolPalette(controller: controller)
                    .padding(.leading, 16)
            }
        }
        .overlay(alignment: .topTrailing) {
            if controller.hasDocument {
                ActionBar(controller: controller)
                    .padding(16)
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
                .foregroundStyle(MiroTheme.textPrimary(scheme))
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
                .foregroundStyle(MiroTheme.textSecondary(scheme))
            Text("Open or drop an image to start annotating")
                .font(.miroBody)
                .foregroundStyle(MiroTheme.textSecondary(scheme))
            HStack(spacing: 12) {
                MiroPrimaryButton(title: "Open Image…") { ExportService.openPanel(controller) }
                MiroSecondaryButton(title: "Paste from Clipboard") { ExportService.confirmAndPasteImage(controller) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Icon tiles

/// Shared icon-in-tile label used by the palette and action-bar buttons; the
/// content shape matches `MiroTileButtonStyle`'s 11pt hover/pressed fill.
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

    private var palette: some View {
        let editsPixelate = controller.sliderEditsPixelateAmount
        let sliderSymbol = editsPixelate ? Tool.pixelate.symbol : "lineweight"
        return VStack(spacing: 4) {
            ForEach(Tool.allCases) { tool in
                Button {
                    if reduceMotion {
                        controller.tool = tool
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) { controller.tool = tool }
                    }
                } label: {
                    tileIcon(tool.symbol,
                             tint: controller.tool == tool ? Color.miroInk : MiroTheme.textSecondary(scheme))
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(controller.tool == tool ? Color.miroYellow : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help("\(tool.label) (\(String(tool.shortcutKey).uppercased()))")
                .keyboardShortcut(.none)
                .anchorPreference(key: StampRowAnchor.self, value: .bounds) { tool == .stamp ? $0 : nil }
            }

            paletteDivider(width: 28, verticalPadding: 4)

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
            .buttonStyle(MiroTileButtonStyle())
            .help("Stroke color")

            Button {
                showsStrokeWidth.toggle()
            } label: {
                tileIcon(sliderSymbol, tint: MiroTheme.textSecondary(scheme))
            }
            .buttonStyle(MiroTileButtonStyle())
            .help(editsPixelate ? "Pixel size" : "Stroke width")
            .popover(isPresented: $showsStrokeWidth, arrowEdge: .trailing) {
                HStack(spacing: 8) {
                    Image(systemName: sliderSymbol)
                        .foregroundStyle(MiroTheme.textSecondary(scheme))
                    MiroSlider(
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
                    tileIcon("circle.lefthalf.filled", tint: MiroTheme.textSecondary(scheme))
                }
                .buttonStyle(MiroTileButtonStyle())
                .help("Opacity (lower for highlighting)")
                .popover(isPresented: $showsPenOpacity, arrowEdge: .trailing) {
                    HStack(spacing: 8) {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(MiroTheme.textSecondary(scheme))
                        MiroSlider(
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
                            .foregroundStyle(MiroTheme.textSecondary(scheme))
                            .frame(width: 36, alignment: .trailing)
                    }
                    .padding(12)
                }
            }

            if controller.editsTextStyle {
                Button {
                    showsTextStyle.toggle()
                } label: {
                    tileIcon(controller.textStyle.symbol, tint: MiroTheme.textSecondary(scheme))
                }
                .buttonStyle(MiroTileButtonStyle())
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

        }
        .miroFloatingPanel()
        // Glyph flyout beside the Stamp tool row whenever a stamp glyph is
        // editable. The row's bounds arrive as an anchor preference, resolved
        // in this same layout pass, so the flyout tracks the row exactly.
        .overlayPreferenceValue(StampRowAnchor.self) { anchor in
            GeometryReader { proxy in
                if let anchor, controller.editsStampKind {
                    let row = proxy[anchor]
                    StampKindPanel(controller: controller)
                        .miroFloatingPanel()
                        // Both panels pad their tiles by 8, so top-aligning
                        // the flyout 8 above the row lines the tiles up.
                        .offset(x: proxy.size.width + 8, y: row.minY - 8)
                        .transition(.scale(scale: 0.95, anchor: .leading).combined(with: .opacity))
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: controller.editsStampKind)
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
            tileIcon(symbol, tint: MiroTheme.textSecondary(scheme), iconSize: 16, tile: 36)
        }
        .buttonStyle(MiroTileButtonStyle())
        .help(help)
        .disabled(!controller.hasDocument)
    }
}

// MARK: - Crop action bar

struct CropActionBar: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            MiroPrimaryButton(title: "Apply Crop") { controller.applyCrop() }
                .help("Apply the crop (Return)")
            Button("Cancel") { controller.cancelCrop() }
                .buttonStyle(.plain)
                .font(.miroControl)
                .foregroundStyle(MiroTheme.textSecondary(scheme))
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .help("Cancel the crop (Esc)")
        }
        .miroFloatingPanel()
        .transition(.opacity)
    }
}

/// Preview-style zoom control next to the size badge: shows the live effective
/// percentage (fit mode included) and pulls down the preset levels.
struct ZoomMenuButton: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Menu {
            ForEach(ZoomMath.presets, id: \.self) { preset in
                Button(ZoomMath.percentLabel(for: preset)) { controller.setZoom(preset) }
            }
            Divider()
            Button("Fit to Window") { controller.zoomToFit() }
        } label: {
            HStack(spacing: 3) {
                Text(controller.zoomPercentText)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.miroCaption)
            .foregroundStyle(MiroTheme.textSecondary(scheme))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .miroFloatingPanel()
        .help("Zoom")
    }
}

/// Bottom-right badge showing the exported image size in pixels; during a
/// pending crop it also shows the original size in parentheses.
struct ImageSizeBadge: View {
    var document: Document
    var exportBounds: ExportBounds
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Text(label)
            .font(.miroCaption)
            .foregroundStyle(MiroTheme.textSecondary(scheme))
            .miroFloatingPanel()
    }

    private var label: String {
        let out = document.outputRect(for: exportBounds).integral
        let size = "\(Int(out.width)) × \(Int(out.height))"
        guard document.crop != nil else { return size }
        let w = Int(document.canvasSize.width)
        let h = Int(document.canvasSize.height)
        return "\(size) (\(w) × \(h))"
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

final class DragOutView: NSView, NSFilePromiseProviderDelegate, NSDraggingSource {
    weak var controller: CanvasController?
    nonisolated(unsafe) private var pendingData: Data?
    private let ioQueue = OperationQueue()

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
        pendingData = data
        let provider = NSFilePromiseProvider(fileType: UTType.png.identifier, delegate: self)
        let item = NSDraggingItem(pasteboardWriter: provider)
        let preview = NSImage(data: data) ?? NSImage()
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    // NSFilePromiseProviderDelegate
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        let base = controller?.sourceURL?.deletingPathExtension().lastPathComponent ?? "annotated"
        return "\(base).png"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        do {
            if let data = pendingData { try data.write(to: url) }
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { ioQueue }
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
