import Foundation

/// What a conversion did to a locator's information.
public enum FieldVerdict: String, Sendable, Hashable, Codable {
    /// Came back identical, and it travelled: the locator carried this value.
    case reproduced
    /// Came back denoting the same place, but **re-derived rather than carried**
    /// — a recomputed progression, an offset recovered from one, a differently
    /// spelled href.
    ///
    /// The value may be *equal* to the original. `compare` has always read this
    /// verdict that way ("an equal number is a coincidence of the arithmetic and
    /// not a copy"); the wording here said "a different value" and understated
    /// it, which is how a rebuilt-at-the-far-end offset came to be reported as
    /// though it had survived.
    case recomputed
    /// A Native Position has nowhere to put it. Not a bug: a coordinate cannot
    /// carry a quotation.
    case notCarriable
    /// Belongs to the publication rather than the position, so it returns only
    /// when the positions table does.
    case documentLevel
    /// Dropped, and it should not have been.
    case lost
}

public enum RoundTripOutcome: Sendable, Hashable, Codable {
    case exact
    case semanticEquivalent(notes: [String])
    case loses(fields: [String])
    case requiresValidator(reason: String)
    case requiresReanchor(reason: String)
}

/// The result of one conversion, in one direction, for one case.
public struct RoundTrip: Sendable, Hashable, Codable {
    public var name: String
    public var outcome: RoundTripOutcome
    /// Per-field verdicts, so a reader can see *which* information was
    /// **carried** rather than only whether the whole thing arrived.
    ///
    /// "Carried" is the operative word and it is not a synonym for "equal". A
    /// value that arrives identical because the bridge recomputed it at the far
    /// end did not survive the trip — it was rebuilt there, from something else.
    /// Both directions of this harness read this dictionary; they used to read
    /// it differently, which is the whole reason one of them could call a
    /// re-derived offset `.reproduced`.
    public var fields: [String: FieldVerdict]
    /// Every conversion through a Native Position needs a validator, and the
    /// reason says which of two situations it is in: the quote was dropped on
    /// the way, or there was never a quote and identity rests on structure alone.
    public var needsValidator: Bool
    public var validatorReason: String?
    /// Set when the conversion could not be made structurally at all.
    public var needsReanchor: Bool
    public var reanchorReason: String?
}

public enum RoundTripHarness {
    /// Publication Position → Native Position → Publication Position.
    ///
    /// `label` names the case, so a report with a dozen of these stays readable.
    public static func locatorToNativeToLocator(
        _ locator: ReadiumLocator,
        in document: Document,
        label: String
    ) -> RoundTrip {
        let name = "\(label) locator->native->locator"
        let resolution = LocationBridge.native(from: locator, in: document)

        switch resolution {
        case .unresolvable(let reason):
            return RoundTrip(
                name: name,
                outcome: .requiresReanchor(reason: reason),
                fields: [:],
                needsValidator: true,
                validatorReason: "nothing was resolved, so nothing can be confirmed",
                needsReanchor: true,
                reanchorReason: reason
            )

        case .ambiguous(let candidates):
            let reason = "the locator's information admits \(candidates.count) positions; choosing between them needs quote matching, which is ReanchorService's job"
            return RoundTrip(
                name: name,
                outcome: .requiresReanchor(reason: reason),
                fields: ["ambiguousCandidates": .lost],
                needsValidator: true,
                validatorReason: "no single position was chosen",
                needsReanchor: true,
                reanchorReason: reason
            )

        case .structural(let position, _), .approximate(let position, _, _):
            guard let regenerated = LocationBridge.locator(from: position, in: document) else {
                let reason = "the native position \(position.nodeID.described) names a unit the locator side cannot express"
                return RoundTrip(
                    name: name,
                    outcome: .requiresValidator(reason: reason),
                    fields: [:],
                    needsValidator: true,
                    validatorReason: reason,
                    needsReanchor: false,
                    reanchorReason: nil
                )
            }
            return compare(original: locator, regenerated: regenerated, basis: resolution, name: name)
        }
    }

