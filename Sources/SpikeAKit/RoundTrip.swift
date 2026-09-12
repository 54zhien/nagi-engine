import Foundation

/// What a conversion did to a locator's information.
///
/// **Provenance, not equality.** These are not a scale from good to bad, and
/// the first three are not distinguished by whether the value came back the
/// same. They answer one question: *did the original information travel, or was
/// it rebuilt at the far end?* A value can arrive identical and still not have
/// travelled — see `recomputed`.
///
/// This distinction is the whole reason the harness exists. It was learned the
/// hard way: an offset recovered by inverting `progression` comes back *exactly*
/// right for every offset a fixture can reach, because `round(o/L × L) == o`
/// holds in IEEE-754. An equality that cannot fail can never be evidence, and
/// it never announces itself. Any future metric must be judged by this table
/// before it is judged by its numbers.
public enum FieldVerdict: String, Sendable, Hashable, Codable {
    /// The locator **carried** this value across the round trip. It travelled.
    case carried
    /// The locator did **not** carry it; the bridge re-derived it at the far
    /// end. It may happen to equal the original — an offset recovered from a
    /// progression does — and that equality is arithmetic, not a copy.
    case recomputed
    /// Recoverable only within a **declared tolerance**, in the metric's own
    /// units. Distinct from `recomputed`, which is exact-by-re-derivation:
    /// this one is honest about not landing on the same place.
    case approximated
    /// The intermediate representation has nowhere to put it. Not a bug:
    /// a coordinate cannot carry a quotation.
    case notCarriable
    /// Belongs to the publication rather than the position, so it returns only
    /// when the positions table does.
    case documentLevel
    /// Dropped, and it should not have been.
    case lost
}

public enum RoundTripOutcome: Sendable, Hashable, Codable {
    /// Every field came back `.carried`. This is a structural rule, not a
    /// three-condition test: `exact` is reachable only when *no* field is
    /// recomputed, approximated or lost. That makes the false positive of round
    /// two impossible rather than merely unlikely.
    case exact
    /// Same place, but at least one field was **re-derived** (`recomputed`) or
    /// recovered only within a tolerance (`approximated`). The numbers on such a
    /// row may all be equal to the originals. Say so here anyway: nothing on
    /// this row travelled, so nothing here is identity preservation.
    case recomputedEquivalent(notes: [String])
    /// Same place, and nothing was re-derived — the differences are fields this
    /// representation has nowhere to put (`notCarriable` / `documentLevel`).
    /// A dropped quotation lands here, and calling that "recomputed" would
    /// misname it.
    case semanticEquivalent(notes: [String])
    case loses(fields: [String])
    case requiresValidator(reason: String)
    case requiresReanchor(reason: String)
}

/// Thrown when the census buckets do not add up to the number of rows.
///
/// An outcome that matches no bucket is invisible: the row vanishes from the
/// count, no `numbers` key appears, and not one word of the detail line changes.
/// This error is the only thing that can notice — which is why the sum is
/// asserted rather than assumed. Adding a case to `RoundTripOutcome` compiles
/// clean everywhere except `main.swift`'s exhaustive `outcomeLabel`, and that
/// tripwire catches the *label*, not the *count*.
public enum RoundTripCensusError: Error, CustomStringConvertible {
    case bucketsDoNotSum(rows: Int, counted: Int)

    public var description: String {
        switch self {
        case .bucketsDoNotSum(let rows, let counted):
            return "the round-trip census counted \(counted) rows across its buckets but there are \(rows) — some outcome case matches no bucket, so those rows are missing from the detail line and from numbers"
        }
    }
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
    /// re-derived offset `.carried`.
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
        // **No `href` field here, on purpose.** There is no input href on this
        // side to judge: the locator was built by `locator(from:)` with
        // `href: unit.href`, so the old code looked that same unit up by the
        // same id and compared its href with its own href — a tautology that
        // always reported "carried". Worse, when the unit failed to resolve,
        // `nil == "…"` is false, so a *missing unit* was being reported as a
        // spelling difference.
        //
        // A field that cannot vary carries no information, so reporting one is
        // the defect — not the verdict chosen for it. Whether the right unit
        // came back is `unitID`'s question, and it is asked below.
        let unitIDMatches = recovered.unitID == position.unitID
        let nodeIDMatches = recovered.nodeID == position.nodeID
        let offsetMatches = recovered.utf16Offset == position.utf16Offset
        fields["unitID"] = unitIDMatches ? .carried : .lost
        // Under a derived resolution the node is recovered by
        // `innermostElement(containing:)` and the offset by inverting a
        // fraction — both functions of the same number. So `nodeIDMatches` is
        // *implied by* `offsetMatches` rather than independent evidence of it,
        // and `.carried` on either would report a tautology as a surviving
        // fact. Equal is not the same as carried.
        fields["nodeID"] = (nodeIDMatches && carried) ? .carried : .recomputed

