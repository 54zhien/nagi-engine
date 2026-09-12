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
        let trip = RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml#p1",
                mediaType: "application/xhtml+xml",
                locations: .init(fragments: ["p1"])
            ),
            in: document,
            label: "href-spelling"
        )
        XCTAssertTrue(
            trip.fields["href"] == .carried,
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
        guard case .unresolvable(let reason) = resolution else {
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
        guard case .ambiguous(let candidates) = resolution else {
            return XCTFail("expected ambiguity, got \(resolution)")
        }
        XCTAssertEqual(candidates.count, 2)
    }

    // MARK: - Round trips

    func testStructuralAnchorRoundTripsExactly() throws {
        let trip = RoundTripHarness.locatorToNativeToLocator(
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
        let trip = RoundTripHarness.locatorToNativeToLocator(
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
        XCTAssertTrue(trip.fields["text"] == .notCarriable)
        guard case .semanticEquivalent(let notes) = trip.outcome else {
            return XCTFail("expected semantic equivalence, got \(trip.outcome)")
        }
        XCTAssertTrue(notes.contains { $0.contains("quotation") }, "the note must name what was lost: \(notes)")
    }

    func testAmbiguousAndUnresolvableCasesNeedAReanchor() throws {
        let document = try document()
        let ambiguous = RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                text: .init(highlight: SpikeAFixture.repeatedText)
            ),
            in: document,
            label: "quotation-repeated"
        )
        XCTAssertTrue(ambiguous.needsReanchor)

        let missing = RoundTripHarness.locatorToNativeToLocator(
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
        let trip = RoundTripHarness.locatorToNativeToLocator(
            ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                locations: .init(progression: 0.5, totalProgression: 0.2, position: 7)
            ),
            in: try document(),
            label: "positions-service-shaped"
        )
        XCTAssertTrue(trip.fields["progression"] == .recomputed)
        XCTAssertTrue(trip.fields["position"] == .documentLevel)
        XCTAssertTrue(trip.fields["totalProgression"] == .documentLevel)
    }

    /// Native → Publication → Native is the direction a stored position
    /// depends on.
    func testNativePositionSurvivesTheRoundTrip() throws {
        let document = try document()
        let unit = try XCTUnwrap(document.unit(withID: "OEBPS/chap1.xhtml"))
        let p1 = try XCTUnwrap(unit.canonical.element(withID: "p1"))
        let trip = RoundTripHarness.nativeToLocatorToNative(
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

        let trip = RoundTripHarness.nativeToLocatorToNative(
            NativePosition(unitID: unit.id, nodeID: .explicitID("astral"), utf16Offset: offset),
            in: document,
            label: "native-inside-surrogate-pair"
        )
        XCTAssertTrue(
            trip.fields["utf16Offset"] == .lost,
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

        let trip = RoundTripHarness.nativeToLocatorToNative(
            NativePosition(unitID: unit.id, nodeID: .explicitID("p4"), utf16Offset: p4.utf16Range.lowerBound + 5),
            in: document,
            label: "native-mid-paragraph"
        )
        XCTAssertTrue(trip.fields["nodeID"] == .carried, "the paragraph is still named correctly")
        XCTAssertTrue(trip.fields["utf16Offset"] == .lost, "but the place inside it is not")
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

        let trip = RoundTripHarness.nativeToLocatorToNative(
            NativePosition(unitID: unit.id, nodeID: .path(anonymous.path), utf16Offset: offset),
            in: document,
            label: "native-path-anchored"
        )

        // The numbers agree — which is precisely why this case is the dangerous
        // one, and why the verdict has to be about provenance instead.
        XCTAssertTrue(
            trip.fields["utf16Offset"] == .recomputed,
            "equal, but rebuilt from a fraction rather than carried"
        )
        XCTAssertTrue(
            trip.fields["nodeID"] == .recomputed,
            "the node came back from that same recovered number, so it is implied by the offset rather than confirmed independently"
        )
        // There is no `href` field in this direction at all — see the comment in
        // `nativeToLocatorToNative`. It used to be reported as `.carried` on the
        // strength of comparing a unit's href with its own href.
        XCTAssertNil(trip.fields["href"], "a field that cannot vary must not be reported")
        guard case .recomputedEquivalent(let notes) = trip.outcome else {
            return XCTFail("expected a recomputed-equivalent verdict, got \(trip.outcome)")
        }
        XCTAssertTrue(
            notes.contains { $0.contains("progression") },
            "the note has to name the channel the value was rebuilt from, or a reader will think the number changed"
        )
    }
}
