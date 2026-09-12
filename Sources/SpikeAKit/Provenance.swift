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
    // **`progressionMetric` used to be here and is now an `Observation`.**
    // It is not a field the input stated, and putting it in a list documented
    // as "one row per field the input stated" made `exact` reachable on a row
    // whose own table said `refused`. A bridge fact belongs beside the transport
    // table, not inside it.

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
        }
    }

    /// Whether a locator **stated** this field.
    ///
    /// **Defined once, here**, because two things need the answer and they must
    /// not each have their own: the bridge, which decides what to report, and the
    /// probe, which checks that the bridge reported everything the input said.
    /// Before this the judgement was spread across `if locator.title != nil` /
    /// `if !locator.text.isEmpty` / `if locator.locations.progression != nil`, so
    /// "did the input state it?" had as many answers as there were call sites —
    /// and a mixed locator fell between two of them and lost two fields.
    public func isStated(by locator: ReadiumLocator) -> Bool {
        switch self {
        case .href:
            // Always. The mirror's decoder requires it and throws rather than
            // defaulting (`Locator.swift:53-59`), so a locator that exists has
            // stated one — its presence is not a choice the producer made.
            return true
        case .title: return locator.title != nil
        case .fragments: return !locator.locations.fragments.isEmpty
        case .cssSelector: return locator.locations.cssSelector != nil
        case .progression: return locator.locations.progression != nil
        case .totalProgression: return locator.locations.totalProgression != nil
        case .position: return locator.locations.position != nil
        case .otherLocations:
            // `cssSelector` is stored inside `otherLocations`, and it has a row
            // of its own — counting it twice would imply a second thing was lost.
            return locator.locations.otherLocations.keys.contains { $0 != "cssSelector" }
        case .text: return !locator.text.isEmpty
        // Never stated by a locator. These are facts a **Native Position** has,
        // and they only appear in the native-first direction's table.
        case .unitID, .nodeID, .utf16Offset: return false
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
    /// A structural anchor named the element first, and this field was never
    /// consulted. **Not a failure** — ADR-0004's ladder puts ids above numbers,
    /// so an id outranking a fraction is the ladder working. It is still a
    /// refusal rather than a carry: what the input stated here is not what came
    /// back, and reporting nothing at all is how a mixed locator came to claim
    /// two fewer fields than it was given.
    case aMorePreciseAnchorResolvedIt

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
        case .aMorePreciseAnchorResolvedIt:
            return "a more precise anchor resolved the position, so this field was never consulted"
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
    /// The basis is a **type**, not a string. It was a string plus an optional
    /// `Bound`, and the renderer explained every `bound == nil` as "the request
    /// was outside the range the field can name" — which is true of exactly one
    /// of the five ways a field gets here. The artifact carried that sentence on
    /// a `cssSelector` recompute, which is a fabricated explanation rather than
    /// a terse one.
    case recomputed(basis: RecomputeBasis)
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
        case .recomputed(let basis):
            return "recomputed from \(basis.described)"
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

    /// The locator stated it and the resolution refused it — **deliberately**,
    /// which is why it is not a loss. It still keeps `exact` out of reach: a
    /// field that was stated and did not come back is not a field that came
    /// back, whatever the reason.
    ///
    /// This existed as a case before it existed as a question, which is how a
    /// row reached `exact` while its own table said `refused` — the reducer
    /// looked for losses, derivations and uncarriable fields, and a refusal is
    /// none of the three.
    public var isDiscarded: Bool {
        if case .discarded = self { return true }
        return false
    }

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
    ///
    /// `producedAPosition` is false for it, which places it with `.unresolvable`
    /// rather than apart from it: it yields no candidate, so `AnchorValidator`
    /// has nothing to work on and the row goes to `ReanchorService` with the
    /// rest. It used to be the one shape whose outcome was `requiresValidator`,
    /// which put it outside both flags' rules and let the outcome and
    /// `needsValidator` contradict each other inside one struct.
    case notExpressible

    /// Whether the shape is one that produced a position.
    public var producedAPosition: Bool {
        self == .structural || self == .approximate
    }
}

/// What a re-derivation was derived **from**, and the guarantee it comes with.
///
/// A type rather than a string because the string could not be explained: the
/// renderer had one sentence for `bound == nil` and four quite different
/// situations produce it. A `switch` with no `default` makes a new basis a
/// compile error, so no explanation can ever be borrowed again.
public enum RecomputeBasis: Sendable, Hashable, Codable {
    /// A fraction of the unit's canonical length, inverted. `bound` is the
    /// guarantee ADR-0009 gives this path — **bounded rather than exact** — and
    /// it is stated in the metric's own unit.
    ///
    /// **Not optional.** A clamped request is a different case rather than the
    /// same case with no bound, and every remaining route to this one carries a
    /// bound: `seekTolerance` is non-optional in `ProgressMetricAxis`. An
    /// optional here would be vocabulary with zero coverage — the defect this
    /// repository has already been bitten by twice.
    case progression(bound: Bound)
    /// A request outside `0...1`. **A different fact from a progression without
    /// a bound**: the bridge did not honour the request, it used the boundary,
    /// so nothing was asked for and nothing was met — not a bound it failed.
    case clampedProgression
    /// A `#id` selector named the element; the way back out spells it as a
    /// fragment.
    case cssSelector
    /// A quotation located the element.
    case textHighlight
    /// The node was recovered from the offset the position already had.
    case utf16Offset

    public var described: String {
        switch self {
        case .progression(let bound):
            return "progression, bounded by \(bound.described)"
        case .clampedProgression:
            return "progression (clamped)"
        case .cssSelector:
            return "cssSelector"
        case .textHighlight:
            return "text.highlight"
        case .utf16Offset:
            return "utf16Offset"
        }
    }
}

/// How far a progression reaches.
///
/// ADR-0009's sealed conclusion is `Position = 数值 + metric + scope +
/// provenance`, and until now only the first two were in the type. Two
/// coordinates with the same value *and* the same metric name different places
/// when their scopes differ — which is exactly the substitution that would have
/// moved an offset from 22 to 9 while every census bucket still added up.
public enum ProgressScope: Sendable, Hashable, Codable {
    /// A fraction of the whole publication.
    case publication
    /// A fraction of one resource. `locations.progression` is this one, and
    /// `LocationBridge.native(from:)` inverts it against `unit.length`.
    ///
    /// The identifier is still a bare `String` and has **two producers**:
    /// `LocationBridge.locator(from:)` passes `DocumentUnit.id`, while
    /// `SourceBytesAxis` and `FixedPageOrdinalAxis` pass the `ByteResource.href`
    /// they captured. Those are the same identifier — a byte resource becomes a
    /// unit whose id is its href — but they coincide because this fixture says
    /// so, not because the type enforces it. Giving unit identity its own type
    /// would close that, and it is a separate change with a much larger blast
    /// radius; what this case fixes is the *scope*, which is the part that was
    /// silently different.
    case resource(String)

    public var described: String {
        switch self {
        case .publication: return "publication-wide"
        case .resource(let id): return "within \(id)"
        }
    }
}

/// A fact the **bridging process** produced, as opposed to something the input
/// stated.
///
/// These are visible in the report and **invisible to the reducer**. The first
/// version appended one of them to the transport table, which made a row read
/// `exact` while its own table said a field had been refused — the model
/// contradicting itself in the artifact.
public struct Observation: Sendable, Hashable, Codable {
    public var kind: ObservationKind
    public var described: String

    public init(kind: ObservationKind, described: String) {
        self.kind = kind
        self.described = described
    }
}

public enum ObservationKind: String, Sendable, Hashable, Codable, CaseIterable {
    /// `locations.progression` is a bare `Double` because that is Readium's
    /// shape, so the label has nowhere to go — ADR-0009:73's gap.
    case metricDroppedToFitTheMirror
    /// The same drop, and a second fact: the number written there is
    /// **resource-scoped**, and the axis's is publication-wide.
    case scopeDroppedToFitTheMirror
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
