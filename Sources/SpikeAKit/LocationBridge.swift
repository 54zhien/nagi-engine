import Foundation

/// How a Publication Position became a Native Position.
///
/// The cases are deliberately not "success / failure". ADR-0004 says the three
/// anchoring responsibilities must not be merged, and the only way to see which
/// of them a given conversion needs is to have the conversion say what it
/// actually did.
///
/// **Each case carries the provenance it produced.** That is the whole point of
/// this round: the bridge states what happened to each field, and the judge
/// interprets those statements instead of comparing values and inferring. A
/// refusal carries provenance too — a conversion that failed to resolve still
/// dropped whatever the locator stated, and a flat list that called that
/// "nothing" is how a refusal came to report no information loss.
public enum Resolution: Sendable, Hashable {
    /// Derived from a structural anchor — an element id. Nothing was
    /// approximated: the same document gives the same answer, and the answer
    /// names a node rather than an offset in a number line.
    case structural(NativePosition, provenance: [FieldProvenance])

    /// Derived from a numeric location. The neighbourhood is right, but the
    /// offset is this bridge's arithmetic rather than anything the locator
    /// stated.
    case approximate(NativePosition, basis: String, bound: Bound?, provenance: [FieldProvenance])

    /// The locator's own information admits more than one position. Readium's
    /// JavaScript produces exactly this shape: `dom.js:55-67` emits a
    /// `cssSelector` plus an unbounded `text.highlight` and nothing else.
    case ambiguous([NativePosition], reason: String, provenance: [FieldProvenance])

    /// Structurally impossible, with the reason spelled out.
    case unresolvable(reason: String, provenance: [FieldProvenance])

    public var position: NativePosition? {
        switch self {
        case .structural(let position, _): return position
        case .approximate(let position, _, _, _): return position
        case .ambiguous, .unresolvable: return nil
        }
    }

    public var provenance: [FieldProvenance] {
        switch self {
        case .structural(_, let provenance): return provenance
        case .approximate(_, _, _, let provenance): return provenance
        case .ambiguous(_, _, let provenance): return provenance
        case .unresolvable(_, let provenance): return provenance
        }
    }

    public var shape: ResolutionShape {
        switch self {
        case .structural: return .structural
        case .approximate: return .approximate
        case .ambiguous: return .ambiguous
        case .unresolvable: return .unresolvable
        }
    }

    /// The channel a position was derived from, when it was derived rather than
    /// carried. The outbound side needs it: a position with no fragment to name
    /// it travels as a fraction, and only this says which one.
    public var basis: String? {
        if case .approximate(_, let basis, _, _) = self { return basis }
        return nil
    }

    public var bound: Bound? {
        if case .approximate(_, _, let bound, _) = self { return bound }
        return nil
    }

    public var refusalReason: String? {
        switch self {
        case .structural, .approximate: return nil
        case .ambiguous(_, let reason, _): return reason
        case .unresolvable(let reason, _): return reason
        }
    }
}

/// What came back from a Native Position, and what it could state about the
/// fields it wrote.
///
/// The mirror's `locations.progression` is a bare `Double?` because that is
/// Readium's shape, so the metric label has to come off to fit. **That drop is
/// the defect ADR-0009:73 describes**, and it is recorded at the point it
/// happens instead of being performed silently.
public struct LocatorExport: Sendable, Hashable, Codable {
    public var locator: ReadiumLocator
    /// What this export can state about itself. It states `progressionMetric`
    /// always, and the fate of `utf16Offset` / `nodeID` **only when it named
    /// the node with a fragment** — a fragment points at an element, so whether
    /// it holds the offset asked for is a fact about what was emitted. When no
    /// fragment went out, the position travelled as a fraction and only the
    /// resolution knows what it was re-derived from; the harness completes those
    /// two fields from `Resolution.basis`, and this list says nothing about them.
    public var provenance: [FieldProvenance]

    public init(locator: ReadiumLocator, provenance: [FieldProvenance]) {
        self.locator = locator
        self.provenance = provenance
    }
}