        // Three outcomes for the offset, not two: it can arrive *equal because
        // it was recomputed*, which is neither `.carried` (nothing carried it)
        // nor `.lost` (nothing was dropped — the number is exactly right).
        let offsetVerdict: FieldVerdict
        if !offsetMatches {
            offsetVerdict = .lost
        } else if carried {
            offsetVerdict = .carried
        } else {
            offsetVerdict = .recomputed
        }
        fields["utf16Offset"] = offsetVerdict

        var derivedNotes: [String] = []
        if let basis = derivedBasis {
            derivedNotes = [
                "the offset came back numerically equal, but it was recomputed and not carried: the locator named no position inside the unit, so the bridge inverted \(basis) to obtain one",
                "an equal number is not evidence here — \(basis) is a fraction whose metric the locator does not state, and ADR-0009 lays the progression round trip down as a bounded tolerance rather than an exactness guarantee. The inversion is exact for every offset this fixture can reach, so this equality could never have failed",
                "the resolution itself lists \(basis) as discarded, so what survived was not anything the locator stated"
            ]
        }
        var semanticNotes: [String] = []
        if !nodeIDMatches {
            semanticNotes = [
                "the node identity came back as \(recovered.nodeID.described) instead of \(position.nodeID.described) at the same offset"
            ]
        }
        let outcome = classify(fields: fields, derivedNotes: derivedNotes, semanticNotes: semanticNotes)

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

    // MARK: - Classification

    /// **The one place a row's outcome is decided.** Both directions route
    /// through here so they cannot drift apart again — which is exactly how the
    /// round-two false positive arose: one direction read `fields` as
    /// provenance, the other as value-equality, and nothing forced them to
    /// agree.
    ///
    /// The rule is structural, not a tally: `exact` is reachable only when
    /// *every* field is `.carried`. A single `.recomputed` field is enough to
    /// demote the row, which makes "equal therefore exact" unreachable by
    /// construction rather than by convention.
    ///
    /// Note the order: a derived field outranks a merely un-carryable one. A row
    /// that both dropped a quotation and rebuilt an offset is reported as
    /// `recomputedEquivalent`, because that is the stronger claim about what
    /// happened to it.
    private static func classify(
        fields: [String: FieldVerdict],
        derivedNotes: [String],
        semanticNotes: [String]
    ) -> RoundTripOutcome {
        let lost = fields.filter { $0.value == .lost }.keys.sorted()
        if !lost.isEmpty { return .loses(fields: lost) }

        let derived = fields.filter { $0.value == .recomputed || $0.value == .approximated }
        if !derived.isEmpty { return .recomputedEquivalent(notes: derivedNotes) }

        let notCarried = fields.filter { $0.value == .notCarriable || $0.value == .documentLevel }
        if !notCarried.isEmpty { return .semanticEquivalent(notes: semanticNotes) }

        return .exact
    }

    // MARK: - Field comparison

    private static func compare(
        original: ReadiumLocator,
        regenerated: ReadiumLocator,
        basis: Resolution,
        name: String
    ) -> RoundTrip {
        var fields: [String: FieldVerdict] = [:]

        fields["href"] = Href.isEquivalent(original.href, regenerated.href) ? .carried : .lost
        fields["mediaType"] = original.mediaType == regenerated.mediaType ? .carried : .recomputed
        fields["title"] = original.title == nil ? .carried : .notCarriable
        fields["fragments"] = original.locations.fragments == regenerated.locations.fragments
            ? .carried
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

        var derivedNotes: [String] = []
        if case .approximate(_, let basisName, _) = basis {
            derivedNotes.append("the position was derived from \(basisName), so its offset is this bridge's arithmetic rather than a stated coordinate")
        }
        var semanticNotes: [String] = []
        if fields["text"] == .notCarriable {
            semanticNotes.append("the quotation did not come back — a Native Position has nowhere to keep it")
        }
        if fields["otherLocations"] == .notCarriable {
            semanticNotes.append("cssSelector / partialCfi / domRange did not come back")
        }
        if fields["position"] == .documentLevel || fields["totalProgression"] == .documentLevel {
            semanticNotes.append("the global position numbering belongs to the publication, not to the coordinate")
        }
        let outcome = classify(fields: fields, derivedNotes: derivedNotes, semanticNotes: semanticNotes)

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
