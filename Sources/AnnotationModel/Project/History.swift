import Foundation
import CoreGraphics

/// Who committed an action. `id` is stable ("human", an agent's id); `name`
/// is what the history panel prints.
public struct HistoryActor: Codable, Equatable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One committed action, as stored in `history.jsonl`. Carries enough to be
/// reversed from the file: the affected elements' full objects before and
/// after, and the crop when it changed.
public struct HistoryEntry: Codable, Equatable, Sendable {
    public var id: UUID
    public var actor: HistoryActor
    public var timestamp: Date
    public var revisionBefore: Int
    public var revisionAfter: Int
    /// The history panel's sentence, e.g. "Ian added arrow 4F2A".
    public var summary: String
    public var affected: [ElementID]
    /// Affected elements as they were, in their old order (deleted and changed).
    public var before: [Annotation]
    /// Affected elements as they are, in their new order (added and changed).
    public var after: [Annotation]
    public var cropChanged: Bool
    public var cropBefore: CGRect?
    public var cropAfter: CGRect?

    public init(id: UUID = UUID(), actor: HistoryActor, timestamp: Date, revisionBefore: Int, revisionAfter: Int,
                summary: String, affected: [ElementID], before: [Annotation], after: [Annotation],
                cropChanged: Bool, cropBefore: CGRect?, cropAfter: CGRect?) {
        self.id = id; self.actor = actor; self.timestamp = Dates.rounded(timestamp)
        self.revisionBefore = revisionBefore; self.revisionAfter = revisionAfter
        self.summary = summary; self.affected = affected; self.before = before; self.after = after
        self.cropChanged = cropChanged; self.cropBefore = cropBefore; self.cropAfter = cropAfter
    }

    /// The entry for the commit that turned `old` into `new`. An element is
    /// affected when it was added, deleted, changed, or moved in z-order.
    /// `summary` is generated unless `summaryOverride` is given (undo and
    /// redo name the action they reversed).
    public static func diff(from old: Document, to new: Document, actor: HistoryActor, revisionBefore: Int,
                            timestamp: Date = Date(), id: UUID = UUID(),
                            summaryOverride: String? = nil) -> HistoryEntry {
        let oldIndex = Dictionary(uniqueKeysWithValues: old.elements.enumerated().map { ($1.id, $0) })
        let newIndex = Dictionary(uniqueKeysWithValues: new.elements.enumerated().map { ($1.id, $0) })
        var deleted: [Annotation] = [], changed: [Annotation] = [], added: [Annotation] = []
        for element in old.elements {
            guard let i = newIndex[element.id] else { deleted.append(element); continue }
            if new.elements[i] != element || i != oldIndex[element.id] { changed.append(new.elements[i]) }
        }
        for element in new.elements where oldIndex[element.id] == nil { added.append(element) }
        let affectedSet = Set((deleted + changed + added).map(\.id))
        let cropChanged = old.crop != new.crop
        let cropChange: HistorySummary.CropChange? = cropChanged ? (new.crop == nil ? .cleared : .changed) : nil
        let summary = summaryOverride ?? HistorySummary.sentence(
            actor: actor, changed: changed, added: added, deleted: deleted, crop: cropChange)
        return HistoryEntry(
            id: id, actor: actor, timestamp: timestamp,
            revisionBefore: revisionBefore, revisionAfter: revisionBefore + 1,
            summary: summary,
            affected: old.elements.map(\.id).filter(affectedSet.contains)
                + added.map(\.id),
            before: old.elements.filter { affectedSet.contains($0.id) },
            after: new.elements.filter { affectedSet.contains($0.id) },
            cropChanged: cropChanged,
            cropBefore: cropChanged ? old.crop : nil,
            cropAfter: cropChanged ? new.crop : nil)
    }
}

/// Plain-words sentences for the history panel: "Ian added arrow 4F2A",
/// "Nova changed 3 elements", "Ian cleared the crop".
public enum HistorySummary {
    public enum CropChange { case changed, cleared }

    public static func sentence(actor: HistoryActor, changed: [Annotation], added: [Annotation], deleted: [Annotation],
                                crop: CropChange?) -> String {
        var parts: [String] = []
        if let part = phrase("changed", changed) { parts.append(part) }
        if let part = phrase("added", added) { parts.append(part) }
        if let part = phrase("deleted", deleted) { parts.append(part) }
        switch crop {
        case .changed?: parts.append("changed the crop")
        case .cleared?: parts.append("cleared the crop")
        case nil: break
        }
        guard !parts.isEmpty else { return "\(actor.name) made no change" }
        return "\(actor.name) \(join(parts))"
    }

    /// "added arrow 4F2A" for one element, "added 3 elements" for several.
    private static func phrase(_ verb: String, _ elements: [Annotation]) -> String? {
        switch elements.count {
        case 0: return nil
        case 1: return "\(verb) \(elements[0].kindName) \(shortID(elements[0].id))"
        default: return "\(verb) \(elements.count) elements"
        }
    }

    public static func shortID(_ id: ElementID) -> String {
        String(id.uuidString.prefix(4))
    }

    /// Oxford-comma list: "a", "a and b", "a, b, and c".
    private static func join(_ parts: [String]) -> String {
        switch parts.count {
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }
}

/// Stored dates keep millisecond precision, matching the file format.
public enum Dates {
    public static func rounded(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}

extension Annotation {
    /// The noun the history panel uses for this element.
    public var kindName: String {
        switch self {
        case .arrow: return "arrow"
        case .line: return "line"
        case .rectangle: return "rectangle"
        case .ellipse: return "ellipse"
        case .pen: return "pen stroke"
        case .text(let t): return t.isCallout ? "callout" : "text"
        case .stamp: return "stamp"
        case .pixelate: return "pixelation"
        case .magnifier: return "magnifier"
        }
    }
}
