import SwiftUI
import AnnotationModel

// Palette accessories split from UI.swift for file size: the stamp glyph
// flyout and its anchor preference, the slider and color preset panel, the
// text halo/outline color row, and the palette labels/symbols for
// TextStyle and StampKind.

/// Bounds of the Stamp tool tile, published by the palette so the glyph
/// flyout can sit beside that row.
struct StampRowAnchor: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Horizontal row of the five stamp glyphs; the current one is highlighted.
struct StampKindPanel: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StampKind.allCases, id: \.self) { kind in
                Button {
                    controller.stampKind = kind
                } label: {
                    tileIcon(kind.symbol,
                             tint: controller.stampKind == kind ? Color.miroInk : MiroTheme.textSecondary(scheme),
                             iconSize: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(controller.stampKind == kind ? Color.miroYellow : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(kind.label)
            }
        }
    }
}

extension StampKind {
    var label: String {
        switch self {
        case .check: return "Check"
        case .cross: return "Cross"
        case .exclaim: return "Exclamation"
        case .question: return "Question"
        case .heart: return "Heart"
        }
    }

    /// SF Symbol standing in for the glyph in the palette.
    var symbol: String {
        switch self {
        case .check: return "checkmark.circle.fill"
        case .cross: return "xmark.circle.fill"
        case .exclaim: return "exclamationmark.circle.fill"
        case .question: return "questionmark.circle.fill"
        case .heart: return "heart.circle.fill"
        }
    }
}

/// White-or-black choice for the text halo/outline color.
struct TextOutlineColorRow: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    private static let choices: [(name: String, color: RGBAColor)] = [("White", .white), ("Black", .black)]

    var body: some View {
        HStack(spacing: 8) {
            Text(controller.textStyle == .outline ? "Outline" : "Halo")
                .font(.miroCaption)
                .foregroundStyle(MiroTheme.textSecondary(scheme))
            ForEach(Self.choices, id: \.name) { choice in
                Button {
                    controller.textOutlineColor = choice.color
                } label: {
                    Circle()
                        .fill(Color(choice.color))
                        .overlay(Circle().strokeBorder(Color.miroDivider, lineWidth: 1))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay {
                            if controller.textOutlineColor == choice.color {
                                Circle().strokeBorder(Color.miroBlue, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(choice.name)
            }
        }
    }
}

extension TextStyle {
    var label: String {
        switch self {
        case .shadow: return "Shadow"
        case .outline: return "Outline"
        case .plain: return "Plain"
        }
    }

    /// SF Symbol for the palette button and picker rows.
    var symbol: String {
        switch self {
        case .shadow: return "shadow"
        case .outline: return "a.square"
        case .plain: return "textformat"
        }
    }
}

/// Pure-SwiftUI slider. The native `Slider` wraps an NSSlider whose knob
/// renders in the inactive (dark) style inside a non-key popover window until
/// clicked; drawing our own knob keeps it white regardless of window key state.
struct MiroSlider: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let onEditingChanged: (Bool) -> Void
    let width: CGFloat
    private let knob: CGFloat = 16
    private let track: CGFloat = 4

    @State private var editing = false

    var body: some View {
        let span = range.upperBound - range.lowerBound
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let fraction = span > 0 ? (clamped - range.lowerBound) / span : 0
        let usable = width - knob

        ZStack(alignment: .leading) {
            Capsule().fill(Color.miroDivider).frame(height: track)
            Capsule().fill(Color.miroBlue)
                .frame(width: knob / 2 + fraction * usable, height: track)
            Circle().fill(.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                .frame(width: knob, height: knob)
                .offset(x: fraction * usable)
        }
        .frame(width: width, height: knob)
        .contentShape(.rect)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !editing { editing = true; onEditingChanged(true) }
                    let x = min(max(0, g.location.x - knob / 2), usable)
                    let f = usable > 0 ? x / usable : 0
                    value = range.lowerBound + f * span
                }
                .onEnded { _ in
                    editing = false
                    onEditingChanged(false)
                }
        )
    }
}

/// Vertical strip of preset swatches (Skitch-style) with the system color
/// picker at the bottom as the fine-grained fallback. Stays open across
/// selections and canvas work so colors can be switched while drawing;
/// the palette swatch button toggles it closed.
struct ColorPresetPanel: View {
    var controller: CanvasController

    /// Skitch-style stroke color presets, top-to-bottom.
    private static let presets: [(name: String, color: RGBAColor)] = [
        ("Red", .red), ("Orange", .orange), ("Yellow", .yellow), ("Green", .green),
        ("Blue", .blue), ("Pink", .pink), ("White", .white), ("Black", .black),
    ]

    private var colorBinding: Binding<Color> {
        Binding(get: { Color(controller.strokeColor) },
                set: { controller.strokeColor = rgbaColor(from: $0) })
    }

    var body: some View {
        VStack(spacing: 6) {
            ForEach(Self.presets, id: \.name) { preset in
                Button {
                    controller.selectStrokeColor(preset.color)
                } label: {
                    Circle()
                        .fill(Color(preset.color))
                        .overlay(Circle().strokeBorder(Color.miroDivider, lineWidth: 1))
                        .frame(width: 22, height: 22)
                        .padding(3)
                        .overlay {
                            if controller.strokeColor == preset.color {
                                Circle().strokeBorder(Color.miroBlue, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }

            paletteDivider(width: 22, verticalPadding: 2)

            ColorPicker("", selection: colorBinding, supportsOpacity: true)
                .labelsHidden()
                .help("Custom color…")
        }
        .padding(2)
    }
}
