import Foundation

/// A field that can appear on a position, in either direction.
///
/// An enum rather than a `String` key because the old spelling silently
/// tolerated a typo: `fields["utf16Offst"] = .lost` added a key, changed no
/// verdict, and nothing anywhere would have said so.
///
/// **`mediaType` is deliberately absent.** The outbound writes `unit.mediaType`
/// and the inbound never records what the locator carried, so no component can
/// state what happened to it — and a verdict that cannot vary is not
/// information. It is the same defect the `href` field was deleted for in the
/// native-first direction (`RoundTrip.swift`), under a different name.
public enum LocatorField: String, Sendable, Hashable, Codable, CaseIterable {
    case href
    case title
    case fragments
    case cssSelector
    case progression
    case totalProgression
    case position
    case otherLocations
    case text
    case unitID
    case nodeID
    case utf16Offset
    /// The metric label the mirror's bare `Double?` has nowhere to put —
    /// ADR-0009's gap, recorded at the point it is dropped.
    case progressionMetric

    /// For notes and the report. `text` reads as "the quotation" because that
    /// is what a reader is being told about, and because a note that says
    /// "text" is a note about a field name rather than about a lost quotation.
    public var described: String {
        switch self {
        case .href: return "href"
        case .title: return "title"
        case .fragments: return "fragments"
        case .cssSelector: return "cssSelector"
        case .progression: return "progression"
        case .totalProgression: return "totalProgression"
        case .position: return "position"
        case .otherLocations: return "otherLocations"
        case .text: return "the quotation"
        case .unitID: return "unitID"
        case .nodeID: return "nodeID"
        case .utf16Offset: return "utf16Offset"
        case .progressionMetric: return "the progression's metric"
        }
    }
}

/// A tolerance **in the metric's own unit**.
///
/// Not in progression space: the report quantizes to three decimals, so a
/// 1e-9 discrepancy written there becomes `0.0` and manufactures exactness.
public struct Bound: Sendable, Hashable, Codable {
    public var tolerance: Double
    public var unit: PublicationProgressMetric

    public init(tolerance: Double, unit: PublicationProgressMetric) {
        self.tolerance = tolerance
        self.unit = unit
    }

    public var described: String {
        "\(tolerance) \(unit)"
    }
}

/// Why a field the locator stated did not survive.
///
/// An enum rather than the free-text reason strings the bridge used to append:
/// a string cannot be classified, cannot be checked for exhaustiveness, and
/// cannot be noticed when a new one appears.
///
/// **There is deliberately no case for a channel that succeeded.** The old code
/// appended a name both where a channel was refused *and* where a different
/// channel carried the same fact — so "cssSelector" appeared on a row where
/// nothing at all was lost. A reason enum with nowhere to put that is the enum
/// doing its job.
public enum DiscardReason: String, Sendable, Hashable, Codable, CaseIterable {
    case hrefMatchesNoUnit
    case fragmentNamesNothing
    case selectorNotUnderstood
    case selectorNamesNothing
    case unitCarriesNoText
    case unitHasNoAddressableElements
    case globalPositionNeedsThePositionsTable
    case nothingResolvable
    case metricHasNowhereToGo

    public var described: String {
        switch self {
        case .hrefMatchesNoUnit:
            return "the href named no unit"
        case .fragmentNamesNothing:
            return "the fragment named no element"
        case .selectorNotUnderstood:
            return "the selector was not a plain #id, so it was refused rather than guessed at"
        case .selectorNamesNothing:
            return "the selector named no element"
        case .unitCarriesNoText:
            return "the unit carries no text, so a fraction has nothing to point into"
        case .unitHasNoAddressableElements:
            return "the unit has no addressable elements"
        case .globalPositionNeedsThePositionsTable:
            return "a global position needs the publication's positions table, which a coordinate cannot hold"
        case .nothingResolvable:
            return "the locator carried nothing this bridge can resolve"
        case .metricHasNowhereToGo:
            return "the mirror's progression field is a bare Double, so the metric label cannot come along"
        }
    }
}