/// The only place Publication Position and Native Position are allowed to meet.
public enum LocationBridge {
    /// Publication Position → Native Position.
    ///
    /// **There is deliberately no href short-circuit.** Readium's
    /// `DefaultLocatorService.locate` returns the locator unchanged the moment
    /// the href is in the manifest (`DefaultLocatorService.swift:27-29`), which
    /// means a round-trip built on it passes trivially and resolves nothing. This
    /// bridge always walks the whole way down — unit, then node, then offset —
    /// and says which of them it used.
    public static func native(from locator: ReadiumLocator, in document: Document) -> Resolution {
        // The facts that hold whatever the resolution turns out to be. A field
        // the locator stated and a coordinate cannot hold is dropped either
        // way, so it is recorded before anything is resolved. Discovering these
        // only on the success paths is how a refusal came to report nothing
        // lost.
        var provenance = uncarriableProvenance(locator)

        let unit: DocumentUnit
        if let match = document.unit(withHref: locator.href) {
            unit = match
            provenance[.href] = .carried
        } else if let total = locator.locations.totalProgression,
                  let fallback = document.unit(coveringTotalProgression: total) {
            unit = fallback
            // The href named nothing; a different field is what found the unit.
            provenance[.href] = .discarded(reason: .hrefMatchesNoUnit)
        } else {
            provenance[.href] = .discarded(reason: .hrefMatchesNoUnit)
            return .unresolvable(
                reason: "href \(locator.href) matches no unit, and no totalProgression was supplied to fall back on",
                provenance: assemble(provenance)
            )
        }

        // A structural anchor beats a number, so ids are tried first — the same
        // order Readium's JavaScript uses (`utils.js:319-330`).
        if let fragment = locator.locations.fragments.first {
            if let element = unit.canonical.element(withID: fragment) {
                provenance[.fragments] = .carried
                return .structural(
                    NativePosition(
                        unitID: unit.id,
                        nodeID: .explicitID(fragment),
                        utf16Offset: element.utf16Range.lowerBound
                    ),
                    provenance: assemble(provenance)
                )
            }
            // A fragment that names nothing is not a resolution failure to paper
            // over by falling through to a number — it is a broken anchor, and
            // saying so is the point.
            provenance[.fragments] = .discarded(reason: .fragmentNamesNothing)
            return .unresolvable(
                reason: "fragment \"\(fragment)\" matches no element id in \(unit.href)",
                provenance: assemble(provenance)
            )
        }

        if let selector = locator.locations.cssSelector {
            // Only `#id` is understood. Anything richer is refused rather than
            // approximated, because a wrong answer here is indistinguishable
            // from a right one in the artifact.
            guard selector.hasPrefix("#"), selector.count > 1 else {
                provenance[.cssSelector] = .discarded(reason: .selectorNotUnderstood)
                return .unresolvable(
                    reason: "cssSelector \"\(selector)\" is not a plain #id selector, which is all this spike resolves",
                    provenance: assemble(provenance)
                )
            }
            let id = String(selector.dropFirst())
            guard let element = unit.canonical.element(withID: id) else {
                provenance[.cssSelector] = .discarded(reason: .selectorNamesNothing)
                return .unresolvable(
                    reason: "cssSelector \"\(selector)\" matches no element id in \(unit.href)",
                    provenance: assemble(provenance)
                )
            }
            provenance[.cssSelector] = .carried
            // The selector named the element, and the way back out spells that
            // same fact as a fragment. **Nothing was refused here** — a reason
            // enum has no case for a channel that succeeded, which is why the
            // old code's flat `"cssSelector"` entry was wrong: it made a
            // success look like a loss.
            provenance[.fragments] = .recomputed(basis: "cssSelector", bound: nil)
            return .structural(
                NativePosition(unitID: unit.id, nodeID: .explicitID(id), utf16Offset: element.utf16Range.lowerBound),
                provenance: assemble(provenance)
            )
        }

        if let progression = locator.locations.progression {
            guard unit.length > 0 else {
                provenance[.progression] = .discarded(reason: .unitCarriesNoText)
                return .unresolvable(
                    reason: "\(unit.href) carries no text, so a progression has nothing to point into",
                    provenance: assemble(provenance)
                )
            }
            // Clamped, because a progression outside 0...1 is a value Readium
            // will happily store and this bridge must still do something
            // defined with it.
            let clamped = min(max(progression, 0), 1)
            let offset = min(Int((clamped * Double(unit.length)).rounded()), unit.length)
            let nodeID: NodeID
            if let element = unit.canonical.innermostElement(containing: offset) {
                nodeID = element.explicitID.map { NodeID.explicitID($0) } ?? .path(element.path)
            } else if let last = unit.canonical.elements.last {
                nodeID = last.explicitID.map { NodeID.explicitID($0) } ?? .path(last.path)
            } else {
                provenance[.progression] = .discarded(reason: .unitHasNoAddressableElements)
                return .unresolvable(
                    reason: "\(unit.href) has no addressable elements",
                    provenance: assemble(provenance)
                )
            }
            // The clamped case keeps its own basis word. It is reachable, and
            // flattening it into "progression" would erase the only record that
            // the request was outside the range the field can name.
            let basis = progression == clamped ? "progression" : "progression (clamped)"
            // **The bound comes from the metric, not from taste.** ADR-0009 lays
            // this path down as bounded rather than exact, and that sentence had
            // no carrier in the artifact until now. A clamped request has no
            // bound to state — it named nothing — so it gets nil rather than a
            // plausible-looking number.
            let bound = progression == clamped
                ? Bound(
                    tolerance: CanonicalTextIndexAxis(document: document).seekTolerance,
                    unit: .canonicalTextIndex
                )
                : nil
            provenance[.progression] = .recomputed(basis: basis, bound: bound)
            provenance[.fragments] = .recomputed(basis: basis, bound: nil)
            return .approximate(
                NativePosition(unitID: unit.id, nodeID: nodeID, utf16Offset: offset),
                basis: basis,
                bound: bound,
                provenance: assemble(provenance)
            )
        }

        if let position = locator.locations.position {
            // A real finding, not a gap in this implementation: `position` is a
            // GLOBAL index across the reading order (`EPUBPositionsService.swift:98`,
            // `:141`), so it names a place only in the presence of the
            // publication's positions table. A Native Position is self-contained
            // and therefore cannot carry it — and a bridge that guessed would be
            // inventing a position numbering the publication never stated.
            provenance[.position] = .discarded(reason: .globalPositionNeedsThePositionsTable)
            return .unresolvable(
                reason: "a global `position` (\(position)) cannot be resolved without the publication's positions table, which is document-level state rather than a coordinate",
                provenance: assemble(provenance)
            )
        }

        if !locator.text.isEmpty {
            // Only the quote, no structural anchor and no number. This is the
            // "repeated text" case by construction: the bridge can find every
            // place the text occurs and cannot choose between them.
            let matches = unit.canonical.elements(withText: locator.text.highlight ?? "")
            if matches.count > 1 {
                return .ambiguous(
                    matches.map { element in
                        NativePosition(
                            unitID: unit.id,
                            nodeID: element.explicitID.map { NodeID.explicitID($0) } ?? .path(element.path),
                            utf16Offset: element.utf16Range.lowerBound
                        )
                    },
                    reason: "the locator's information admits \(matches.count) positions; choosing between them needs quote matching, which is ReanchorService's job",
                    provenance: assemble(provenance)
                )
            }
            if let only = matches.first {
                // The element is named, but by the quotation rather than by any
                // id the locator stated — the same fact by another channel.
                provenance[.fragments] = .recomputed(basis: "text.highlight", bound: nil)
                return .approximate(
                    NativePosition(
                        unitID: unit.id,
                        nodeID: only.explicitID.map { NodeID.explicitID($0) } ?? .path(only.path),
                        utf16Offset: only.utf16Range.lowerBound
                    ),
                    basis: "text.highlight",
                    bound: nil,
                    provenance: assemble(provenance)
                )
            }
        }

        return .unresolvable(
            reason: "the locator carries nothing this bridge can resolve: no fragment, cssSelector, progression, position or matching text",
            provenance: assemble(provenance)
        )
    }

