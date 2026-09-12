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
    ///   - provenances: what happened to each field the input stated.
    ///   - shape: how the conversion went. Not a field, so it cannot arrive
    ///     through the projection — and the rules need it, because "the locator
    ///     admitted two positions" is not the fate of any one field.
    ///   - refusalReason: the prose the bridge gave for a refusal. A refusal's
    ///     reason is not a field fact either, so it comes in beside the shape
    ///     rather than being invented here from whatever fields happen to be
    ///     present.
    ///   - row: names the row in an error. Never part of a verdict.
    public static func reduce(
        _ provenances: [FieldProvenance],
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
            if shape == .notExpressible {
                return .requiresValidator(reason: reason)
            }
            return .requiresReanchor(reason: reason)
        }

        guard !provenances.isEmpty else {
            throw OutcomeReducerError.noEvidence(shape: shape, row: row)
        }

        let lost = provenances.filter { $0.provenance.isLost }
        if !lost.isEmpty {
            return .loses(fields: sortedFields(lost.map(\.field)).map(\.described))
        }

        let derived = provenances.filter { $0.provenance.isDerived }
        if !derived.isEmpty {
            return .recomputedEquivalent(notes: derivedNotes(derived))
        }

        let uncarried = provenances.filter { $0.provenance.isUncarriable }
        if !uncarried.isEmpty {
            return .semanticEquivalent(notes: uncarriedNotes(uncarried))
        }

        return .exact
    }

    // MARK: - Notes

    /// Notes say **which field** and **by what channel**, because a reader
    /// looking at a row where the numbers all agree has no other way to learn
    /// that nothing travelled.
    private static func derivedNotes(_ derived: [FieldProvenance]) -> [String] {
        derived.map { entry in
            guard case .recomputed(let basis, let bound) = entry.provenance else {
                return "\(entry.field.described) was rebuilt at the far end rather than carried"
            }
            let head = "\(entry.field.described) came back by way of \(basis), not carried: the locator named no position inside the unit, so the bridge derived one"
            guard let bound else {
                return head
                    + " — and no bound is stated for that path, because the request was outside the range the field can name, so the bridge used the boundary instead of honouring it"
            }
            return head
                + " — and only within \(bound.described), because ADR-0009 lays that path down as bounded rather than exact. An equal number is not evidence here: the inversion is exact for every offset this fixture can reach, so the equality could never have failed"
        }
    }

    private static func uncarriedNotes(_ uncarried: [FieldProvenance]) -> [String] {
        uncarried.map { entry in
            switch entry.provenance {
            case .notCarriable:
                return "\(entry.field.described) did not come back — a Native Position is a coordinate, and a coordinate has nowhere to keep it"
            case .documentLevel:
                return "\(entry.field.described) belongs to the publication rather than to the coordinate"
            default:
                return "\(entry.field.described) did not come back"
            }
        }
    }
}