/// What happened to one field. **Provenance, not a scale from good to bad.**
///
/// The first three are not distinguished by whether the value came back the
/// same. They answer one question: *did the original information travel, or was
/// it rebuilt at the far end?* A value can arrive identical and still not have
/// travelled — an offset recovered by inverting a fraction does, for every
/// offset this fixture can reach, because `round(o/L × L) == o` holds in
/// IEEE-754. An equality that cannot fail can never be evidence.
public enum Provenance: Sendable, Hashable, Codable {
    /// The intermediate representation carried it and it came back.
    case carried
    /// It was rebuilt at the far end from something else.
    ///
    /// - `basis` names that something and is **always the resolution's own
    ///   basis string**, never a literal written at a call site. The clamp is
    ///   reachable, and `"progression (clamped)"` must not be flattened into
    ///   `"progression"` — a fact that a text comparison once depended on.
    /// - `bound` is the guarantee the path comes with. ADR-0009 lays the
    ///   progression path down as **bounded rather than exact**, and until now
    ///   that sentence had no carrier anywhere in the artifact. A path with no
    ///   stated bound is `nil` rather than a plausible-looking number.
    case recomputed(basis: String, bound: Bound?)
    /// The intermediate representation has nowhere to put it. Not a bug: a
    /// coordinate cannot carry a quotation.
    case notCarriable
    /// Belongs to the publication rather than the coordinate.
    case documentLevel
    /// The locator stated it and the resolution **refused** it. Distinct from
    /// `lost`, which is a drop nobody intended.
    case discarded(reason: DiscardReason)
    /// Dropped, and it should not have been.
    case lost

    public var described: String {
        switch self {
        case .carried:
            return "carried"
        case .recomputed(let basis, let bound):
            guard let bound else { return "recomputed from \(basis)" }
            return "recomputed from \(basis), bounded by \(bound.described)"
        case .notCarriable:
            return "nowhere to put it"
        case .documentLevel:
            return "publication-level, not a coordinate"
        case .discarded(let reason):
            return "refused: \(reason.described)"
        case .lost:
            return "lost"
        }
    }

    /// Rebuilt at the far end — the fact that keeps `exact` out of reach.
    public var isDerived: Bool {
        if case .recomputed = self { return true }
        return false
    }

    public var isLost: Bool { self == .lost }

    /// Differences this representation cannot help: it has nowhere to put the
    /// value, or the value belongs to the publication rather than the position.
    public var isUncarriable: Bool {
        self == .notCarriable || self == .documentLevel
    }
}

/// One field's provenance, with **no values attached**.
///
/// This is what the reducer consumes. Keeping the values off it makes "the
/// reducer cannot compare before against after" a fact about the types rather
/// than a rule someone has to remember — the same move as making `exact`
/// unreachable without every field being `.carried`.
public struct FieldProvenance: Sendable, Hashable, Codable {
    public var field: LocatorField
    public var provenance: Provenance

    public init(field: LocatorField, provenance: Provenance) {
        self.field = field
        self.provenance = provenance
    }
}

/// One row of the report's field table: what the input said, what came back,
/// and what happened in between.
///
/// **The two values are for a human reader and for nothing else.** Nothing
/// derives a verdict from them.
public struct FieldResolution: Sendable, Hashable, Codable {
    public var field: LocatorField
    public var original: String?
    public var resolved: String?
    public var provenance: Provenance

    public init(
        field: LocatorField,
        original: String?,
        resolved: String?,
        provenance: Provenance
    ) {
        self.field = field
        self.original = original
        self.resolved = resolved
        self.provenance = provenance
    }

    public var provenanceOnly: FieldProvenance {
        FieldProvenance(field: field, provenance: provenance)
    }
}

/// The shape of the resolution a row went through.
///
/// It is **not a field**, which is exactly why the reducer cannot receive it
/// through the provenance projection — and why it is a second argument rather
/// than something smuggled into `[LocatorField: Provenance]` as a pseudo-field.
/// The rules need it: a refusal is a different outcome from a loss, and no
/// field's fate can say "the locator admitted two positions".
public enum ResolutionShape: String, Sendable, Hashable, Codable {
    case structural
    case approximate
    case ambiguous
    case unresolvable
    /// The position could not be written out at all, so there was no locator to
    /// resolve back.
    case notExpressible

    /// Whether the shape is one that produced a position.
    public var producedAPosition: Bool {
        self == .structural || self == .approximate
    }
}

/// The order every reported field list is built in.
///
/// **Not decoration.** `Dictionary` iteration order is seeded per process, and
/// a `Codable` dictionary whose key is a `String`-raw enum encodes as an
/// *unkeyed* array — in that order — because the standard library branches on
/// `Key.self == String.self` rather than on the key being string-like. Three CI
/// processes would then hash three different payloads and the fingerprint gate
/// would fail outright. Arrays built from this are the same everywhere.
public func sortedFields(_ fields: [LocatorField]) -> [LocatorField] {
    let order = Dictionary(
        uniqueKeysWithValues: LocatorField.allCases.enumerated().map { ($1, $0) }
    )
    return fields.sorted { (order[$0] ?? 0) < (order[$1] ?? 0) }
}
