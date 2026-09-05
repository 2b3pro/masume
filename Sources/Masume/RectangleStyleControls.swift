import SwiftUI
import AnnotationModel

enum RectangleTreatment: String, Codable, CaseIterable, PaletteChoice {
    case outline, rounded, highlight
    var label: String {
        switch self {
        case .outline: return "Rectangle"
        case .rounded: return "Rounded rectangle"
        case .highlight: return "Rectangular highlight"
        }
    }
    var symbol: String {
        switch self {
        case .outline: return "rectangle"
        case .rounded: return "rectangle.roundedtop"
        case .highlight: return "rectangle.fill"
        }
    }
}

extension CanvasController {
    func newRectangle(in rect: CGRect) -> ShapeElement {
        var shape = ShapeElement(rect: rect, color: strokeColor, width: strokeWidth)
        if rectangleTreatment == .rounded { shape.cornerRadius = cornerRadius }
        if rectangleTreatment == .highlight { shape.highlightOpacity = highlightOpacity }
        return shape
    }

    var selectedRectangle: ShapeElement? {
        guard let id = selection, let element = document?.elements.first(where: { $0.id == id }),
              case .rectangle(let shape) = element else { return nil }
        return shape
    }

    var displayedRectangleTreatment: RectangleTreatment {
        guard let shape = selectedRectangle else { return rectangleTreatment }
        if shape.highlightOpacity != nil { return .highlight }
        return (shape.cornerRadius ?? 0) > 0 ? .rounded : .outline
    }

    func setRectangleTreatment(_ treatment: RectangleTreatment) {
        rectangleTreatment = treatment
        guard let id = selection, var shape = selectedRectangle else { return }
        shape.cornerRadius = treatment == .rounded ? max(1, cornerRadius) : 0
        shape.highlightOpacity = treatment == .highlight ? highlightOpacity : nil
        shape.shadow = treatment == .highlight ? false : shadowEnabled
        perform { $0.mutate(id) { $0 = .rectangle(shape) } }
    }

    func setRectangleRadius(_ radius: CGFloat) {
        cornerRadius = radius
        guard let id = selection, selectedRectangle != nil else { return }
        perform { $0.mutate(id) { $0.rectangleCornerRadius = radius } }
    }

    func setHighlightOpacity(_ opacity: CGFloat) {
        highlightOpacity = opacity
        guard let id = selection, selectedRectangle?.highlightOpacity != nil else { return }
        perform { $0.mutate(id) { $0.opacity = opacity } }
    }

    var displayedShadow: Bool {
        guard let id = selection, let element = document?.elements.first(where: { $0.id == id }) else { return shadowEnabled }
        return element.shadowEnabled ?? shadowEnabled
    }

    func setShadow(_ enabled: Bool) {
        shadowEnabled = enabled
        guard let id = selection else { return }
        perform { $0.mutate(id) { $0.shadowEnabled = enabled } }
    }
}

struct RectangleStyleControls: View {
    var controller: CanvasController
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ChoicePanel(choices: RectangleTreatment.allCases, selected: controller.displayedRectangleTreatment) {
                controller.setRectangleTreatment($0)
            }
            if controller.displayedRectangleTreatment == .rounded {
                HStack {
                    Text("Corner radius")
                    TextField("Pixels", value: Binding<Double>(
                        get: { Double(controller.selectedRectangle?.cornerRadius ?? controller.cornerRadius) },
                        set: { controller.setRectangleRadius(CGFloat(max(0, $0))) }), format: .number)
                        .frame(width: 65)
                        .accessibilityLabel("Corner radius in pixels")
                }
            }
            if controller.displayedRectangleTreatment == .highlight {
                HStack {
                    Text("Opacity")
                    Slider(value: Binding(
                        get: { controller.selectedRectangle?.highlightOpacity ?? controller.highlightOpacity },
                        set: { controller.setHighlightOpacity($0) }), in: 0...1)
                        .frame(width: 100)
                }
            }
        }
    }
}
