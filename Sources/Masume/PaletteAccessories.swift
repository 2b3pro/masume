import SwiftUI
import AnnotationModel

// Palette accessories split from UI.swift for file size: the tool-row
// flyouts (stamp glyph, bubble shape, loupe shape) and their anchor
// preference, the slider and color preset panel, the text rows, and the
// palette labels/symbols for the choice enums.

/// Bounds of the tool tiles that own a flyout (stamp glyph, bubble shape,
/// loupe shape), keyed by tool, so each flyout can sit beside its own row.
struct ToolRowAnchors: PreferenceKey {
    static let defaultValue: [Tool: Anchor<CGRect>] = [:]
    static func reduce(value: inout [Tool: Anchor<CGRect>], nextValue: () -> [Tool: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// A palette choice with a tooltip and an SF Symbol.
protocol PaletteChoice: Hashable {
    var label: String { get }
    var symbol: String { get }
}

/// Horizontal row of symbol tiles; the current choice is highlighted.
struct ChoicePanel<Choice: PaletteChoice>: View {
    let choices: [Choice]
    let selected: Choice
    var iconSize: CGFloat = 22
    let select: (Choice) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(choices, id: \.self) { choice in
                Button {
                    select(choice)
                } label: {
                    tileIcon(choice.symbol,
                             tint: selected == choice ? Color.miroInk : MiroTheme.textSecondary(scheme),
                             iconSize: iconSize)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(selected == choice ? Color.miroYellow : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(choice.label)
            }
        }
    }
}

/// The flyout beside a tool row: stamp glyphs, bubble shapes, or loupe shapes.
struct ToolFlyout: View {
    var controller: CanvasController
    let tool: Tool

    var body: some View {
        switch tool {
        case .stamp:
            HStack(spacing: 8) {
                ChoicePanel(choices: StampKind.allCases, selected: controller.stampKind) { controller.stampKind = $0 }
                if controller.stampKind == .emoji { EmojiField(controller: controller) }
            }
        case .callout:
            ChoicePanel(choices: CalloutShape.allCases, selected: controller.calloutShape) { controller.calloutShape = $0 }
        case .magnifier:
            ChoicePanel(choices: MagnifierShape.allCases, selected: controller.magnifierShape) { controller.magnifierShape = $0 }
        case .select:
            ChoicePanel(choices: ZoneShape.allCases, selected: controller.zoneShape) { controller.zoneShape = $0 }
        default:
            EmptyView()
        }
    }
}

extension StampKind: PaletteChoice {}
extension CalloutShape: PaletteChoice {}
extension MagnifierShape: PaletteChoice {
    var label: String {
        switch self {
        case .circle: return "Round loupe"
        case .square: return "Square loupe"
        }
    }

    var symbol: String {
        switch self {
        case .circle: return "circle"
        case .square: return "square"
        }
    }
}
extension LineAlignment: PaletteChoice {}
extension ZoneShape: PaletteChoice {
    var label: String {
        switch self {
        case .rectangle: return "Rectangular zone (drag on empty canvas)"
        case .ellipse: return "Elliptical zone (drag on empty canvas)"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: return "rectangle.dashed"
        case .ellipse: return "circle.dashed"
        }
    }
}
extension ImageMask: PaletteChoice {
    var label: String {
        switch self {
        case .rectangle: return "Rectangle"
        case .rounded: return "Rounded rectangle"
        case .circle: return "Circle"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .rounded: return "rectangle.roundedtop"
        case .circle: return "circle"
        }
    }
}

/// Mask, border, and shadow for the selected image layer.
struct ImageLayerPanel: View {
    @Bindable var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Mask")
                .font(.miroCaption)
                .foregroundStyle(MiroTheme.textSecondary(scheme))
            ChoicePanel(choices: ImageMask.allCases, selected: controller.imageMask, iconSize: 18) {
                controller.imageMask = $0
            }
            Toggle("Border (stroke color and width)", isOn: $controller.imageBorder)
                .font(.miroCaption)
            Toggle("Shadow", isOn: $controller.imageShadow)
                .font(.miroCaption)
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
        case .number: return "Number"
        case .letter: return "Letter"
        case .emoji: return "Emoji"
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
        case .number: return "number.circle.fill"
        case .letter: return "a.circle.fill"
        case .emoji: return "face.smiling.inverse"
        }
    }
}

/// The emoji an emoji stamp shows: a one-character field that keeps the
/// last character typed or pasted, and a button that opens the system
/// Character Viewer, which inserts into the focused field.
struct EmojiField: View {
    @Bindable var controller: CanvasController
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            TextField("", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 18))
                .multilineTextAlignment(.center)
                .frame(width: 44)
                .focused($focused)
                .onAppear { draft = controller.stampEmoji }
                .onChange(of: controller.stampEmoji) { _, emoji in if draft != emoji { draft = emoji } }
                .onChange(of: draft) { _, text in
                    guard let emoji = StampElement.normalizedEmoji(text) else { return }
                    if draft != emoji { draft = emoji }
                    if controller.stampEmoji != emoji { controller.stampEmoji = emoji }
                }
                .help("The emoji for new stamps (or the selected one); type or paste one")
            Button {
                focused = true
                NSApp.orderFrontCharacterPalette(nil)
            } label: {
                Image(systemName: "keyboard")
                    .font(.system(size: 14))
            }
            .buttonStyle(.plain)
            .help("Choose from Emoji & Symbols")
        }
    }
}

