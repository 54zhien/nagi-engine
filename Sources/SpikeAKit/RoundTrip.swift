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
    /// Same place, and nothing was re-derived — the differences are fields that
    /// did not come back and were not rebuilt: this representation has nowhere
    /// to put them (`notCarriable` / `documentLevel`), or the resolution refused
    /// them (`discarded`).
    ///
    /// A dropped quotation lands here, and calling that "recomputed" would
    /// misname it. So would calling a deliberate refusal a loss: `loses` means
    /// dropped and it should not have been, and a refusal is the bridge saying
    /// it used something more precise.
    case semanticEquivalent(notes: [String])
    case loses(fields: [String])
    /// **Reached by no path today, and that is a statement rather than an
    /// oversight.** It was the catch-all for a shape whose outcome no field rule
    /// could decide — `.notExpressible` — and that shape now goes to
    /// `requiresReanchor` like every other one that produced no position. So the
    /// census reads `requiresValidator: 0`, which it already did before this
    /// change: the case has been zero-coverage for as long as the census has
    /// been reported.
    ///
    /// It is kept for one round on purpose. Merging it into `requiresReanchor`
    /// is the next round's change — `tasks/todo.md` has it as the vocabulary
    /// count going 6 → 5 — and doing that merge here would put a vocabulary
    /// rewrite inside a push whose whole criterion is that no bucket moves.
    /// `main.swift`'s `outcomeLabel` keeps its arm, so deleting the case will
    /// still be a compile error in the place that must notice.
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

/// Thrown when a row rebuilt a field and could not say what from.
///
/// The harness needs the channel to write the row's own two fields, and until
/// this round it covered a missing one with the literal `"an unnamed channel"` —
/// an explanation invented for a branch nobody had established was reachable.
/// A fabricated sentence in the artifact is worse than a terse one, and this is
/// the same rule `OutcomeReducerError.noEvidence` enforces on the other side of
/// the same seam.
public enum RoundTripAssemblyError: Error, CustomStringConvertible {
    case derivationWithoutAStatedBasis(row: String, shape: ResolutionShape)

    public var description: String {
        switch self {
        case .derivationWithoutAStatedBasis(let row, let shape):
            return "\(row) resolved as \(shape.rawValue) and stated no offset of its own, so the harness had to derive one — but the resolution names no basis, and naming a channel it never named would put a sentence in the artifact that no measurement produced"
        }
    }
}

/// The result of one conversion, in one direction, for one case.
public struct RoundTrip: Sendable, Hashable, Codable {
    public var name: String
    public var outcome: RoundTripOutcome
    /// **The report's field table: one row per field the input stated**, saying
    /// what it said, what came back, and what happened in between.
    ///
    /// The two values are for a human reader. **Nothing derives a verdict from
    /// them** — `OutcomeReducer` receives only `provenance`, which is a type
    /// that has nowhere to put a value. "This code cannot compare before against
    /// after" is therefore a property of the types rather than a rule a future
    /// reader has to remember.
    ///
    /// **The name says `transport` because it is a contract, not a label.** The
    /// table holds what travelled — or failed to — for the fields the input
    /// gave. Facts the *bridge* produced about itself are `observations` below,
    /// a different type in a different property, so `OutcomeReducer` cannot
    /// reach them even by accident. It used to be one list, and the metric label
    /// — a bridge fact, not an input field — sat in it as a `refused` row that
    /// made `exact` read as a contradiction of the row's own table.
    public var transportResolutions: [FieldResolution]
    /// What the **bridging process** produced, as opposed to anything the input
    /// stated. Reported, and deliberately outside the verdict.
    public var observations: [Observation]
    /// Whether a validator has work to do on this row, and the reason says which
    /// of the two situations it is in: a candidate came back and something has to
    /// confirm it still names the same content, or several candidates came back
    /// and something has to choose between them.
    ///
    /// **False when no candidate was produced at all.** A row that resolved to
    /// nothing hands AnchorValidator nothing to validate, so it goes straight to
    /// `ReanchorService` — which is why this flag and `needsReanchor` can both be
    /// true on the same row, and why neither implies the other.
    public var needsValidator: Bool
    public var validatorReason: String?
    /// Set when the conversion could not be made structurally at all.
    public var needsReanchor: Bool
    public var reanchorReason: String?

    public init(
        name: String,
        outcome: RoundTripOutcome,
        transportResolutions: [FieldResolution],
        observations: [Observation],
        needsValidator: Bool,
        validatorReason: String?,
        needsReanchor: Bool,
        reanchorReason: String?
    ) {
        self.name = name
        self.outcome = outcome
        self.transportResolutions = transportResolutions
        self.observations = observations
        self.needsValidator = needsValidator
        self.validatorReason = validatorReason
        self.needsReanchor = needsReanchor
        self.reanchorReason = reanchorReason
    }

