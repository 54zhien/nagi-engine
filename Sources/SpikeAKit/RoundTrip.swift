import Foundation

public enum RoundTripOutcome: Sendable, Hashable, Codable {
    /// Every field came back `.carried`. This is a structural rule, not a
    /// three-condition test: `exact` is reachable only when *no* field is
    /// recomputed or lost. That makes the false positive of round two
    /// impossible rather than merely unlikely.
    case exact
    /// Same place, but at least one field was **re-derived**. The numbers on
    /// such a row may all be equal to the originals. Say so here anyway:
    /// nothing on this row travelled, so nothing here is identity preservation.
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
    /// **The report's field table.** One row per field the input stated, saying
    /// what it said, what came back, and what happened in between.
    ///
    /// The two values are for a human reader. **Nothing derives a verdict from
    /// them** — `OutcomeReducer` receives only `provenance`, which is a type
    /// that has nowhere to put a value. "This code cannot compare before against
    /// after" is therefore a property of the types rather than a rule a future
    /// reader has to remember.
    public var resolutions: [FieldResolution]
    /// Every conversion through a Native Position needs a validator, and the
    /// reason says which of two situations it is in: the quote was dropped on
    /// the way, or there was never a quote and identity rests on structure alone.
    public var needsValidator: Bool
    public var validatorReason: String?
    /// Set when the conversion could not be made structurally at all.
    public var needsReanchor: Bool
    public var reanchorReason: String?

    public init(
        name: String,
        outcome: RoundTripOutcome,
        resolutions: [FieldResolution],
        needsValidator: Bool,
        validatorReason: String?,
        needsReanchor: Bool,
        reanchorReason: String?
    ) {
        self.name = name
        self.outcome = outcome
        self.resolutions = resolutions
        self.needsValidator = needsValidator
        self.validatorReason = validatorReason
        self.needsReanchor = needsReanchor
        self.reanchorReason = reanchorReason
    }

    public func resolution(of field: LocatorField) -> FieldResolution? {
        resolutions.first { $0.field == field }
    }

    public func provenance(of field: LocatorField) -> Provenance? {
        resolution(of: field)?.provenance
    }
}

public enum RoundTripHarness {
    /// Publication Position → Native Position → Publication Position.
    ///
    /// `label` names the case, so a report with a dozen of these stays readable.
    public static func locatorToNativeToLocator(
        _ locator: ReadiumLocator,
        in document: Document,
        label: String
    ) throws -> RoundTrip {
        let name = "\(label) locator->native->locator"
        let resolution = LocationBridge.native(from: locator, in: document)

        guard let position = resolution.position else {
            return try refused(
                name: name,
                resolution: resolution,
                shape: resolution.shape,
                validatorReason: "nothing was resolved, so nothing can be confirmed"
            )
        }
        guard let exported = LocationBridge.locator(from: position, in: document) else {
            return try refused(
                name: name,
                resolution: resolution,
                shape: .notExpressible,
                validatorReason: "the native position \(position.nodeID.described) names a unit the locator side cannot express"
            )
        }

        // **The input's own fields, and nothing else.** The export contributes
        // only the metric label it had to drop. Reporting the fields the export
        // wrote would put a `.recomputed` progression on every `id-anchored`
        // row — a field the input never stated, with a verdict invented for it.
        var table = resolution.provenance
        table.append(contentsOf: exported.provenance.filter { $0.field == .progressionMetric })

        return try finish(
            name: name,
            table: table,
            shape: resolution.shape,
            refusalReason: resolution.refusalReason,
            original: { field in describe(locator: locator, field: field) },
            resolved: { field in describe(locator: exported.locator, field: field) }
        )
    }

