import SwiftUI
import AnnotationModel

// MARK: - Crop action bar

struct CropActionBar: View {
    @Bindable var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                TextField("W", value: $controller.pendingFrameWidth, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Text("×")
                    .foregroundStyle(MiroTheme.textSecondary(scheme))
                TextField("H", value: $controller.pendingFrameHeight, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
            }
            .font(.miroControl)
            .help("The new image size in pixels; a size keeps the frame's top-left corner")
            MiroPrimaryButton(title: controller.pendingFrameExpands ? "Apply Resize" : "Apply Crop") {
                controller.applyCrop()
            }
                .help("Apply the frame (Return): inside the image it crops, outside it grows the canvas")
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

/// Bottom-right toggle for the address grid, highlighted while it shows.
/// Same action as View ▸ Show Grid (⌘G).
struct GridToggleButton: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button {
            controller.showsGrid.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "grid")
                    .font(.system(size: 11, weight: .semibold))
                if let doc = controller.document {
                    Text("\(doc.grid.columns)\u{00D7}\(doc.grid.rows)")
                        .font(.miroCaption)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(controller.showsGrid ? Color.miroInk : MiroTheme.textSecondary(scheme))
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(controller.showsGrid ? Color.miroYellow : .clear)
                    .padding(-4)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
        .miroFloatingPanel()
        .help(controller.showsGrid ? "Hide Grid (\u{2318}G)" : "Show Grid (\u{2318}G)")
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
