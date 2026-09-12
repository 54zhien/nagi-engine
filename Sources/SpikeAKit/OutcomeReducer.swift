import Foundation

/// Thrown when a row that produced a position reports no field provenance.
///
/// **`exact` must not be reachable from an empty projection.** The old
/// `classify` opened with "is any field `.lost`?", which is vacuously false for
/// an empty dictionary, so a row that reported nothing was reported as a
/// perfect round trip. A resolution that produced a position has at least one
/// field whose fate it can state; if it says nothing, the harness built the row
/// wrongly and that is a code failure, not a measurement.
public enum OutcomeReducerError: Error, CustomStringConvertible {
    case noEvidence(shape: ResolutionShape, row: String)

    public var description: String {
        switch self {
        case .noEvidence(let shape, let row):
            return "\(row) resolved as \(shape.rawValue) but reported no field provenance at all — an empty projection makes every rule vacuously true, and `exact` is the one verdict it must never yield"
        }
    }
}

/// The one place a row's outcome is decided.
///
/// Both directions route through here, so they cannot drift apart — which is
/// how the round-two false positive arose: one direction read the field table
/// as provenance, the other as value equality, and nothing forced them to
/// agree.
///
/// **It receives provenance and a shape, never values.** `[FieldProvenance]` has
/// nowhere to put an `original` or a `resolved`, so "this function cannot
/// compare before against after" is a property of the types rather than a rule
/// a future reader has to remember.
public enum OutcomeReducer {

    /// - Parameters:
    ///   - transport: what happened to each field the input stated — and, by
    ///     construction, **nothing else**. `RoundTrip.transportResolutions`
    ///     projected through `provenanceOnly`, which drops the two values a
    ///     reader sees; the bridge's own `observations` are a different type in a
    ///     different property, so they cannot arrive here even by mistake. A
    ///     metric label that had no business in this list is what let a row read
    ///     `exact` over its own `refused` row.
    ///   - shape: how the conversion went. Not a field, so it cannot arrive
    ///     through the projection — and the rules need it, because "the locator
    ///     admitted two positions" is not the fate of any one field.
    ///   - refusalReason: the prose the bridge gave for a refusal. A refusal's
    ///     reason is not a field fact either, so it comes in beside the shape
    ///     rather than being invented here from whatever fields happen to be
    ///     present.
    ///   - row: names the row in an error. Never part of a verdict.
    public static func reduce(
        _ transport: [FieldProvenance],
        shape: ResolutionShape,
        refusalReason: String?,
        row: String
    ) throws -> RoundTripOutcome {
        // A shape that produced no position is judged by the shape, not by
        // fields. Note the order: this outranks every field rule, because a
        // refusal is a stronger statement than any per-field outcome.
        if !shape.producedAPosition {
            let reason = refusalReason
                ?? "\(row) could not be resolved (\(shape.rawValue)) and no reason was recorded"
            // **Every shape that produced no position goes to ReanchorService**,
            // `.notExpressible` included. That last one used to return
            // `.requiresValidator` — a catch-all in a vocabulary whose other
            // rules are all about fields, chosen for the one shape that has no
            // fields to rule on.
            //
            // What a validator works on is a **candidate**, and this shape
            // produces none: the position could not be written out at all, so
            // there is nothing to confirm. Once `needsValidator` stopped being
            // written unconditionally, that outcome and that flag disagreed on
            // this shape — one struct claiming a validator was needed and not
            // needed in the same object. The pipeline's own rule settles it:
            // AnchorStrategy → AnchorValidator → ReanchorService, and a step with
            // no input from the step before it is skipped.
            return .requiresReanchor(reason: reason)
        }

        guard !transport.isEmpty else {
            throw OutcomeReducerError.noEvidence(shape: shape, row: row)
        }

        let lost = transport.filter { $0.provenance.isLost }
        if !lost.isEmpty {
            return .loses(fields: sortedFields(lost.map(\.field)).map(\.described))
        }

        let derived = transport.filter { $0.provenance.isDerived }
        if !derived.isEmpty {
            return .recomputedEquivalent(notes: derivedNotes(derived))
        }

        // **A refusal is not a carry, and this step is the difference.** Without
        // it `.discarded` fell through every filter above and landed on `exact`,
        // so a row could report `exact` while its own field table said
        // `refused` — the same contradiction that started this round, entering
        // through a door nobody had tried. It stayed hidden because every row
        // carrying a `.discarded` field was a row with no position, and those
        // are judged by their shape above and never reach these rules at all.
        //
        // It sits with the uncarriable fields rather than with the losses
        // because a refusal is intended: `loses` means dropped and it should not
        // have been.
        let notCarried = transport.filter {
            $0.provenance.isUncarriable || $0.provenance.isDiscarded
        }
        if !notCarried.isEmpty {
            return .semanticEquivalent(notes: notCarriedNotes(notCarried))
        }

        return .exact
    }

