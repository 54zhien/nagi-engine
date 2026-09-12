import Foundation
import XCTest
@testable import SpikeAKit

/// The metric matrix, at the seam a caller uses.
///
/// `XCTAssertTrue(dict["k"] == .someCase)` rather than `XCTAssertEqual` wherever
/// an enum is compared through a subscript — a dictionary subscript hands back
/// `T?`, a leading-dot member leaves the generic parameter unresolved, and the
/// compiler reports it as "type 'Equatable' has no member …", which is a symptom
/// a long way from its cause. `tasks/lessons.md` records this being forgotten
/// once already in this very package.
final class ProgressMetricTests: XCTestCase {

    private func document() throws -> Document {
        try SpikeAFixture.document()
    }

    private func byteResource() -> ByteResource {
        SpikeAFixture.twoPageByteResource
    }

    // MARK: - Progression

    /// The same place, two metrics, two **different numbers** — which is why a
    /// value that does not carry its label does not identify a place.
    ///
    /// A test that merely compared two `Progression` values would prove nothing:
    /// `==` is synthesised over the stored properties, so `0.5` under one metric
    /// and `0.5` under another are unequal by arithmetic on the type rather than
    /// by anything the model does. The distinction only becomes evidence when it
    /// is asked of a real position on a real subject.
    func testTwoMetricsOverOneSubjectNameDifferentNumbers() throws {
        let resource = byteResource()
        let byBytes = SourceBytesAxis(resource: resource)
        let byText = CanonicalTextIndexAxis(document: resource.singleUnitDocument)
        let position = try XCTUnwrap(resource.position(atUTF16: 3))

        let fromBytes = try XCTUnwrap(byBytes.progression(of: position))
        let fromText = try XCTUnwrap(byText.progression(of: position))

        XCTAssertTrue(fromBytes.metric == .sourceBytes)
        XCTAssertTrue(fromText.metric == .canonicalTextIndex)
        XCTAssertNotEqual(
            fromBytes.value,
            fromText.value,
            "one is a fraction of the resource's bytes, the other of the text's UTF-16 units"
        )
    }

    // MARK: - CanonicalTextIndexAxis

    /// The coordinate at a unit's start is the sum of the lengths before it.
    /// Stated as a relation against the reading order, never as a constant — two
    /// earlier offset assertions in this repository were pinned from memory and
    /// were wrong both times.
    func testAUnitStartIsTheSumOfTheLengthsBeforeIt() throws {
        let document = try document()
        let axis = CanonicalTextIndexAxis(document: document)

        var running = 0
        for unit in document.readingOrder {
            let position = NativePosition(unitID: unit.id, nodeID: .path([]), utf16Offset: 0)
            XCTAssertEqual(try XCTUnwrap(axis.coordinate(of: position)), Double(running))
            running += unit.length
        }
        XCTAssertEqual(Double(running), Double(document.totalLength))
    }

    /// The empty unit's start and end are the same coordinate. This is what a
    /// prefix sum off by one moves, and it is invisible in a book that has no
    /// zero-length unit.
    func testAnEmptyUnitContributesNoWidth() throws {
        let document = try document()
        let axis = CanonicalTextIndexAxis(document: document)
        let empty = try XCTUnwrap(
            document.readingOrder.first { $0.length == 0 },
            "the fixture must still carry a unit with no text"
        )
        let start = try XCTUnwrap(
            axis.coordinate(of: NativePosition(unitID: empty.id, nodeID: .path([]), utf16Offset: 0))
        )
        let end = try XCTUnwrap(
            axis.coordinate(of: NativePosition(unitID: empty.id, nodeID: .path([]), utf16Offset: empty.length))
        )
        XCTAssertEqual(start, end)
    }

    /// An offset past the end of its unit is not a coordinate. The axis returns
    /// nil; the service is what turns that into a throw.
    func testAnOffsetPastTheEndOfItsUnitHasNoCoordinate() throws {
        let document = try document()
        let axis = CanonicalTextIndexAxis(document: document)
        let unit = try XCTUnwrap(document.readingOrder.first { $0.length > 0 })
        XCTAssertNil(
            axis.coordinate(of: NativePosition(unitID: unit.id, nodeID: .path([]), utf16Offset: unit.length + 1))
        )
        XCTAssertNil(
            axis.coordinate(of: NativePosition(unitID: "no-such-unit", nodeID: .path([]), utf16Offset: 0))
        )
    }