    /// Native Position → Publication Position → Native Position.
    ///
    /// This is the direction a reader actually depends on: a stored position
    /// must survive being written out and read back.
    public static func nativeToLocatorToNative(
        _ position: NativePosition,
        in document: Document,
        label: String
    ) -> RoundTrip {
        let name = "\(label) native->locator->native"
        guard let locator = LocationBridge.locator(from: position, in: document) else {
            return RoundTrip(
                name: name,
                outcome: .requiresValidator(reason: "the native position names no unit in this document"),
                fields: [:],
                needsValidator: true,
                validatorReason: "the position could not be expressed at all",
                needsReanchor: false,
                reanchorReason: nil
            )
        }

        let resolution = LocationBridge.native(from: locator, in: document)
        guard let recovered = resolution.position else {
            let reason = "the regenerated locator does not resolve back"
            return RoundTrip(
                name: name,
                outcome: .requiresReanchor(reason: reason),
                fields: [:],
                needsValidator: true,
                validatorReason: reason,
                needsReanchor: true,
                reanchorReason: reason
            )
        }

        // Did the offset come back *carried*, or was it *rebuilt* at this end?
        //
        // `Resolution.approximate` is exactly the rebuilt case, and says so
        // itself: "the offset is this bridge's arithmetic rather than anything
        // the locator stated" (`LocationBridge.swift:15-18`). Keyed on the case
        // and not on the basis string, so that "progression (clamped)" — which
        // is reachable — cannot slip past a text comparison.
        //
        // (`basis: "text.highlight"` is unreachable in this direction:
        // `locator(from:)` never emits a quotation and `native(from:)` requires
        // a non-empty one. Its offset would be an element's range rather than a
        // number — a different reason for the same verdict.)
        var derivedBasis: String?
        if case .approximate(_, let basis, _) = resolution { derivedBasis = basis }
        let carried = derivedBasis == nil

        var fields: [String: FieldVerdict] = [:]
        fields["href"] = locator.href == document.unit(withID: position.unitID)?.href ? .reproduced : .recomputed
        let unitIDMatches = recovered.unitID == position.unitID
        let nodeIDMatches = recovered.nodeID == position.nodeID
        let offsetMatches = recovered.utf16Offset == position.utf16Offset
        fields["unitID"] = unitIDMatches ? .reproduced : .lost
        // Under a derived resolution the node is recovered by
        // `innermostElement(containing:)` and the offset by inverting a
        // fraction — both functions of the same number. So `nodeIDMatches` is
        // *implied by* `offsetMatches` rather than independent evidence of it,
        // and `.reproduced` on either would report a tautology as a surviving
        // fact. Equal is not the same as carried.
        fields["nodeID"] = (nodeIDMatches && carried) ? .reproduced : .recomputed

        // Three outcomes for the offset, not two: it can arrive *equal because
        // it was recomputed*, which is neither `.reproduced` (nothing carried
        // it) nor `.lost` (nothing was dropped — the number is exactly right).
        // Spelled out rather than nested, so each verdict gets its own line.
        let offsetVerdict: FieldVerdict
        if !offsetMatches {
            offsetVerdict = .lost
        } else if carried {
            offsetVerdict = .reproduced
        } else {
            offsetVerdict = .recomputed
        }
        fields["utf16Offset"] = offsetVerdict

        let outcome: RoundTripOutcome
        if !unitIDMatches || !offsetMatches {
            outcome = .loses(fields: fields.filter { $0.value == .lost }.keys.sorted())
        } else if let basis = derivedBasis {
            // Equal, but not carried. `.semanticEquivalent` and not `.loses`,
            // deliberately: the numbers do agree, and ADR-0009 gives the
            // progression round trip a bounded tolerance — reporting a
            // successful bounded seek as a lost field would be a second kind of
            // misreport, in the opposite direction.
            outcome = .semanticEquivalent(notes: [
                "the offset came back numerically equal, but it was recomputed and not carried: the locator named no position inside the unit, so the bridge inverted \(basis) to obtain one",
                "an equal number is not evidence here — \(basis) is a fraction whose metric the locator does not state, and ADR-0009 lays the progression round trip down as a bounded tolerance rather than an exactness guarantee. The inversion is exact for every offset this fixture can reach, so this equality could never have failed",
                "the resolution itself lists \(basis) as discarded, so what survived was not anything the locator stated"
            ])
        } else if nodeIDMatches {
            outcome = .exact
        } else {
            outcome = .semanticEquivalent(notes: [
                "the node identity came back as \(recovered.nodeID.described) instead of \(position.nodeID.described) at the same offset"
            ])
        }

        return RoundTrip(
            name: name,
            outcome: outcome,
            fields: fields,
            needsValidator: true,
            validatorReason: "the position carries no quotation, so only a validator can confirm the offset still lands on the same content",
            needsReanchor: false,
            reanchorReason: nil
        )
    }

