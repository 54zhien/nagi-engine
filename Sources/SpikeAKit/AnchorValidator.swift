import Foundation

/// What the stored position came back as.
///
/// No `Codable`: this is an intermediate answer inside one call, not something
/// that gets persisted or reported. What reaches a report is `ReanchorResult`.
public enum AnchorValidation: Sendable, Hashable {
    case valid(NativePosition)
    case invalid
}

/// Answers one question: **does the stored position still point at the content
/// the anchor recorded?**
///
/// Not "can it be found again" — that is `ReanchorService`. ADR-0004 keeps the
/// two apart because they answer different questions, and Spike A measured that
/// they are different: 22 round trips, 16 producing candidates, 7 producing
/// none, with `quotation-repeated` in both lists.
public enum AnchorValidator {

    /// `async throws` because production has to materialise the unit before it
    /// can read text (ADR-0004's Consequences). This round is handed a
    /// materialised `Document`, so nothing here actually suspends — the
    /// boundary is stated now so that call sites are already correct the day a
    /// real store arrives.
    public static func validate(
        _ anchor: Anchor,
        in document: Document
    ) async throws -> AnchorValidation {
        // The fast path is not exempt from cancellation. It reads one unit
        // today and would materialise one in production, and a caller that has
        // cancelled should stop either way — a "quick" path that ignores it is
        // how a cancelled re-anchor still reports a result.
        try Task.checkCancellation()

        guard let position = anchor.position else { return .invalid }
        guard let unit = document.unit(withID: position.unitID) else { return .invalid }

        let exact = AnchorMatching.units(anchor.quote.exact)
        // An empty quote confirms nothing. `ReanchorService` reports that as
        // `emptyQuote` before reaching here; a direct call must not answer
        // `valid` on the strength of matching zero units at any offset.
        guard !exact.isEmpty else { return .invalid }

        guard position.utf16Offset >= 0 else { return .invalid }

        let text = AnchorMatching.units(unit.canonical.string)
        guard AnchorMatching.matches(exact, in: text, at: position.utf16Offset) else {
            return .invalid
        }
        // Every non-empty part of the context has to hold, adjacently. A quote
        // that matches but whose surroundings do not is not evidence that this
        // is the same content.
        guard AnchorMatching.contextHolds(
            exactAt: position.utf16Offset,
            exactLength: exact.count,
            prefix: AnchorMatching.units(anchor.quote.prefix ?? ""),
            suffix: AnchorMatching.units(anchor.quote.suffix ?? ""),
            in: text
        ) else { return .invalid }

        // **Rebuilt from the current text, never inherited.** The stored
        // `nodeID` may still resolve and still point somewhere else — the case
        // ADR-0003's stability promise does not cover — so the answer has to
        // come from the text that is here now. If the offset sits in no
        // element, there is nothing to build and the verdict is `invalid`
        // rather than the old identity.
        guard let nodeID = AnchorMatching.nodeID(
            forOffset: position.utf16Offset,
            in: unit.canonical
        ) else { return .invalid }

        return .valid(NativePosition(
            unitID: unit.id,
            nodeID: nodeID,
            utf16Offset: position.utf16Offset
        ))
    }
}
