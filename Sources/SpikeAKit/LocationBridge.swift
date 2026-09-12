import Foundation

/// How a Publication Position became a Native Position.
///
/// The cases are deliberately not "success / failure". ADR-0004 says the three
/// anchoring responsibilities must not be merged, and the only way to see which
/// of them a given conversion needs is to have the conversion say what it
/// actually did.
public enum Resolution: Sendable, Hashable {
    /// Derived from a structural anchor — an element id. Nothing was
    /// approximated: the same document gives the same answer, and the answer
    /// names a node rather than an offset in a number line.
    case structural(NativePosition, discarded: [String])

    /// Derived from a numeric location. The neighbourhood is right, but the
    /// offset is this bridge's arithmetic rather than anything the locator
    /// stated.
    case approximate(NativePosition, basis: String, discarded: [String])

    /// The locator's own information admits more than one position. Readium's
    /// JavaScript produces exactly this shape: `dom.js:55-67` emits a
    /// `cssSelector` plus an unbounded `text.highlight` and nothing else.
    case ambiguous([NativePosition], discarded: [String])

    /// Structurally impossible, with the reason spelled out.
    case unresolvable(String, discarded: [String])

    public var position: NativePosition? {
        switch self {
        case .structural(let position, _): return position
        case .approximate(let position, _, _): return position
        case .ambiguous, .unresolvable: return nil
        }
    }

    /// **Every case carries this, including the two that carry no position.**
    ///
    /// It used to be computed for all four and returned for only two, so a case
    /// that failed to resolve reported that nothing was dropped — even when the
    /// bridge had already filtered a quotation or an href into a list it then
    /// threw away. A refusal is not the same as an empty list, and the report is
    /// read by people who cannot tell the difference unless the type makes them
    /// able to.
    public var discarded: [String] {
        switch self {
        case .structural(_, let discarded): return discarded
        case .approximate(_, _, let discarded): return discarded
        case .ambiguous(_, let discarded): return discarded
        case .unresolvable(_, let discarded): return discarded
        }
    }
}

/// What came back from a Native Position, and what the locator had nowhere to
/// put.
///
/// The mirror's `locations.progression` is a bare `Double?` because that is
/// Readium's shape, so the metric label has to come off to fit. **That drop is
/// the defect ADR-0009:73 describes**, and it is now recorded at the point it
/// happens instead of being performed silently — which is the difference between
/// a known limitation and a bug nobody can see.
public struct LocatorExport: Sendable, Hashable, Codable {
    public var locator: ReadiumLocator
    public var discarded: [String]

    public init(locator: ReadiumLocator, discarded: [String]) {
        self.locator = locator
        self.discarded = discarded
    }
}

/// The only place Publication Position and Native Position are allowed to meet.
public enum LocationBridge {
    /// Every locator field a Native Position has no room for.
    ///
    /// This list is the reason `AnchorValidator` and `ReanchorService` exist: a
    /// Native Position is a coordinate, and a coordinate cannot say "this used
    /// to be the paragraph that said X".
    ///
    /// `mediaType` and `href` are deliberately absent — both come back from the
    /// unit the position names, so nothing is lost. `title` does not: it is
    /// navigation metadata, and a position has no place for it.
    public static let notCarriableByNativePosition = ["title", "text"]