    // MARK: - Field comparison

    private static func compare(
        original: ReadiumLocator,
        regenerated: ReadiumLocator,
        basis: Resolution,
        name: String
    ) -> RoundTrip {
        var fields: [String: FieldVerdict] = [:]

        fields["href"] = Href.isEquivalent(original.href, regenerated.href) ? .reproduced : .lost
        fields["mediaType"] = original.mediaType == regenerated.mediaType ? .reproduced : .recomputed
        fields["title"] = original.title == nil ? .reproduced : .notCarriable
        fields["fragments"] = original.locations.fragments == regenerated.locations.fragments
            ? .reproduced
            : (regenerated.locations.fragments.isEmpty ? .lost : .recomputed)
        if original.locations.progression != nil {
            // Always `recomputed`, even when the two numbers agree: the value is
            // derived from the offset rather than carried, so an equal number is
            // a coincidence of the arithmetic and not a copy.
            fields["progression"] = .recomputed
        }
        if original.locations.totalProgression != nil { fields["totalProgression"] = .documentLevel }
        if original.locations.position != nil { fields["position"] = .documentLevel }
        if !original.locations.otherLocations.isEmpty { fields["otherLocations"] = .notCarriable }
        if !original.text.isEmpty { fields["text"] = .notCarriable }

        let lost = fields.filter { $0.value == .lost }.keys.sorted()
        let outcome: RoundTripOutcome
        if !lost.isEmpty {
            outcome = .loses(fields: lost)
        } else if fields.values.allSatisfy({ $0 == .reproduced }) {
            outcome = .exact
        } else {
            var notes: [String] = []
            if case .approximate(_, let basisName, _) = basis {
                notes.append("the position was derived from \(basisName), so its offset is this bridge's arithmetic rather than a stated coordinate")
            }
            if fields["text"] == .notCarriable {
                notes.append("the quotation did not come back — a Native Position has nowhere to keep it")
            }
            if fields["otherLocations"] == .notCarriable {
                notes.append("cssSelector / partialCfi / domRange did not come back")
            }
            if fields["position"] == .documentLevel || fields["totalProgression"] == .documentLevel {
                notes.append("the global position numbering belongs to the publication, not to the coordinate")
            }
            outcome = .semanticEquivalent(notes: notes)
        }

        let hadQuote = !original.text.isEmpty
        return RoundTrip(
            name: name,
            outcome: outcome,
            fields: fields,
            needsValidator: true,
            validatorReason: hadQuote
                ? "the locator carried a quotation and the result does not, so nothing in it can confirm the position still names the same content"
                : "the locator carried no quotation, so identity rested on structure alone and there is nothing to check it against",
            needsReanchor: false,
            reanchorReason: nil
        )
    }
}