    // MARK: - Notes

    /// Notes say **which field** and **by what channel**, because a reader
    /// looking at a row where the numbers all agree has no other way to learn
    /// that nothing travelled.
    private static func derivedNotes(_ derived: [FieldProvenance]) -> [String] {
        derived.map { entry in
            guard case .recomputed(let basis) = entry.provenance else {
                return "\(entry.field.described) was rebuilt at the far end rather than carried"
            }
            return "\(entry.field.described) " + explanation(of: basis)
        }
    }

    /// **A `switch` with no `default`, over a type rather than over a string.**
    ///
    /// Every one of these sentences used to be chosen by `bound == nil`, which
    /// four different situations produce — so the artifact printed "the request
    /// was outside the range the field can name" on a row where the bridge had
    /// recomputed a fragment from a `cssSelector` and no request had been out of
    /// range at all. A fabricated explanation is worse than a terse one. A new
    /// basis is now a compile error here, and no case can borrow its
    /// neighbour's sentence.
    private static func explanation(of basis: RecomputeBasis) -> String {
        switch basis {
        case .progression(let bound):
            return "came back by way of the progression, not carried: the locator named no position inside the unit, so the bridge inverted a fraction to derive one — and only within \(bound.described), because ADR-0009 lays that path down as bounded rather than exact. An equal number is not evidence here: the inversion is exact for every offset this fixture can reach, so the equality could never have failed"
        case .clampedProgression:
            return "came back by way of a clamped progression, not carried: the request was outside 0...1, so the bridge used the boundary rather than honouring it. Nothing was asked for and nothing was met — which is why this path states no guarantee, and why the numbers agreeing is not the seek succeeding"
        case .cssSelector:
            return "came back by way of the cssSelector the locator stated: a selector names an element, and a fragment is how the way back out spells that same naming. Nothing was compared with anything"
        case .textHighlight:
            return "came back by way of the quotation: the element it matched is named, and a fragment is how the way back out spells it. What travelled is the element, not the text — a coordinate has nowhere to keep a quotation"
        case .utf16Offset:
            return "was derived from the offset the position already had, so it names the element that offset sits in rather than the offset itself"
        }
    }

    /// **No `default`.** Its sibling above is exhaustive on purpose, so that a
    /// new basis is a compile error; this one ended in a catch-all that would
    /// swallow a new `Provenance` case and print a sentence naming neither the
    /// case nor a reason. The four cases the filter excludes are now listed and
    /// say the only true thing about them — that they should not be here —
    /// rather than inventing a verdict for a field that is in neither list.
    private static func notCarriedNotes(_ notCarried: [FieldProvenance]) -> [String] {
        notCarried.map { entry in
            switch entry.provenance {
            case .notCarriable:
                return "\(entry.field.described) did not come back — a Native Position is a coordinate, and a coordinate has nowhere to keep it"
            case .documentLevel:
                return "\(entry.field.described) belongs to the publication rather than to the coordinate"
            case .discarded(let reason):
                return "\(entry.field.described) did not come back — refused: \(reason.described)"
            case .carried, .recomputed, .lost:
                return "\(entry.field.described) is \(entry.provenance.described), which is not a field that failed to come back — the filter above and this switch have drifted apart"
            }
        }
    }
}