    /// `0 / 0` must be nil rather than NaN. A document of nothing but empty units
    /// is the only input that reaches it, which is why the fixture carries one.
    func testADocumentWithNoTextAtAllRefusesRatherThanDividingByZero() throws {
        let empty = Document(readingOrder: [
            DocumentUnit(
                id: "empty",
                href: "empty",
                mediaType: "application/xhtml+xml",
                canonical: CanonicalText(string: "", elements: [])
            )
        ])
        let axis = CanonicalTextIndexAxis(document: empty)
        let progression = axis.progression(
            of: NativePosition(unitID: "empty", nodeID: .path([]), utf16Offset: 0)
        )
        XCTAssertNil(progression, "there is no fraction to state")
    }

    // MARK: - SourceBytesAxis

    /// The map from text offsets to byte offsets, against the hand-written table.
    ///
    /// The two `\n` units sit inside their CRLFs, so their byte offsets — 4 and
    /// 11 — are **not** in `legalBoundaries`. Pinning that is what keeps the seek
    /// probe honest: if `coordinate` could only ever return a legal offset, then
    /// "the seek landed on a legal offset" would be true by construction.
    func testTheByteMapAgreesWithTheHandWrittenTableAndCanReportIllegalOffsets() throws {
        let resource = byteResource()
        XCTAssertEqual(resource.utf16Count, 8, "记 CRLF A FF 记 CRLF decodes to eight UTF-16 units")

        XCTAssertEqual(try XCTUnwrap(resource.byteOffset(forUTF16: 2)), 4, "the LF of the first CRLF")
        XCTAssertEqual(try XCTUnwrap(resource.byteOffset(forUTF16: 7)), 11, "the LF of the second CRLF")
        XCTAssertFalse(resource.legalBoundaries.contains(4))
        XCTAssertFalse(resource.legalBoundaries.contains(11))
        // The map's image is wider than the table by exactly those two — which
        // is what lets `coordinate(of:)` report an offset a seek may not land on.
        XCTAssertEqual(resource.decodedBoundaries.count, 9)
        XCTAssertTrue(resource.decodedBoundaries.contains(4))
        XCTAssertTrue(resource.decodedBoundaries.contains(11))

        for boundary in resource.legalBoundaries {
            XCTAssertEqual(
                resource.byteOffset(forUTF16: try XCTUnwrap(resource.utf16Offset(forByte: boundary))),
                boundary,
                "the derived map and the hand-written table must agree at \(boundary)"
            )
        }
    }

    /// The ill-formed byte consumes exactly one byte, which is a **policy** —
    /// the maximal-subpart rule — and not a fact the bytes state. A decoder that
    /// grouped `FF` with the `41` that follows would move every offset after it.
    func testTheIllFormedByteConsumesExactlyOneByte() throws {
        let resource = byteResource()
        XCTAssertEqual(try XCTUnwrap(resource.utf16Offset(forByte: 6)), 4, "the replacement character starts at 6")
        XCTAssertEqual(try XCTUnwrap(resource.utf16Offset(forByte: 7)), 5, "so 7 is where the next unit starts")
        XCTAssertTrue(resource.legalBoundaries.contains(7))
        XCTAssertTrue(resource.hazard(atByte: 7) == .invalidLeadByteWidth)
    }

    /// Each hazard must be reachable, or a probe that swept for it would be
    /// reporting on nothing.
    func testAllThreeHazardsArePresentInTheFixture() throws {
        let resource = byteResource()
        var seen: Set<ByteResource.BoundaryHazard> = []
        for offset in 0...resource.byteCount {
            if let hazard = resource.hazard(atByte: offset) { seen.insert(hazard) }
        }
        XCTAssertEqual(seen.count, ByteResource.BoundaryHazard.allCases.count, "saw \(seen)")
        XCTAssertTrue(resource.hazard(atByte: 1) == .multiByteInterior)
        XCTAssertTrue(resource.hazard(atByte: 4) == .crlfInterior)
        XCTAssertTrue(resource.hazard(atByte: 11) == .crlfInterior)
    }