    public func resolution(of field: LocatorField) -> FieldResolution? {
        transportResolutions.first { $0.field == field }
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
                validatorReason: "no single position came back, so nothing can be confirmed here",
                observations: [],
                original: { field in describe(locator: locator, field: field) }
            )
        }
        guard let exported = LocationBridge.locator(from: position, in: document) else {
            return try refused(
                name: name,
                resolution: resolution,
                shape: .notExpressible,
                validatorReason: "the native position \(position.nodeID.described) names a unit the locator side cannot express",
                observations: [],
                original: { field in describe(locator: locator, field: field) }
            )
        }

        // **The input's own fields, and nothing else.** What the export had to
        // drop to fit the mirror — the metric label and the scope — is a fact
        // about the bridge, and it travels as an observation on the row rather
        // than as a row in this table. Appending it here is exactly how a row
        // came to read `exact` while its own table said `refused`.
        return try finish(
            name: name,
            table: resolution.provenance,
            observations: exported.observations,
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
                validatorReason: "the position could not be expressed at all",
                observations: [],
                original: { field in describe(position: position, field: field) }
            )
        }

        let resolution = LocationBridge.native(from: exported.locator, in: document)
        guard resolution.position != nil else {
            return try refused(
                name: name,
                resolution: resolution,
                shape: resolution.shape,
                validatorReason: "the regenerated locator does not resolve back",
                observations: exported.observations,
                original: { field in describe(position: position, field: field) }
            )
        }

        // The export states `unitID` and — when it wrote a fragment — the fate of
        // `utf16Offset` and `nodeID`, because there the comparison is a fact
        // about what it emitted. A position that travelled as a fraction states
        // neither: only the read-back resolution knows what it was derived from,
        // and it says so with its basis. Nothing is filtered out of the export's
        // list here any more — a filter in this direction and an append in the
        // other was one edit away from silently changing a field table.
        var table = exported.provenance
        if !table.contains(where: { $0.field == .utf16Offset }) {
            // **This used to fall back to the string `"an unnamed channel"`.** A
            // path that derives an offset and cannot say what from does not
            // exist — `.approximate` is the only shape that reaches here and it
            // carries a basis by construction — so that literal was a sentence
            // invented to cover a branch nobody had checked was unreachable. An
            // unreachable branch that quietly does nothing is how a field table
            // loses a row with nobody the wiser; this one throws.
            guard let basis = resolution.basis else {
                throw RoundTripAssemblyError.derivationWithoutAStatedBasis(
                    row: name,
                    shape: resolution.shape
                )
            }
            // Appended in `LocatorField.allCases` order — `nodeID` before
            // `utf16Offset` — so both directions report their fields the same
            // way and a reader diffing the artifact does not see one direction
            // out of order for no stated reason.
            table.append(FieldProvenance(field: .nodeID, provenance: .recomputed(basis: basis)))
            table.append(FieldProvenance(field: .utf16Offset, provenance: .recomputed(basis: basis)))
        }

        return try finish(
            name: name,
            table: table,
            observations: exported.observations,
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
        validatorReason: String,
        observations: [Observation],
        original: (LocatorField) -> String?
    ) throws -> RoundTrip {
        let table = resolution?.provenance ?? []
        let outcome = try OutcomeReducer.reduce(
            table,
            shape: shape,
            refusalReason: resolution?.refusalReason ?? validatorReason,
            row: name
        )
        // **Every shape without a position, with no exception.** The
        // `shape != .notExpressible` carve-out existed because that shape's
        // outcome was `requiresValidator` and a row could not need both — but it
        // produces no candidate either, and by the pipeline's own rule a step
        // with nothing from the step before it is skipped. Leaving the carve-out
        // would have moved the contradiction rather than removed it: the outcome
        // would say reanchor while this flag said no.
        let needsReanchor = !shape.producedAPosition
        // **A candidate is what a validator validates.** `.ambiguous` produced
        // several and something has to choose between them; `.unresolvable` and
        // `.notExpressible` produced none, and a validator handed nothing has
        // nothing to confirm — those rows go straight to `ReanchorService`.
        //
        // This was `true` unconditionally, so twenty rows out of twenty claimed
        // a validator's work to do and six of them had none.
        let needsValidator = shape == .ambiguous
        return RoundTrip(
            name: name,
            outcome: outcome,
            transportResolutions: resolutions(from: table, original: original, resolved: { _ in nil }),
            observations: observations,
            needsValidator: needsValidator,
            // A reason for a flag that is off is noise, and worse: it reads as
            // though the validator had been asked and declined.
            validatorReason: needsValidator ? (resolution?.refusalReason ?? validatorReason) : nil,
            needsReanchor: needsReanchor,
            reanchorReason: needsReanchor ? (resolution?.refusalReason ?? validatorReason) : nil
        )
    }

    private static func finish(
        name: String,
        table: [FieldProvenance],
        observations: [Observation],
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
            transportResolutions: resolutions(from: table, original: original, resolved: resolved),
            observations: observations,
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
        case .unitID, .nodeID, .utf16Offset: return nil
        }
    }

    private static func describe(position: NativePosition, field: LocatorField) -> String? {
        switch field {
        case .unitID: return position.unitID
        case .nodeID: return position.nodeID.described
        case .utf16Offset: return String(position.utf16Offset)
        // Every other field belongs to the locator side and has no value here.
        default: return nil
        }
    }
}