extension CalloutShape {
    var label: String {
        switch self {
        case .speech: return "Speech bubble"
        case .thought: return "Thought cloud"
        }
    }

    var symbol: String {
        switch self {
        case .speech: return "bubble.left.fill"
        case .thought: return "cloud.fill"
        }
    }
}

extension LineAlignment {
    var label: String {
        switch self {
        case .left: return "Align left"
        case .center: return "Center"
        case .right: return "Align right"
        }
    }

    var symbol: String {
        switch self {
        case .left: return "text.alignleft"
        case .center: return "text.aligncenter"
        case .right: return "text.alignright"
        }
    }
}

/// Left / center / right for the text and callout tools and the selected
/// text element.
struct TextAlignmentRow: View {
    var controller: CanvasController

    var body: some View {
        ChoicePanel(choices: LineAlignment.allCases, selected: controller.textAlignment, iconSize: 18) {
            controller.textAlignment = $0
        }
    }
}

/// None / speech / thought for the selected text element: wraps plain text
/// in a bubble or takes the bubble away.
struct BubbleRow: View {
    var controller: CanvasController
    @Environment(\.colorScheme) private var scheme

    private var choices: [(name: String, symbol: String, shape: CalloutShape?)] {
        [("No bubble", "textformat", nil)]
            + CalloutShape.allCases.map { ($0.label, $0.symbol, $0) }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("Bubble")
                .font(.miroCaption)
                .foregroundStyle(MiroTheme.textSecondary(scheme))
            ForEach(choices, id: \.name) { choice in
                Button {
                    controller.setSelectedBubble(choice.shape)
                } label: {
                    tileIcon(choice.symbol,
                             tint: controller.selectedBubble == choice.shape ? Color.miroInk : MiroTheme.textSecondary(scheme),
                             iconSize: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 11)
                                .fill(controller.selectedBubble == choice.shape ? Color.miroYellow : .clear)
                        )
                }
                .buttonStyle(.plain)
                .help(choice.name)
            }
        }
    }
}

/// White-or-black choice for the text halo/outline color, or a callout's
/// ink (border and text) when `label` says so.
struct TextOutlineColorRow: View {
    var controller: CanvasController
    var label: String?
    @Environment(\.colorScheme) private var scheme

    private static let choices: [(name: String, color: RGBAColor)] = [("White", .white), ("Black", .black)]

    var body: some View {
        HStack(spacing: 8) {
            Text(label ?? (controller.textStyle == .outline ? "Outline" : "Halo"))
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