    /// Native Position → Publication Position → Native Position.
    ///
    /// This is the direction a reader actually depends on: a stored position
    /// must survive being written out and read back.
    public static func nativeToLocatorToNative(
        _ position: NativePosition,
        in document: Document,
        label: String
    ) throws -> RoundTrip {
        let name = "\(label) native->locator->native"
        guard let exported = LocationBridge.locator(from: position, in: document) else {
            return try refused(
                name: name,
                resolution: nil,
                shape: .notExpressible,
                validatorReason: "the position could not be expressed at all"
            )
        }

        let resolution = LocationBridge.native(from: exported.locator, in: document)
        guard resolution.position != nil else {
            return try refused(
                name: name,
                resolution: resolution,
                shape: resolution.shape,
                validatorReason: "the regenerated locator does not resolve back"
            )
        }

        // The export states `unitID` and — when it wrote a fragment — the fate of
        // `utf16Offset` and `nodeID`, because there the comparison is a fact
        // about what it emitted. A position that travelled as a fraction states
        // neither: only the read-back resolution knows what it was derived from,
        // and it says so with its basis.
        var table = exported.provenance.filter { $0.field != .progressionMetric }
        let statedOffset = table.contains { $0.field == .utf16Offset }
        if !statedOffset {
            let basis = resolution.basis ?? "an unnamed channel"
            // Appended in `LocatorField.allCases` order — `nodeID` before
            // `utf16Offset` — so both directions report their fields the same
            // way and a reader diffing the artifact does not see one direction
            // out of order for no stated reason.
            table.append(FieldProvenance(
                field: .nodeID,
                provenance: .recomputed(basis: basis, bound: nil)
            ))
            table.append(FieldProvenance(
                field: .utf16Offset,
                provenance: .recomputed(basis: basis, bound: resolution.bound)
            ))
        }
        if let metric = exported.provenance.first(where: { $0.field == .progressionMetric }) {
            table.append(metric)
        }

        return try finish(
            name: name,
            table: table,
            shape: resolution.shape,
            refusalReason: resolution.refusalReason,
            original: { field in describe(position: position, field: field) },
            resolved: { field in
                guard let recovered = resolution.position else { return nil }
                return describe(position: recovered, field: field)
            }
        )
    }

    // MARK: - Assembly

    /// A conversion that produced no position. Its outcome is the shape's, but
    /// its field table is not empty: everything the locator stated and a
    /// coordinate cannot hold was still dropped, and a refusal that reported
    /// nothing lost is how this round started.
    private static func refused(
        name: String,
        resolution: Resolution?,
        shape: ResolutionShape,
        validatorReason: String
    ) throws -> RoundTrip {
        let table = resolution?.provenance ?? []
        let outcome = try OutcomeReducer.reduce(
            table,
            shape: shape,
            refusalReason: resolution?.refusalReason ?? validatorReason,
            row: name
        )
        let needsReanchor = !shape.producedAPosition && shape != .notExpressible
        return RoundTrip(
            name: name,
            outcome: outcome,
            resolutions: resolutions(from: table, original: { _ in nil }, resolved: { _ in nil }),
            needsValidator: true,
            validatorReason: validatorReason,
            needsReanchor: needsReanchor,
            reanchorReason: needsReanchor ? (resolution?.refusalReason ?? validatorReason) : nil
        )
    }

    private static func finish(
        name: String,
        table: [FieldProvenance],
        shape: ResolutionShape,
        refusalReason: String?,
        original: (LocatorField) -> String?,
        resolved: (LocatorField) -> String?
    ) throws -> RoundTrip {
        let outcome = try OutcomeReducer.reduce(
            table,
            shape: shape,
            refusalReason: refusalReason,
            row: name
        )
        let carriedAQuote = table.contains { $0.field == .text && $0.provenance == .notCarriable }
        return RoundTrip(
            name: name,
            outcome: outcome,
            resolutions: resolutions(from: table, original: original, resolved: resolved),
            needsValidator: true,
            validatorReason: carriedAQuote
                ? "the locator carried a quotation and the result does not, so nothing in it can confirm the position still names the same content"
                : "the locator carried no quotation, so identity rested on structure alone and there is nothing to check it against",
            needsReanchor: false,
            reanchorReason: nil
        )
    }

    private static func resolutions(
        from table: [FieldProvenance],
        original: (LocatorField) -> String?,
        resolved: (LocatorField) -> String?
    ) -> [FieldResolution] {
        table.map { entry in
            FieldResolution(
                field: entry.field,
                original: original(entry.field),
                resolved: resolved(entry.field),
                provenance: entry.provenance
            )
        }
    }

    // MARK: - Rendering the two values

    private static func describe(locator: ReadiumLocator, field: LocatorField) -> String? {
        switch field {
        case .href: return locator.href
        case .title: return locator.title
        case .fragments: return locator.locations.fragments.isEmpty ? nil : locator.locations.fragments.joined(separator: " ")
        case .cssSelector: return locator.locations.cssSelector
        case .progression: return locator.locations.progression.map { String(format: "%.6f", $0) }
        case .totalProgression: return locator.locations.totalProgression.map { String(format: "%.6f", $0) }
        case .position: return locator.locations.position.map(String.init)
        case .otherLocations:
            let keys = locator.locations.otherLocations.keys.filter { $0 != "cssSelector" }.sorted()
            return keys.isEmpty ? nil : keys.joined(separator: " ")
        case .text: return locator.text.isEmpty ? nil : locator.text.highlight
        case .unitID, .nodeID, .utf16Offset, .progressionMetric: return nil
        }
    }

    private static func describe(position: NativePosition, field: LocatorField) -> String? {
        switch field {
        case .unitID: return position.unitID
        case .nodeID: return position.nodeID.described
        case .utf16Offset: return String(position.utf16Offset)
        case .progressionMetric: return nil
        default: return nil
        }
    }
}