    /// Native Position → Publication Position.
    ///
    /// What comes back is a *weaker* locator than the one that went in, and
    /// deliberately so: everything this bridge cannot know, it leaves out rather
    /// than inventing. The quote context that `AnchorValidator` and
    /// `ReanchorService` would need has no home in a Native Position, so it does
    /// not appear here — which is exactly the finding, not an oversight.
    public static func locator(
        from position: NativePosition,
        in document: Document
    ) -> LocatorExport? {
        guard let unit = document.unit(withID: position.unitID) else { return nil }
        let element = unit.canonical.innermostElement(containing: position.utf16Offset)

        var fragments: [String] = []
        if case .explicitID(let id) = position.nodeID {
            fragments = [id]
        } else if let id = element?.explicitID {
            fragments = [id]
        }

        var provenance: [LocatorField: Provenance] = [:]
        // The unit identity is intact: this function found the unit by the id
        // the position names.
        provenance[.unitID] = .carried

        // **The offset's fate is decided here, and only here**, because here is
        // the one place that holds both the offset asked for and the element the
        // emitted fragment actually names. Moving this comparison to the judge
        // is what let a `.structural` resolution be read as "carried" — and a
        // fragment names a whole element, so an offset inside one is *lost*, not
        // carried. Getting that wrong turns `native-id-anchored` back into a
        // perfect round trip, which is the round-two false positive returning
        // through the front door.
        if let id = fragments.first, let named = unit.canonical.element(withID: id) {
            provenance[.utf16Offset] = named.utf16Range.lowerBound == position.utf16Offset
                ? .carried
                : .lost
            provenance[.nodeID] = position.nodeID == .explicitID(id)
                ? .carried
                : .recomputed(basis: "utf16Offset", bound: nil)
        }
        // A position that travelled as a fraction states neither field here: the
        // resolution knows what it was re-derived from, and this export does
        // not. The harness completes them.

        // **Per-resource, and it has to stay per-resource.**
        //
        // `locations.progression` is what Readium's `EPUBPositionsService` mints
        // per resource, and `native(from:)` above inverts it against
        // `unit.length`. `CanonicalTextIndexAxis.progression` is a fraction of
        // the whole *publication* — a different number that names a different
        // place. The two are one substitution apart, and that substitution is
        // quiet: `native-path-anchored`'s offset 22 would come back as 9, the row
        // would fall from `recomputedEquivalent` into `loses(["utf16Offset"])`,
        // and **the census buckets would still sum to the number of rows**. Only
        // the value would be wrong.
        var progression: Double?
        if unit.length > 0 {
            let perUnit = Progression(
                value: Double(position.utf16Offset) / Double(unit.length),
                metric: .canonicalTextIndex
            )
            progression = perUnit.value
            provenance[.progressionMetric] = .discarded(reason: .metricHasNowhereToGo)
        }

        return LocatorExport(
            locator: ReadiumLocator(
                href: unit.href,
                mediaType: unit.mediaType,
                title: nil,
                locations: ReadiumLocator.Locations(
                    fragments: fragments,
                    progression: progression
                    // `totalProgression` is left out: it is a publication-level
                    // number, and the spike has no positions table to state it from.
                ),
                text: ReadiumLocator.Text()
            ),
            provenance: assemble(provenance)
        )
    }

