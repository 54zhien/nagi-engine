import Foundation

/// Answers the other question: **the stored position is gone, or has stopped
/// meaning what it meant — can the text be found again?**
///
/// The search is deliberately dull. Reading order, then UTF-16 offset inside
/// the unit. No weighting by the old `unitID` / `href` / `nodeID`, no distance,
/// no "nearest". A recovered position that is chosen by proximity is a guess
/// wearing a coordinate's clothes, and the reader is never told.
public enum ReanchorService {

    /// One hit, with the text that produced it.
    ///
    /// **Not a public type and not `NativePosition` on its own.** A candidate
    /// is only meaningful together with the haystack it was found in, and the
    /// filter has to read *that* text rather than look the unit up again. The
    /// public `[NativePosition]` is a projection of these, made once, at the
    /// end.
    private struct Candidate {
        var position: NativePosition
        var haystack: [UInt16]
    }

    /// `async throws` for the same reason as `AnchorValidator.validate`: the
    /// production boundary needs to materialise units, and the signature should
    /// already say so.
    public static func reanchor(
        _ anchor: Anchor,
        in document: Document
    ) async throws -> ReanchorResult {
        let exact = AnchorMatching.units(anchor.quote.exact)

        // Nothing to search for and nothing to confirm, said before the
        // validator runs — so this answer does not depend on whether some
        // position happened to survive. ADR-0012.
        guard !exact.isEmpty else { return .notFound(.emptyQuote) }

        // Assigned to a temporary before the pattern match rather than written
        // as `if case … = try await …`. Both are legal Swift as far as this
        // author can tell, and `tasks/lessons.md` records a CI run lost to a
        // `try` in a position that was *also* legal-looking. The explicit form
        // is the one that cannot be wrong about evaluation order.
        let validation = try await AnchorValidator.validate(anchor, in: document)
        if case .valid(let position) = validation {
            return .relocated(position, method: .originalPosition)
        }

        let prefix = AnchorMatching.units(anchor.quote.prefix ?? "")
        let suffix = AnchorMatching.units(anchor.quote.suffix ?? "")

        // **A candidate carries the text it was actually found in.**
        // Re-deriving that text from `candidate.unitID` at filter time would be
        // a second lookup, and a second lookup can disagree with the first:
        // `DocumentUnit.id` is the href in this fixture, and two units sharing
        // an href would collapse in `unit(withID:)`. The evidence for a match
        // is the haystack that produced it, so it travels with the candidate.
        var candidates: [Candidate] = []
        for unit in document.readingOrder {
            try Task.checkCancellation()
            let text = AnchorMatching.units(unit.canonical.string)
            for offset in AnchorMatching.occurrences(of: exact, in: text) {
                // Only occurrences a `NativePosition` can be built from are
                // recorded. An offset that sits in no element has no node to
                // name, and inventing one would make a coordinate out of
                // nothing.
                guard let nodeID = AnchorMatching.nodeID(
                    forOffset: offset,
                    in: unit.canonical
                ) else { continue }
                candidates.append(Candidate(
                    position: NativePosition(
                        unitID: unit.id,
                        nodeID: nodeID,
                        utf16Offset: offset
                    ),
                    haystack: text
                ))
            }
        }

        // Candidates are appended unit by unit and offset by offset, so the
        // order is reading order + UTF-16 offset **by construction**. Nothing
        // re-sorts them, and nothing may.
        guard !candidates.isEmpty else { return .notFound(.exactTextMissing) }

        // **One occurrence needs no context, and a stale context cannot veto
        // it.** Refusing here would report a miss about text that is plainly
        // present, which is the `notFound` this whole layer exists to avoid.
        if candidates.count == 1 {
            return .relocated(candidates[0].position, method: .uniqueExactQuote)
        }

        var filtered: [Candidate] = []
        for candidate in candidates {
            if AnchorMatching.contextHolds(
                exactAt: candidate.position.utf16Offset,
                exactLength: exact.count,
                prefix: prefix,
                suffix: suffix,
                in: candidate.haystack
            ) {
                filtered.append(candidate)
            }
        }

        if filtered.count == 1 {
            return .relocated(filtered[0].position, method: .quoteContext)
        }
        if filtered.count > 1 {
            return .ambiguous(filtered.map(\.position))
        }

        // **Zero survivors is not `notFound`.** The quote matched literally;
        // what failed is the memory of its surroundings. Answering `notFound`
        // would deny text that is right there, and answering with the nearest
        // survivor would invent a choice the evidence does not make. ADR-0012:
        // the raw candidates come back, so the caller sees what was actually
        // found.
        return .ambiguous(candidates.map(\.position))
    }
}