    /// A seek lands on the **greatest legal boundary not past the request**.
    /// Bounded only by membership, a nearest-boundary implementation would pass
    /// by answering 5 for a request of 4 — legal, and on the wrong side.
    func testASeekLandsOnThePrecedingLegalBoundary() throws {
        let resource = byteResource()
        let axis = SourceBytesAxis(resource: resource)
        let service = PublicationProgressService(axis: axis)

        for requested in 0...resource.byteCount {
            let back = try service.position(near: Double(requested) / Double(resource.byteCount))
            let landed = try XCTUnwrap(axis.coordinate(of: back))
            let expected = try XCTUnwrap(
                resource.legalBoundaries.last { $0 <= requested },
                "the table must have a boundary at or before byte \(requested)"
            )
            XCTAssertEqual(Int(landed), expected, "byte \(requested)")
            XCTAssertLessThanOrEqual(
                abs(landed - Double(requested)),
                axis.seekTolerance,
                "the observed snap must respect the tolerance the metric declares"
            )
        }
    }

    /// The tolerance is the metric's, not this fixture's: the fixture's longest
    /// illegal run is two bytes, and a four-byte scalar has three continuation
    /// bytes, so the declared bound has to be the larger of the two.
    func testTheByteToleranceIsTheMetricsNotTheFixtures() {
        XCTAssertEqual(SourceBytesAxis(resource: byteResource()).seekTolerance, 3)
    }

    // MARK: - FixedPageOrdinalAxis

    /// One mutation, two metrics, two opposite expectations — on the same bytes.
    func testDeclaredPaginationMovesThePageMetricAndNotTheByteMetric() throws {
        let two = SpikeAFixture.twoPageByteResource
        let four = SpikeAFixture.fourPageByteResource

        let pagesTwo = FixedPageOrdinalAxis(resource: two)
        let pagesFour = FixedPageOrdinalAxis(resource: four)
        let bytesTwo = SourceBytesAxis(resource: two)
        let bytesFour = SourceBytesAxis(resource: four)

        var pagesMoved = 0
        for offset in 0...two.utf16Count {
            let position = try XCTUnwrap(two.position(atUTF16: offset))
            if pagesTwo.coordinate(of: position) != pagesFour.coordinate(of: position) { pagesMoved += 1 }
            XCTAssertEqual(
                bytesTwo.coordinate(of: position),
                bytesFour.coordinate(of: position),
                "the bytes did not change, so the byte coordinate must not"
            )
        }
        XCTAssertGreaterThan(pagesMoved, 0, "otherwise the mutation never reached the metric")
    }

    /// Under the page-centre convention, only a floor inverts the fraction. This
    /// pins the arithmetic the probe relies on.
    func testThePageCentreFractionRoundTripsExactlyUnderFloor() throws {
        let resource = byteResource()
        let axis = FixedPageOrdinalAxis(resource: resource)
        let service = PublicationProgressService(axis: axis)

        for offset in 0...resource.utf16Count {
            let position = try XCTUnwrap(resource.position(atUTF16: offset))
            let ordinal = try XCTUnwrap(axis.coordinate(of: position))
            let progression = try service.progression(for: position)
            XCTAssertTrue(progression.metric == .fixedPageOrdinal)
            let back = try service.position(near: progression.value)
            XCTAssertEqual(axis.coordinate(of: back), ordinal, "offset \(offset)")
        }
    }

    /// Reflowable content has no page ordinals, and the metric says so rather
    /// than inventing them. This is ADR-0008's prohibition as a measurement.
    func testAResourceTheContainerDoesNotPaginateHasNoPageOrdinal() throws {
        let resource = SpikeAFixture.reflowableByteResource
        let axis = FixedPageOrdinalAxis(resource: resource)
        XCTAssertEqual(axis.seekTolerance, 0, "a page has no finer coordinate")
        for offset in 0...resource.utf16Count {
            let position = try XCTUnwrap(resource.position(atUTF16: offset))
            XCTAssertNil(axis.coordinate(of: position))
            XCTAssertNil(axis.progression(of: position))
        }
    }

    // MARK: - PublicationProgressService

    /// The service throws rather than clamping. A clamped answer would be a
    /// coordinate the publication never stated, handed back looking real.
    func testAnOutOfRangeProgressionIsRefusedNotClamped() throws {
        let service = PublicationProgressService(axis: SourceBytesAxis(resource: byteResource()))
        XCTAssertThrowsError(try service.position(near: 1.5))
        XCTAssertThrowsError(try service.position(near: -0.001))
    }

    /// A position from another metric's subject is refused too.
    func testAPositionOutsideTheAxisIsRefused() throws {
        let service = PublicationProgressService(axis: SourceBytesAxis(resource: byteResource()))
        XCTAssertThrowsError(
            try service.progression(
                for: NativePosition(unitID: "OEBPS/chap1.xhtml", nodeID: .path([]), utf16Offset: 0)
            )
        )
    }
}