    // MARK: - Assembling

    /// The facts that hold whatever the resolution turns out to be.
    private static func uncarriableProvenance(_ locator: ReadiumLocator) -> [LocatorField: Provenance] {
        var provenance: [LocatorField: Provenance] = [:]
        if locator.title != nil { provenance[.title] = .notCarriable }
        if !locator.text.isEmpty { provenance[.text] = .notCarriable }
        // **A field is reported only when the input stated it.** Reporting one
        // always, with `.carried` standing in for "it was not there", puts rows
        // in the report that no measurement produced — and, worse, invites a
        // verdict on a field whose absence is not a fact about the conversion.
        if locator.locations.totalProgression != nil { provenance[.totalProgression] = .documentLevel }
        // A global `position` is publication-level state either way. When it is
        // the *only* thing the locator carries, the branch below overwrites this
        // with the refusal — which is the stronger and more useful statement.
        if locator.locations.position != nil { provenance[.position] = .documentLevel }
        // `cssSelector` is stored inside `otherLocations`, so a locator with a
        // selector sets both. Reporting `otherLocations` as well would count one
        // fact twice and imply a second thing was lost that never existed.
        let otherKeys = locator.locations.otherLocations.keys.filter { $0 != "cssSelector" }
        if !otherKeys.isEmpty { provenance[.otherLocations] = .notCarriable }
        return provenance
    }

    /// Always in `LocatorField.allCases` order. **A dictionary's iteration order
    /// is seeded per process**, and these lists reach the artifact — three CI
    /// processes would otherwise hash three different payloads and the
    /// fingerprint comparison would fail rather than merely differ.
    public static func assemble(_ provenance: [LocatorField: Provenance]) -> [FieldProvenance] {
        var ordered: [FieldProvenance] = []
        for field in sortedFields(Array(provenance.keys)) {
            guard let value = provenance[field] else { continue }
            ordered.append(FieldProvenance(field: field, provenance: value))
        }
        return ordered
    }
}

extension Document {
    /// The unit whose share of the publication's length covers a total
    /// progression — this spike's model, stated in `CanonicalTextIndexAxis`.
    func unit(coveringTotalProgression total: Double) -> DocumentUnit? {
        guard totalLength > 0 else { return nil }
        let target = min(max(total, 0), 1) * Double(totalLength)
        var running = 0
        for unit in readingOrder {
            running += unit.length
            if Double(running) >= target { return unit }
        }
        return readingOrder.last
    }
}
