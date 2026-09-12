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
        XCTAssertEqual(position.utf16Offset, 0, "p1 is the first text in the body")
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
                text: .init(before: "", highlight: "韩立望着眼前", after: "山谷")
            ),
            in: try document(),
            label: "id-anchored-with-quotation"
        )
        XCTAssertEqual(trip.fields["text"], .notCarriable)
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
        XCTAssertEqual(trip.fields["progression"], .recomputed)
        XCTAssertEqual(trip.fields["position"], .documentLevel)
        XCTAssertEqual(trip.fields["totalProgression"], .documentLevel)
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

    /// The bridge is faithful, and that includes being faithful to an offset
    /// that is not a text boundary: it neither produces nor repairs one. Snapping
    /// is `PositionResolver`'s job (ADR-0004), and this is the evidence for
    /// keeping that layer separate.
    func testAnOffsetInsideASurrogatePairIsCarriedThroughUnchanged() throws {
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
        XCTAssertEqual(trip.fields["utf16Offset"], .reproduced, "the bridge does not round, and does not snap")
    }
}