    /// Publication Position → Native Position.
    ///
    /// **There is deliberately no href short-circuit.** Readium's
    /// `DefaultLocatorService.locate` returns the locator unchanged the moment
    /// the href is in the manifest (`DefaultLocatorService.swift:27-29`), which
    /// means a round-trip built on it passes trivially and resolves nothing. This
    /// bridge always walks the whole way down — unit, then node, then offset —
    /// and says which of them it used.
    public static func native(from locator: ReadiumLocator, in document: Document) -> Resolution {
        // Computed **before** anything resolves, because these are fields the
        // locator carries and a Native Position can never hold: they are dropped
        // whether or not the resolution succeeds. Discovering them only on the
        // success paths is how a refusal came to report that nothing was lost.
        var discarded = notCarriableByNativePosition.filter { field in
            switch field {
            case "title": return locator.title != nil
            case "text": return !locator.text.isEmpty
            default: return false
            }
        }

        let unit: DocumentUnit
        if let match = document.unit(withHref: locator.href) {
            unit = match
        } else if let total = locator.locations.totalProgression,
                  let fallback = document.unit(coveringTotalProgression: total) {
            unit = fallback
            // The href named nothing; a different field is what found the unit.
            discarded.append("href")
        } else {
            return .unresolvable(
                "href \(locator.href) matches no unit, and no totalProgression was supplied to fall back on",
                discarded: discarded + ["href"]
            )
        }

        // A structural anchor beats a number, so ids are tried first — the same
        // order Readium's JavaScript uses (`utils.js:319-330`).
        if let fragment = locator.locations.fragments.first {
            if let element = unit.canonical.element(withID: fragment) {
                return .structural(
                    NativePosition(
                        unitID: unit.id,
                        nodeID: .explicitID(fragment),
                        utf16Offset: element.utf16Range.lowerBound
                    ),
                    discarded: discarded
                )
            }
            // A fragment that names nothing is not a resolution failure to paper
            // over by falling through to a number — it is a broken anchor, and
            // saying so is the point.
            return .unresolvable(
                "fragment \"\(fragment)\" matches no element id in \(unit.href)",
                discarded: discarded + ["fragments"]
            )
        }

        if let selector = locator.locations.cssSelector {
            // Only `#id` is understood. Anything richer is refused rather than
            // approximated, because a wrong answer here is indistinguishable
            // from a right one in the artifact.
            guard selector.hasPrefix("#"), selector.count > 1 else {
                return .unresolvable(
                    "cssSelector \"\(selector)\" is not a plain #id selector, which is all this spike resolves",
                    discarded: discarded + ["cssSelector"]
                )
            }
            let id = String(selector.dropFirst())
            guard let element = unit.canonical.element(withID: id) else {
                return .unresolvable(
                    "cssSelector \"\(selector)\" matches no element id in \(unit.href)",
                    discarded: discarded + ["cssSelector"]
                )
            }
            return .structural(
                NativePosition(unitID: unit.id, nodeID: .explicitID(id), utf16Offset: element.utf16Range.lowerBound),
                discarded: discarded + ["cssSelector"]
            )
        }

        if let progression = locator.locations.progression {
            guard unit.length > 0 else {
                return .unresolvable(
                    "\(unit.href) carries no text, so a progression has nothing to point into",
                    discarded: discarded + ["progression"]
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
                return .unresolvable(
                    "\(unit.href) has no addressable elements",
                    discarded: discarded + ["progression"]
                )
            }
            return .approximate(
                NativePosition(unitID: unit.id, nodeID: nodeID, utf16Offset: offset),
                basis: progression == clamped ? "progression" : "progression (clamped)",
                discarded: discarded + ["progression"]
            )
        }

        if let position = locator.locations.position {
            // A real finding, not a gap in this implementation: `position` is a
            // GLOBAL index across the reading order (`EPUBPositionsService.swift:98`,
            // `:141`), so it names a place only in the presence of the
            // publication's positions table. A Native Position is self-contained
            // and therefore cannot carry it — and a bridge that guessed would be
            // inventing a position numbering the publication never stated.
            return .unresolvable(
                "a global `position` (\(position)) cannot be resolved without the publication's positions table, which is document-level state rather than a coordinate",
                discarded: discarded + ["position"]
            )
        }

        if !locator.text.isEmpty {
            // Only the quote, no structural anchor and no number. This is the
            // "repeated text" case by construction: the bridge can find every
            // place the text occurs and cannot choose between them.
            //
            // `discarded` already names `text` — that is the whole finding of
            // this case, and it is a drop like any other.
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
                    discarded: discarded
                )
            }
            if let only = matches.first {
                return .approximate(
                    NativePosition(
                        unitID: unit.id,
                        nodeID: only.explicitID.map { NodeID.explicitID($0) } ?? .path(only.path),
                        utf16Offset: only.utf16Range.lowerBound
                    ),
                    basis: "text.highlight",
                    discarded: discarded
                )
            }
        }

        // `unknown-href-with-fallback` lands here, and its `discarded` names the
        // href — which is the only thing that found the unit and still could not
        // name a place inside it. That list used to be empty.
        return .unresolvable(
            "the locator carries nothing this bridge can resolve: no fragment, cssSelector, progression, position or matching text",
            discarded: discarded
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
        //
        // The metric cannot come along — the field is a bare `Double?` because
        // that is Readium's shape — so the drop is recorded here.
        var progression: Double?
        var discarded: [String] = []
        if unit.length > 0 {
            let perUnit = Progression(
                value: Double(position.utf16Offset) / Double(unit.length),
                metric: .canonicalTextIndex
            )
            progression = perUnit.value
            discarded.append("progression.metric")
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
            discarded: discarded
        )
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
