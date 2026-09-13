import Foundation
import XCTest
@testable import SpikeAKit

/// The bridge, and what survives it.
///
/// These are the assertions that make Spike A's report mean something: each one
/// is a case whose classification would otherwise be an opinion.
final class IdentityTests: XCTestCase {

    private func document() throws -> Document {
        try SpikeAFixture.document()
    }

    // MARK: - The fixture itself

    /// The two chapters are byte-identical on purpose. If this ever stops being
    /// true, the href-routing case quietly stops testing anything.
    func testTheTwoChaptersAreIdenticalInContent() throws {
        let document = try document()
        let first = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let second = try XCTUnwrap(document.unit(withID: "OEBPS/chap2.xhtml"))
        XCTAssertEqual(first.canonical.string, second.canonical.string)
        XCTAssertNotEqual(first.id, second.id)
    }

    /// The whitespace between two elements belongs to neither of them, so a
    /// paragraph must not acquire a leading space from the one before it.
    func testInterElementWhitespaceDoesNotLeakIntoAnElement() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap3.xhtml"))
        let spaced = try XCTUnwrap(unit.canonical.element(withID: "spaced"))
        XCTAssertEqual(unit.canonical.text(in: spaced.utf16Range), "空白 折叠 测试")
    }

    // MARK: - Href

    func testHrefComparisonNormalisesTheWayReadiumDoes() {
        XCTAssertTrue(Href.isEquivalent("OEBPS/chap1.xhtml", "OEBPS/chap1.xhtml"))
        XCTAssertTrue(Href.isEquivalent("HTTPS://Example/a", "https://Example/a"), "the scheme is lowercased")
        XCTAssertTrue(Href.isEquivalent("OEBPS/chap1.xhtml?v=2", "OEBPS/chap1.xhtml"), "a query is stripped on the second pass")
        XCTAssertTrue(Href.isEquivalent("OEBPS/chap1.xhtml#p1", "OEBPS/chap1.xhtml"), "so is a fragment")
        XCTAssertFalse(Href.isEquivalent("OEBPS/chap1.xhtml", "OEBPS/chap2.xhtml"))
    }

    func testFragmentIsExtractedAndPercentDecoded() {
        XCTAssertEqual(Href.fragment(of: "chap1.xhtml#p%31"), "p1")
        XCTAssertEqual(Href.fragment(of: "chap1.xhtml"), nil)
        XCTAssertEqual(Href.removingFragment("chap1.xhtml#p1"), "chap1.xhtml")
    }

    /// The semantic href comparison driven all the way through the bridge, not
    /// asserted on `Href` alone. A fragment on the href names the same
    /// document; raw `==` at the comparison site would report it `.lost` and
    /// drop an otherwise perfect row out of `.exact`. Pinning it here means a
    /// regression has to break a test, not just change a number nobody reads.
    func testAFragmentSpelledIntoTheHrefStillNamesTheSameUnit() throws {
        let document = try document()
        let trip = try RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml#p1",
                mediaType: "application/xhtml+xml",
                locations: .init(fragments: ["p1"])
            ),
            in: document,
            label: "href-spelling"
        )
        XCTAssertTrue(
            trip.provenance(of: .href) == .carried,
            "a fragment on the href names the same resource, so the comparison has to be semantic"
        )
        XCTAssertEqual(trip.outcome, .exact)
    }

    // MARK: - The bridge, Publication Position → Native Position

    func testFragmentResolvesStructurally() throws {
        let resolution = LocationBridge.native(
            from: ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                locations: .init(fragments: ["p1"])
            ),
            in: try document()
        )
        guard case .structural(let position, _) = resolution else {
            return XCTFail("expected a structural resolution, got \(resolution)")
        }
        XCTAssertEqual(position.unitID, "OEBPS/chap1.xhtml")
        XCTAssertEqual(position.nodeID, .explicitID("p1"))

        // Invariants, not constants. Two earlier versions of this test pinned
        // absolute offsets from memory and were wrong both times — first because
        // `<title>` was counted as reading flow, then because a paragraph was
        // assumed to open the text when the heading before it does.
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let heading = try XCTUnwrap(unit.canonical.element(withID: "ch1"))
        let p1 = try XCTUnwrap(unit.canonical.element(withID: "p1"))

        XCTAssertEqual(position.utf16Offset, p1.utf16Range.lowerBound, "a fragment resolves to its element's start")
        XCTAssertEqual(heading.utf16Range.lowerBound, 0, "with `head` excluded, the heading opens the canonical text")
        XCTAssertEqual(
            unit.canonical.text(in: p1.utf16Range),
            "韩立望着眼前的山谷，沉默了片刻。",
            "and the element it names is the paragraph, not something that merely starts at the same offset"
        )
    }

    /// The same id exists in both chapters at the same path with the same text.
    /// Only the href can tell them apart, and this is where that shows.
    func testTheSameIDInTwoIdenticalUnitsResolvesToDifferentUnits() throws {
        let document = try document()
        func unitID(_ href: String) -> String? {
            LocationBridge.native(
                from: ReadiumLocator(href: href, mediaType: "application/xhtml+xml", locations: .init(fragments: ["p1"])),
                in: document
            ).position?.unitID
        }
        XCTAssertEqual(unitID("OEBPS/chap1.xhtml"), "OEBPS/chap1.xhtml")
        XCTAssertEqual(unitID("OEBPS/chap2.xhtml"), "OEBPS/chap2.xhtml")
    }

    /// A broken anchor is a result, not something to fall through from.
    func testFragmentNamingNothingIsUnresolvable() throws {
        let resolution = LocationBridge.native(
            from: ReadiumLocator(href: "OEBPS/chap1.xhtml", mediaType: "application/xhtml+xml", locations: .init(fragments: ["p99"])),
            in: try document()
        )
        guard case .unresolvable(let reason, _) = resolution else {
            return XCTFail("expected unresolvable, got \(resolution)")
        }
        XCTAssertTrue(reason.contains("p99"))
    }

    /// A global `position` names a place only alongside the publication's
    /// positions table, which a Native Position is not.
    func testGlobalPositionAloneIsUnresolvable() throws {
        let resolution = LocationBridge.native(
            from: ReadiumLocator(href: "OEBPS/chap1.xhtml", mediaType: "application/xhtml+xml", locations: .init(position: 42)),
            in: try document()
        )
        guard case .unresolvable = resolution else {
            return XCTFail("expected unresolvable, got \(resolution)")
        }
    }

    func testPlainIDSelectorResolvesAndARicherOneDoesNot() throws {
        let document = try document()
        let simple = LocationBridge.native(
            from: ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                locations: .init(otherLocations: ["cssSelector": .string("#p4")])
            ),
            in: document
        )
        guard case .structural(let position, _) = simple else {
            return XCTFail("expected a structural resolution, got \(simple)")
        }
        XCTAssertEqual(position.nodeID, .explicitID("p4"))

        let complex = LocationBridge.native(
            from: ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                locations: .init(otherLocations: ["cssSelector": .string("body > p:nth-child(3)")])
            ),
            in: document
        )
        guard case .unresolvable = complex else {
            return XCTFail("a selector richer than #id must be refused, not guessed at")
        }
    }

    /// The fixture's whole point for this axis: the same sentence twice, once
    /// with an id and once without.
    func testRepeatedQuotationIsAmbiguous() throws {
        let resolution = LocationBridge.native(
            from: ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                text: .init(highlight: SpikeAFixture.repeatedText)
            ),
            in: try document()
        )
        guard case .ambiguous(let candidates, _, _) = resolution else {
            return XCTFail("expected ambiguity, got \(resolution)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    // MARK: - Round trips

    func testStructuralAnchorRoundTripsExactly() throws {
        let trip = try RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(href: "OEBPS/chap1.xhtml", mediaType: "application/xhtml+xml", locations: .init(fragments: ["p1"])),
            in: try document(),
            label: "id-anchored"
        )
        XCTAssertEqual(trip.outcome, .exact, "a structural anchor has nothing to approximate")
        XCTAssertTrue(trip.needsValidator, "even an exact conversion cannot confirm the content without a validator")
    }

    /// The quotation is the part that cannot come back, and it is the reason
    /// `AnchorValidator` exists rather than being optional.
    func testQuotationDoesNotSurviveTheNativePosition() throws {
        let trip = try RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                locations: .init(fragments: ["p1"]),
                text: .init(after: "山谷", before: "", highlight: "韩立望着眼前")
            ),
            in: try document(),
            label: "id-anchored-with-quotation"
        )
        // `==` rather than `XCTAssertEqual`: a leading-dot member against a
        // dictionary subscript leaves the generic parameter unresolved, and the
        // compiler reports it as "type 'Equatable' has no member …".
        XCTAssertTrue(trip.provenance(of: .text) == .notCarriable)
        guard case .semanticEquivalent(let notes) = trip.outcome else {
            return XCTFail("expected semantic equivalence, got \(trip.outcome)")
        }
        XCTAssertTrue(notes.contains { $0.contains("quotation") }, "the note must name what was lost: \(notes)")
    }

    func testAmbiguousAndUnresolvableCasesNeedAReanchor() throws {
        let document = try document()
        let ambiguous = try RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                text: .init(highlight: SpikeAFixture.repeatedText)
            ),
            in: document,
            label: "quotation-repeated"
        )
        XCTAssertTrue(ambiguous.needsReanchor)

        let missing = try RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(href: "OEBPS/chap1.xhtml", mediaType: "application/xhtml+xml", locations: .init(fragments: ["p99"])),
            in: document,
            label: "fragment-names-nothing"
        )
        XCTAssertTrue(missing.needsReanchor)
        guard case .requiresReanchor = missing.outcome else {
            return XCTFail("expected requiresReanchor, got \(missing.outcome)")
        }
    }

    /// A locator minted the way Readium's positions service mints them: a
    /// progression, a global position and a totalProgression, no anchor.
    func testPositionsServiceShapedLocatorIsApproximateAndLosesTheGlobalNumbering() throws {
        let trip = try RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                locations: .init(progression: 0.5, totalProgression: 0.2, position: 7)
            ),
            in: try document(),
            label: "positions-service-shaped"
        )
        XCTAssertTrue(trip.provenance(of: .progression)?.isDerived == true)
        XCTAssertTrue(trip.provenance(of: .position) == .documentLevel)
        XCTAssertTrue(trip.provenance(of: .totalProgression) == .documentLevel)
    }

    /// Native → Publication → Native is the direction a stored position
    /// depends on.
    func testNativePositionSurvivesTheRoundTrip() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let p1 = try XCTUnwrap(unit.canonical.element(withID: "p1"))
        let trip = try RoundTripHarness.nativeToLocatorToNative(
            NativePosition(unitID: unit.id, nodeID: .explicitID("p1"), utf16Offset: p1.utf16Range.lowerBound),
            in: document,
            label: "native-id-anchored"
        )
        XCTAssertEqual(trip.outcome, .exact)
    }

    /// A finding rather than a defect, and it was the first CI run that produced
    /// it: **a fragment names a whole element, so it cannot carry an offset
    /// inside one.** Any offset that is not the element's start is lost on the
    /// way back.
    ///
    /// The fixture puts the offset in the middle of a non-BMP character, which
    /// makes the loss visible, but the loss would be identical for an offset at
    /// character five of a paragraph. Closing the gap needs a mechanism this
    /// bridge does not emit — `domRange` with `charOffset`, say — and Readium's
    /// own JavaScript producer does not emit one either (`dom.js:55-67`), so the
    /// gap is real on both sides rather than a shortcut taken here.
    ///
    /// **What does not close it**: the very same locator also carries a
    /// `progression`, and inverting that would hand the offset straight back.
    /// ADR-0009 forbids it — "精确的阅读位置恢复不得经由 `Double` progression
    /// 往返" — and it is why the sibling row with no fragment resolves only
    /// `.approximate`. The gap is a property of the coordinate system, not of
    /// this bridge's diligence.
    func testSubElementPrecisionIsLostThroughAFragmentAnchoredLocator() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap3.xhtml"))
        let astral = try XCTUnwrap(unit.canonical.element(withID: "astral"))
        let offset = astral.utf16Range.lowerBound + 4
        XCTAssertTrue(unit.canonical.isMidCharacter(offset), "the fixture must still place this inside a character")

        let trip = try RoundTripHarness.nativeToLocatorToNative(
            NativePosition(unitID: unit.id, nodeID: .explicitID("astral"), utf16Offset: offset),
            in: document,
            label: "native-inside-surrogate-pair"
        )
        XCTAssertTrue(
            trip.provenance(of: .utf16Offset) == .lost,
            "a fragment names the element, not an offset within it"
        )
        guard case .loses(let fields) = trip.outcome else {
            return XCTFail("expected the offset to be reported as lost, got \(trip.outcome)")
        }
        XCTAssertTrue(fields.contains("utf16Offset"))
    }

    /// The other half of the same finding: the element identity itself does
    /// survive, so what comes back is the right paragraph with the wrong
    /// position inside it. That is the worst shape of failure for an annotation
    /// — plausible, and off by a few characters.
    func testTheElementSurvivesEvenWhenTheOffsetDoesNot() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let p4 = try XCTUnwrap(unit.canonical.element(withID: "p4"))

        let trip = try RoundTripHarness.nativeToLocatorToNative(
            NativePosition(unitID: unit.id, nodeID: .explicitID("p4"), utf16Offset: p4.utf16Range.lowerBound + 5),
            in: document,
            label: "native-mid-paragraph"
        )
        XCTAssertTrue(trip.provenance(of: .nodeID) == .carried, "the paragraph is still named correctly")
        XCTAssertTrue(trip.provenance(of: .utf16Offset) == .lost, "but the place inside it is not")
    }

    /// The counterpart of the two above, and the reason neither of them is the
    /// whole story: when the node has no id the locator gets **no fragment at
    /// all**, so the only channel left for the position is a progression —
    /// which ADR-0009 forbids using to recover a reading position exactly.
    ///
    /// The offset does come back, and it comes back *equal*. It is still not
    /// carried: the bridge inverted a fraction to rebuild it, and that inversion
    /// is exact for every offset this fixture can reach, so the equality was
    /// never capable of failing. Calling it `.exact` would claim a precision the
    /// Progression path does not have — ADR-0009 gives that path a bounded
    /// tolerance. So both fields are `.recomputed`, not `.carried`: equal is
    /// not the same as carried.
    ///
    /// This row had no test at all before, which is how it stayed wrong.
    func testAPathAnchoredPositionIsRebuiltRatherThanCarried() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let anonymous = try XCTUnwrap(
            unit.canonical.elements.first { $0.name == "p" && $0.explicitID == nil },
            "the fixture must still carry a paragraph with no id"
        )
        let offset = anonymous.utf16Range.lowerBound + 1

        let trip = try RoundTripHarness.nativeToLocatorToNative(
            NativePosition(unitID: unit.id, nodeID: .path(anonymous.path), utf16Offset: offset),
            in: document,
            label: "native-path-anchored"
        )

        // The numbers agree — which is precisely why this case is the dangerous
        // one, and why the verdict has to be about provenance instead.
        XCTAssertTrue(
            trip.provenance(of: .utf16Offset)?.isDerived == true,
            "equal, but rebuilt from a fraction rather than carried"
        )
        XCTAssertTrue(
            trip.provenance(of: .nodeID)?.isDerived == true,
            "the node came back from that same recovered number, so it is implied by the offset rather than confirmed independently"
        )
        // There is no `href` field in this direction at all — see the comment in
        // `nativeToLocatorToNative`. It used to be reported as `.carried` on the
        // strength of comparing a unit's href with its own href.
        XCTAssertNil(trip.resolution(of: .href), "a field that cannot vary must not be reported")
        guard case .recomputedEquivalent(let notes) = trip.outcome else {
            return XCTFail("expected a recomputed-equivalent verdict, got \(trip.outcome)")
        }
        XCTAssertTrue(
            notes.contains { $0.contains("progression") },
            "the note has to name the channel the value was rebuilt from, or a reader will think the number changed"
        )
    }

    /// The channel a rebuilt value came from, and every name it was dropped
    /// under, both reach the row. The inbound half of that list used to be
    /// pattern-discarded at its only call site (`if case .approximate(_, let
    /// basis, _)`) — not merely unread, thrown away.
    func testADerivedRowNamesTheChannelItWasRebuiltFrom() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let anonymous = try XCTUnwrap(
            unit.canonical.elements.first { $0.name == "p" && $0.explicitID == nil }
        )

        let trip = try RoundTripHarness.nativeToLocatorToNative(
            NativePosition(
                unitID: unit.id,
                nodeID: .path(anonymous.path),
                utf16Offset: anonymous.utf16Range.lowerBound + 1
            ),
            in: document,
            label: "native-path-anchored"
        )
        // The channel is now a property of the field rather than of the row, so
        // it says which field came back that way — and with what guarantee.
        // `==` rather than `XCTAssertEqual`: an optional on the left and a
        // leading-dot member on the right leaves the generic parameter
        // unresolved, and the compiler reports it as "type 'Equatable' has no
        // member …". `tasks/lessons.md` records this being forgotten once
        // already in this package.
        let expectedBound = Bound(
            tolerance: CanonicalTextIndexAxis(document: document).seekTolerance,
            unit: .canonicalTextIndex
        )
        XCTAssertTrue(
            trip.provenance(of: .utf16Offset) == .recomputed(basis: .progression(bound: expectedBound))
        )
        XCTAssertEqual(trip.provenance(of: .nodeID)?.isDerived, true)
        // The metric label is an **observation** on the row, not a row in the
        // field table. A table row for it made `exact` readable on a row whose
        // own table said `refused` — the field was never the input's to state.
        XCTAssertTrue(
            trip.observations.contains { $0.kind == .metricDroppedToFitTheMirror },
            "the mirror's bare Double is where the metric label goes, and saying so is not a field verdict"
        )
        XCTAssertTrue(
            trip.observations.contains { $0.kind == .scopeDroppedToFitTheMirror },
            "the number written there is resource-scoped, and the mirror has no field to say so"
        )
    }

    /// **The basis is a type, and one of its cases has no row in the corpus.**
    ///
    /// `RecomputeBasis.utf16Offset` is reached when the export emits a fragment
    /// naming an element whose id the position's own `nodeID` does **not** name —
    /// a path-rung identity sitting inside an element that has one. No fixture
    /// case does that (`native-path-anchored` sits in an anonymous paragraph, so
    /// no fragment goes out at all), so without this the case would be vocabulary
    /// with zero coverage.
    ///
    /// Covered here rather than by a new corpus row on purpose: adding a case
    /// moves the census, and this round's whole criterion is that the census
    /// does not move. A unit test pins the case without touching a number.
    func testTheOffsetBasisIsReachableWhenAPathRungIdentitySitsInAnIdentifiedElement() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let identified = try XCTUnwrap(unit.canonical.element(withID: "dup"))

        let trip = try RoundTripHarness.nativeToLocatorToNative(
            NativePosition(
                unitID: unit.id,
                nodeID: .path(identified.path),
                utf16Offset: identified.utf16Range.lowerBound
            ),
            in: document,
            label: "native-path-inside-an-identified-element"
        )

        XCTAssertTrue(
            trip.provenance(of: .nodeID) == .recomputed(basis: .utf16Offset),
            "the export names the element by its id and the position named it by path, so the node came back from the offset"
        )
        // The offset itself is the element's start, so a fragment *can* carry
        // it — which is what keeps this row from being a second loss.
        XCTAssertTrue(trip.provenance(of: .utf16Offset) == .carried)
    }

    /// **`exact` is not reachable from a table containing a refusal.**
    ///
    /// The reducer looked for losses, derivations and uncarriable fields, and a
    /// `.discarded` is none of the three — so it fell through to `exact`. Nothing
    /// caught it because every row carrying a refusal was a row with **no
    /// position**, and those are judged by their shape before any field rule
    /// runs. The mixed locator is the first row that has both.
    func testARefusedFieldKeepsExactOutOfReach() throws {
        let document = try document()
        let testCase = try XCTUnwrap(
            SpikeACases.locatorCases.first { $0.label == "mixed-evidence-locator" }
        )
        let trip = try RoundTripHarness.locatorToNativeToLocator(
            testCase.locator,
            in: document,
            label: testCase.label
        )

        // The fragment named the element, so this row has a position — that is
        // the premise the test rests on, and without it the shape rule would
        // decide the outcome and prove nothing.
        guard case .semanticEquivalent = trip.outcome else {
            return XCTFail("expected a semantic-equivalent verdict, got \(trip.outcome)")
        }
        XCTAssertTrue(
            trip.provenance(of: .progression) == .discarded(reason: .aMorePreciseAnchorResolvedIt)
        )
        XCTAssertTrue(
            trip.provenance(of: .cssSelector) == .discarded(reason: .aMorePreciseAnchorResolvedIt)
        )
        // Every field the locator stated has a row, and no row is missing.
        let stated = Set(LocatorField.allCases.filter { $0.isStated(by: testCase.locator) })
        XCTAssertEqual(Set(trip.transportResolutions.map(\.field)), stated)
    }

    /// **The flag is a measurement, not a constant.**
    ///
    /// It used to be written `true` unconditionally, so twenty rows out of
    /// twenty claimed a validator's work to do — including the six that had
    /// nothing to hand one. Every other assertion in this file checks the flag is
    /// *true* somewhere, so putting the unconditional `true` back would change no
    /// test at all: it would move a number in a report and nothing else. A fix
    /// whose only witness is a human reading a detail line is the defect this
    /// project keeps finding, so the negative case is asserted here.
    func testARowWithNoCandidateDoesNotClaimAValidator() throws {
        let document = try document()

        // **No candidate.** The selector is richer than a plain `#id`, so the
        // bridge refuses it rather than guessing, and a validator has nothing to
        // confirm — it goes straight to ReanchorService.
        let unresolvable = try RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                locations: .init(otherLocations: ["cssSelector": .string("body > p:nth-child(3)")])
            ),
            in: document,
            label: "js-shaped-complex-selector"
        )
        XCTAssertFalse(unresolvable.needsValidator)
        XCTAssertNil(
            unresolvable.validatorReason,
            "a reason attached to a flag that is off reads as though a validator had been asked and declined"
        )
        XCTAssertTrue(unresolvable.needsReanchor)

        // **Several candidates.** This is the row the flag is for: choosing
        // between them is exactly a validator's work, and it is also a row with
        // no single position — which is why it appears in both lists.
        let ambiguous = try RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                text: .init(highlight: SpikeAFixture.repeatedText)
            ),
            in: document,
            label: "quotation-repeated"
        )
        XCTAssertTrue(ambiguous.needsValidator)
        XCTAssertTrue(ambiguous.needsReanchor)
    }

    /// **The third shape that produces no candidate, and the only one whose field
    /// table is empty.**
    ///
    /// Its siblings are covered above: several candidates (`.ambiguous`) and none
    /// resolvable (`.unresolvable`). This one is `ResolutionShape.notExpressible`
    /// — "the position could not be written out at all" — and no other corpus row
    /// reaches it, because every other native row draws its `unitID` from a unit
    /// the fixture has.
    ///
    /// **Why the census was not enough.** The census counts rows and buckets; it
    /// does not fail when a row changes *what it says* without leaving its
    /// bucket. This very shape has been silently wrong before — it used to return
    /// a validator verdict, which is what hid the path. `tasks/lessons.md` records
    /// the same gap for `native-path-anchored`, which stayed mis-judged because
    /// nothing asserted on it.
    ///
    /// The case is read back from the corpus instead of rebuilt here, so the row
    /// and this test cannot drift apart.
    func testAPositionInAUnitThatNoLongerExistsIsNotExpressible() throws {
        let document = try document()
        let testCase = try XCTUnwrap(
            SpikeACases.nativeCases(document)
                .first { $0.label == "native-position-in-a-unit-that-no-longer-exists" }
        )

        // **The premise, asserted rather than assumed.** The corpus names this
        // unit instead of looking it up, so the day a unit of that name exists
        // the row would quietly become a different measurement.
        XCTAssertNil(
            document.unit(withID: testCase.position.unitID),
            "this case is only about a missing unit while that unit is missing"
        )

        let trip = try RoundTripHarness.nativeToLocatorToNative(
            testCase.position,
            in: document,
            label: testCase.label
        )

        // No candidate, so a validator has nothing to confirm.
        XCTAssertFalse(trip.needsValidator)
        // No position either, so it goes to ReanchorService.
        XCTAssertTrue(trip.needsReanchor)

        // **No field table at all**, which is what separates this shape from
        // `.unresolvable`. `locator(from:)` returned nil before a single field
        // could be stated, so there is no fate to report — not an empty answer,
        // but no answer. Reading this as "nothing was lost" is how a resolution
        // failure came to be reported as a clean round trip in an earlier round.
        XCTAssertTrue(
            trip.transportResolutions.isEmpty,
            "a position that could not be written out has no field whose fate it can state"
        )

        guard case .requiresReanchor(let reason) = trip.outcome else {
            return XCTFail("expected a reanchor, got \(trip.outcome)")
        }
        XCTAssertTrue(
            reason.contains("could not be expressed"),
            "the reason should name what happened, not merely that something did: \(reason)"
        )
    }

    /// **The number written into `locations.progression` is per resource, and
    /// that is not a detail.**
    ///
    /// The field's EPUB semantics are `readiumPositions`, and `native(from:)`
    /// inverts it against `unit.length`. `CanonicalTextIndexAxis.progression` is
    /// a fraction of the whole **publication** — a different number naming a
    /// different place. Swapping them is one substitution away and it is quiet:
    /// this row's offset 22 would come back as 9, the row would fall from
    /// `recomputedEquivalent` into `loses(["utf16Offset"])`, and the census
    /// buckets would still sum to the number of rows.
    func testTheProgressionWrittenIntoTheLocatorIsPerResource() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let anonymous = try XCTUnwrap(
            unit.canonical.elements.first { $0.name == "p" && $0.explicitID == nil }
        )
        let position = NativePosition(
            unitID: unit.id,
            nodeID: .path(anonymous.path),
            utf16Offset: anonymous.utf16Range.lowerBound + 1
        )

        let exported = try XCTUnwrap(LocationBridge.locator(from: position, in: document))
        let written = try XCTUnwrap(exported.locator.locations.progression)

        // Stated as a relation against the fixture, not as a constant — this
        // repository has pinned absolute offsets from memory and been wrong.
        XCTAssertEqual(written, Double(position.utf16Offset) / Double(unit.length))

        let atPublicationLevel = try XCTUnwrap(
            CanonicalTextIndexAxis(document: document).progression(of: position)
        )
        XCTAssertNotEqual(
            written,
            atPublicationLevel.value,
            "the two candidate numbers must actually differ, or this test proves nothing"
        )

        XCTAssertTrue(
            exported.observations.contains { $0.kind == .metricDroppedToFitTheMirror },
            "the label cannot come along, so the drop has to be recorded"
        )
        // **The scope half, and it is the new half.** The two candidates above
        // differ by scope as well as by metric, and until this round the type
        // could not tell them apart — the substitution would have moved this
        // offset from 22 to 9 with every census bucket still adding up. The
        // assertion is on the unit's own id rather than on the word "resource",
        // because `.publication` is the specific wrong answer being excluded.
        let scopeObservations = exported.observations.filter {
            $0.kind == .scopeDroppedToFitTheMirror
        }
        XCTAssertEqual(scopeObservations.count, 1)
        XCTAssertTrue(
            scopeObservations[0].described.contains(unit.id),
            "the scope has to name the resource it reaches over, or the observation says nothing"
        )
        XCTAssertFalse(
            scopeObservations[0].described.contains("publication-wide"),
            "the number written into locations.progression is resource-local, and calling it publication-wide is the substitution the type now forbids"
        )
    }

    /// The fixture must still carry a unit with no text: the empty-unit tie is
    /// the only place a prefix sum off by one is visible, and it disappears
    /// silently if the fixture loses the unit.
    func testTheFixtureStillCarriesAnEmptyUnit() throws {
        let document = try document()
        let blank = try XCTUnwrap(document.unit(withID: "OEBPS/blank.xhtml"))
        XCTAssertEqual(blank.canonical.utf16Count, 0)
        XCTAssertGreaterThan(document.readingOrder.count, 1)
        let index = try XCTUnwrap(document.readingOrder.firstIndex { $0.id == blank.id })
        XCTAssertTrue(
            index > 0 && index < document.readingOrder.count - 1,
            "it has to sit between two units with text, or it has no neighbour to tie with"
        )
    }
}
