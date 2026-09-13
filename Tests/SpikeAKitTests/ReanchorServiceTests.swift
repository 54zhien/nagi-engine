import Foundation
import XCTest
@testable import SpikeAKit

/// The ReanchorService contract from ADR-0012, asserted rather than described.
///
/// These tests build **their own** documents instead of using `SpikeAFixture`.
/// The fixture is Spike A's measurement subject and its shape is load-bearing
/// for those readings; re-anchoring wants scenarios the fixture has no reason to
/// contain (a paragraph that moved to another unit, a quote split across two
/// units). Building them here also keeps every string a test depends on inside
/// the test that depends on it.
///
/// **Offsets are derived, never recalled.** A literal here would be a constant
/// written from memory, which is the mistake `tasks/lessons.md` records twice.
/// Where an offset is asserted it is computed from the text that produces it —
/// `inserted.utf16.count`, `prefix.utf16.count`, `canonical.utf16.count` — so a
/// change in the fixture strings moves the expectation with it. `0` is used
/// only for "the start of the text", which is not a measurement.
final class ReanchorServiceTests: XCTestCase {

    // MARK: - Building documents

    /// `id` and `href` are separate parameters on purpose: one test has to show
    /// that every stored identity can change while the quote does not, and that
    /// requires the two to be able to differ in the first place.
    private func makeDocument(_ units: [(id: String, href: String, body: String)]) throws -> Document {
        var built: [DocumentUnit] = []
        for entry in units {
            let xhtml = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>t</title></head>
            <body>
            \(entry.body)
            </body>
            </html>
            """
            let canonical = try XHTMLToCanonical.build(from: xhtml)
            built.append(DocumentUnit(
                id: entry.id,
                href: entry.href,
                mediaType: "application/xhtml+xml",
                canonical: canonical
            ))
        }
        return Document(readingOrder: built)
    }

    private func single(_ body: String, id: String = "u1") throws -> Document {
        try makeDocument([(id: id, href: id, body: body)])
    }

    /// Pins the premise a derived offset is counted in.
    private func canonicalText(_ document: Document, _ unitID: String = "u1") throws -> String {
        let unit = try XCTUnwrap(document.unit(withID: unitID))
        return unit.canonical.string
    }

    // MARK: - a. the original position still holds, and the quote repeats elsewhere

    func testATheOriginalPositionWinsOverARepeatedQuote() async throws {
        let document = try single("<p id=\"a\">target</p><p id=\"b\">target</p>")
        XCTAssertEqual(try canonicalText(document), "targettarget")

        let anchor = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
            quote: AnchorQuote(exact: "target")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .relocated(let position, let method) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        XCTAssertTrue(method == .originalPosition, "a position that still holds is not a search result")
        XCTAssertEqual(position.utf16Offset, 0)
        XCTAssertTrue(position.nodeID == .explicitID("a"), "the first of the two, not whichever is nearer")
    }

    // MARK: - b. an insertion before the quote moves the offset

    func testBAnInsertionBeforeTheQuoteMovesTheOffset() async throws {
        let inserted = "XXX"
        let document = try single("<p id=\"a\">\(inserted)target</p>")
        XCTAssertEqual(try canonicalText(document), inserted + "target")

        let anchor = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
            quote: AnchorQuote(exact: "target")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .relocated(let position, let method) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        XCTAssertTrue(method == .uniqueExactQuote)
        XCTAssertEqual(position.utf16Offset, inserted.utf16.count)
    }

    // MARK: - c. the paragraph moved to another unit

    func testCTheQuoteIsFoundInAnotherUnitAfterTheParagraphMoves() async throws {
        let document = try makeDocument([
            (id: "u1", href: "u1.xhtml", body: "<p id=\"a\">nothing of the sort</p>"),
            (id: "u2", href: "u2.xhtml", body: "<p id=\"b\">target</p>")
        ])

        let anchor = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
            quote: AnchorQuote(exact: "target")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .relocated(let position, let method) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        XCTAssertTrue(method == .uniqueExactQuote)
        XCTAssertEqual(position.unitID, "u2")
        XCTAssertEqual(position.utf16Offset, 0)
    }

    // MARK: - d. two identical quotes, separated by their context

    func testDDifferentContextSeparatesTwoIdenticalQuotes() async throws {
        let firstPrefix = "alpha "
        let document = try single("<p id=\"a\">\(firstPrefix)target omega</p><p id=\"b\">beta target psi</p>")

        let anchor = Anchor(
            position: nil,
            quote: AnchorQuote(exact: "target", prefix: firstPrefix, suffix: " omega")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .relocated(let position, let method) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        XCTAssertTrue(method == .quoteContext, "the context is what chose this one")
        XCTAssertEqual(position.utf16Offset, firstPrefix.utf16.count)
    }

    // MARK: - e. two identical quotes with nothing to choose between them

    /// The two offsets, derived: the second sits one whole paragraph plus the
    /// second occurrence's own prefix into the text.
    private func repeatedQuoteOffsets() -> (first: Int, second: Int) {
        let firstPrefix = "alpha "
        let middle = "alpha target omegabeta "
        return (firstPrefix.utf16.count, middle.utf16.count)
    }

    private func repeatedQuoteDocument() throws -> Document {
        try single("<p id=\"a\">alpha target omega</p><p id=\"b\">beta target psi</p>")
    }

    func testETwoIdenticalQuotesWithNoContextAreAmbiguousAndInOrder() async throws {
        let document = try repeatedQuoteDocument()
        let expected = repeatedQuoteOffsets()

        let anchor = Anchor(position: nil, quote: AnchorQuote(exact: "target"))

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .ambiguous(let candidates) = result else {
            return XCTFail("expected ambiguity, got \(result)")
        }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map(\.unitID), ["u1", "u1"], "reading order")
        XCTAssertEqual(candidates.map(\.utf16Offset), [expected.first, expected.second])
    }

    func testEContextFittingNothingReturnsTheRawCandidatesRatherThanAnEmptyList() async throws {
        let document = try repeatedQuoteDocument()
        let expected = repeatedQuoteOffsets()

        let anchor = Anchor(
            position: nil,
            quote: AnchorQuote(exact: "target", prefix: "NOWHERE", suffix: "NOWHERE")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .ambiguous(let candidates) = result else {
            return XCTFail("expected ambiguity, got \(result)")
        }
        XCTAssertEqual(candidates.count, 2, "what failed is the memory of the surroundings, not the quote")
        XCTAssertEqual(candidates.map(\.utf16Offset), [expected.first, expected.second], "the raw hits, unchanged")
    }

    /// **The test that falsifies "choose the nearest".**
    ///
    /// The stored position fails validation *and* sits immediately before the
    /// second occurrence — so an implementation that fell back to proximity
    /// would return that one, confidently, with nothing in the result to say a
    /// choice had been made. Two equally good candidates must stay two.
    func testENearnessDoesNotBreakATieThatTheEvidenceCannotBreak() async throws {
        let document = try repeatedQuoteDocument()
        let expected = repeatedQuoteOffsets()

        let anchor = Anchor(
            position: NativePosition(
                unitID: "u1",
                nodeID: .explicitID("b"),
                utf16Offset: expected.second - 1
            ),
            quote: AnchorQuote(exact: "target")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .ambiguous(let candidates) = result else {
            return XCTFail("a stale position near one candidate must not become that candidate: got \(result)")
        }
        XCTAssertEqual(candidates.map(\.utf16Offset), [expected.first, expected.second])
    }

    /// Ambiguity across units, where the order that matters is **reading order**
    /// rather than offset — the two units' offsets are not comparable, so a
    /// sort by offset would be meaningless and a sort by the old `unitID` would
    /// be a guess.
    func testEAmbiguityAcrossUnitsKeepsReadingOrderAndPerUnitOffsets() async throws {
        let firstPrefix = "AAA "
        let secondPrefix = "BB "
        let document = try makeDocument([
            (id: "u1", href: "u1.xhtml", body: "<p id=\"a\">\(firstPrefix)target</p>"),
            (id: "u2", href: "u2.xhtml", body: "<p id=\"b\">\(secondPrefix)target</p>")
        ])

        let anchor = Anchor(position: nil, quote: AnchorQuote(exact: "target"))
        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .ambiguous(let candidates) = result else {
            return XCTFail("expected ambiguity, got \(result)")
        }
        XCTAssertEqual(candidates.map(\.unitID), ["u1", "u2"], "reading order")
        XCTAssertEqual(
            candidates.map(\.utf16Offset),
            [firstPrefix.utf16.count, secondPrefix.utf16.count],
            "each offset is counted inside its own unit"
        )
    }

    // MARK: - f. the quote text itself changed

    func testFChangedQuoteTextIsNotFound() async throws {
        let document = try single("<p id=\"a\">the text moved on</p>")

        let anchor = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
            quote: AnchorQuote(exact: "target")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .notFound(let reason) = result else {
            return XCTFail("expected notFound, got \(result)")
        }
        XCTAssertTrue(reason == .exactTextMissing)
    }

    // MARK: - g. every stored identity changed

    /// **The premise is real, not stipulated.** The old document is built first
    /// and its three identities are read back out of it — unit id, href, and
    /// element id — and the anchor is anchored at the old element's own start.
    /// Only then is a second document built in which all three differ and the
    /// quote does not.
    func testGTheQuoteIsRecoveredWhenEveryStoredIdentityChanged() async throws {
        let oldUnitID = "old-unit"
        let oldHref = "old.xhtml"
        let oldElementID = "old-id"

        let oldDocument = try makeDocument([
            (id: oldUnitID, href: oldHref, body: "<p id=\"\(oldElementID)\">target</p>")
        ])
        let oldUnit = try XCTUnwrap(oldDocument.unit(withID: oldUnitID))
        XCTAssertEqual(oldUnit.href, oldHref, "the stored href is a real, different string")
        XCTAssertNotEqual(oldUnitID, oldHref, "id and href are not the same value in this setup")
        let oldElement = try XCTUnwrap(oldUnit.canonical.element(withID: oldElementID))

        let anchor = Anchor(
            position: NativePosition(
                unitID: oldUnitID,
                nodeID: .explicitID(oldElementID),
                utf16Offset: oldElement.utf16Range.lowerBound
            ),
            quote: AnchorQuote(exact: "target")
        )

        let newUnitID = "new-unit"
        let newHref = "new.xhtml"
        let newElementID = "new-id"
        let newDocument = try makeDocument([
            (id: newUnitID, href: newHref, body: "<p id=\"\(newElementID)\">target</p>")
        ])

        // Each identity really is gone, and the text really is the same.
        XCTAssertNotEqual(oldUnitID, newUnitID)
        XCTAssertNotEqual(oldHref, newHref)
        XCTAssertNotEqual(oldElementID, newElementID)
        XCTAssertNil(newDocument.unit(withID: oldUnitID), "the old unit id resolves to nothing here")
        XCTAssertEqual(
            try canonicalText(newDocument, newUnitID),
            try canonicalText(oldDocument, oldUnitID),
            "and the quote is unchanged, which is the only thing that carries over"
        )

        let result = try await ReanchorService.reanchor(anchor, in: newDocument)
        guard case .relocated(let position, let method) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        XCTAssertTrue(method == .uniqueExactQuote)
        XCTAssertEqual(position.unitID, newUnitID)
        XCTAssertEqual(position.utf16Offset, 0)
        XCTAssertTrue(position.nodeID == .explicitID(newElementID))
    }

    // MARK: - h. CJK punctuation and folded whitespace

    func testHCJKPunctuationAndFoldedWhitespaceAreMatchedAsCanonicalText() async throws {
        // The source carries a run of spaces; the canonical text carries one,
        // because folding happened before anything here saw it.
        let document = try single("<p id=\"a\">甲，    乙</p>")
        XCTAssertEqual(try canonicalText(document), "甲， 乙")

        let folded = Anchor(position: nil, quote: AnchorQuote(exact: "甲， 乙"))
        let foldedResult = try await ReanchorService.reanchor(folded, in: document)
        guard case .relocated(let position, let method) = foldedResult else {
            return XCTFail("expected a relocation, got \(foldedResult)")
        }
        XCTAssertTrue(method == .uniqueExactQuote)
        XCTAssertEqual(position.utf16Offset, 0)

        // The full-width comma is matched as itself. Nothing here is lenient
        // about punctuation, so an ASCII comma is a different quote.
        let asciiComma = Anchor(position: nil, quote: AnchorQuote(exact: "甲, 乙"))
        let asciiResult = try await ReanchorService.reanchor(asciiComma, in: document)
        guard case .notFound(let reason) = asciiResult else {
            return XCTFail("expected notFound, got \(asciiResult)")
        }
        XCTAssertTrue(reason == .exactTextMissing, "punctuation is not folded, normalised or guessed at")
    }

    // MARK: - i. ruby is not on the axis

    /// The quote here sits **after** the annotation, so the offset can only be
    /// right if `rt` really occupies no units. A test that only checked the
    /// base text at offset 0 would pass on an implementation that never
    /// measured the annotation's width at all.
    func testIRubyIsNotOnTheAxisAndTheOffsetAfterItProvesSo() async throws {
        let base = "京都"
        let afterAnnotation = "へ行った。"
        let document = try single("<p id=\"a\"><ruby>\(base)<rt>きょうと</rt></ruby>\(afterAnnotation)</p>")
        XCTAssertEqual(try canonicalText(document), base + afterAnnotation)

        let anchor = Anchor(
            position: nil,
            quote: AnchorQuote(exact: afterAnnotation, prefix: base)
        )
        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .relocated(let position, _) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        // The annotation is four characters wide in the source and zero units
        // wide here, so this number is the annotation's absence.
        XCTAssertEqual(position.utf16Offset, base.utf16.count)

        // The annotation's own text is not in the canonical primary text at
        // all — so it is missing, not matched somewhere unobvious.
        let annotation = Anchor(position: nil, quote: AnchorQuote(exact: "きょうと"))
        let annotationResult = try await ReanchorService.reanchor(annotation, in: document)
        guard case .notFound(let reason) = annotationResult else {
            return XCTFail("expected notFound, got \(annotationResult)")
        }
        XCTAssertTrue(reason == .exactTextMissing)
    }

    // MARK: - j. an offset after a non-BMP character

    func testJAnOffsetAfterANonBMPPrefixIsCountedInUTF16Units() async throws {
        let prefix = "𠀋"
        let document = try single("<p id=\"a\">\(prefix)记号</p>")
        XCTAssertEqual(try canonicalText(document), prefix + "记号")

        XCTAssertEqual(prefix.count, 1, "one Character")
        XCTAssertEqual(prefix.utf16.count, 2, "and two UTF-16 code units")

        let anchor = Anchor(position: nil, quote: AnchorQuote(exact: "记号", prefix: prefix))
        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .relocated(let position, _) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        // Derived, not written down: a Character-counting implementation would
        // say 1 here, and the number would look plausible.
        XCTAssertEqual(position.utf16Offset, prefix.utf16.count)
    }

    // MARK: - k. an empty quote

    func testKAnEmptyQuoteIsNotFoundEvenWhenThePositionStillHolds() async throws {
        let document = try single("<p id=\"a\">target</p>")

        // The stored position is genuinely still correct, and it still does not
        // matter: there is nothing to re-anchor to, and saying `originalPosition`
        // would report a confirmation that was never made.
        let anchor = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
            quote: AnchorQuote(exact: "")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .notFound(let reason) = result else {
            return XCTFail("expected notFound, got \(result)")
        }
        XCTAssertTrue(reason == .emptyQuote)
    }

    // MARK: - l. overlapping occurrences

    func testLOverlappingOccurrencesAreBothCounted() async throws {
        let document = try single("<p id=\"a\">aaa</p>")
        XCTAssertEqual(try canonicalText(document), "aaa")

        // "aa" sits at 0 and one unit later. A search that skipped overlaps
        // would find only the first and report a confident relocation to a
        // position this text does not single out.
        let anchor = Anchor(position: nil, quote: AnchorQuote(exact: "aa"))
        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .ambiguous(let candidates) = result else {
            return XCTFail("expected ambiguity, got \(result)")
        }
        XCTAssertEqual(candidates.map(\.utf16Offset), [0, "a".utf16.count])
    }

    // MARK: - The node id is rebuilt, never inherited

    func testTheValidatorRebuildsTheNodeIDRatherThanTrustingTheStoredOne() async throws {
        let document = try single("<p id=\"now\">target</p>")

        let anchor = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("gone"), utf16Offset: 0),
            quote: AnchorQuote(exact: "target")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .relocated(let position, let method) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        XCTAssertTrue(method == .originalPosition)
        XCTAssertTrue(position.nodeID == .explicitID("now"), "the element that is here")
        XCTAssertFalse(position.nodeID == .explicitID("gone"), "not the one that was remembered")
    }

    // MARK: - A stale context cannot veto the only occurrence

    func testAStaleContextDoesNotRejectTheOnlyOccurrence() async throws {
        let document = try single("<p id=\"a\">target</p>")

        let anchor = Anchor(
            position: nil,
            quote: AnchorQuote(exact: "target", prefix: "STALE", suffix: "STALE")
        )

        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .relocated(let position, let method) = result else {
            return XCTFail("expected a relocation, got \(result)")
        }
        XCTAssertTrue(method == .uniqueExactQuote)
        XCTAssertEqual(position.utf16Offset, 0)
    }

    // MARK: - v1 does not match across units

    func testAQuoteSplitAcrossTwoUnitsIsNotFound() async throws {
        let document = try makeDocument([
            (id: "u1", href: "u1.xhtml", body: "<p id=\"a\">tar</p>"),
            (id: "u2", href: "u2.xhtml", body: "<p id=\"b\">get</p>")
        ])

        let anchor = Anchor(position: nil, quote: AnchorQuote(exact: "target"))
        let result = try await ReanchorService.reanchor(anchor, in: document)
        guard case .notFound(let reason) = result else {
            return XCTFail("expected notFound, got \(result)")
        }
        XCTAssertTrue(reason == .exactTextMissing, "the two halves are adjacent in reading order, not in any unit")
    }

    // MARK: - The validator's own verdicts

    func testTheValidatorRefusesEveryShapeItCannotConfirm() async throws {
        let quote = "target"
        let document = try single("<p id=\"a\">\(quote)</p>")
        let textLength = try canonicalText(document).utf16.count

        // A local helper rather than `guard case .invalid = try await …` five
        // times over. `tasks/lessons.md` records a CI run lost to a `try` in a
        // legal-looking position, so the explicit form wins.
        func confirms(_ anchor: Anchor) async throws -> Bool {
            let validation = try await AnchorValidator.validate(anchor, in: document)
            if case .valid = validation { return true }
            return false
        }

        let noPosition = Anchor(position: nil, quote: AnchorQuote(exact: quote))
        let noPositionConfirmed = try await confirms(noPosition)
        XCTAssertFalse(noPositionConfirmed, "a nil position cannot be confirmed")

        let unknownUnit = Anchor(
            position: NativePosition(unitID: "nope", nodeID: .explicitID("a"), utf16Offset: 0),
            quote: AnchorQuote(exact: quote)
        )
        let unknownUnitConfirmed = try await confirms(unknownUnit)
        XCTAssertFalse(unknownUnitConfirmed, "a unit that is not there cannot be confirmed")

        // Past the end, counted from the text rather than written down.
        let pastTheEnd = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: textLength),
            quote: AnchorQuote(exact: quote)
        )
        let pastTheEndConfirmed = try await confirms(pastTheEnd)
        XCTAssertFalse(pastTheEndConfirmed, "an offset at the very end cannot be confirmed")

        // **A corrupt offset, which used to trap.** `offset + needle.count`
        // overflows on `Int.max`, so the bounds check is what decides whether
        // this is answered or crashes the process. This assertion is the one
        // that fails if anyone writes the addition back.
        let absurd = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: Int.max),
            quote: AnchorQuote(exact: quote)
        )
        let absurdConfirmed = try await confirms(absurd)
        XCTAssertFalse(absurdConfirmed, "a stored offset that cannot exist must be answered, not trap")

        let mismatchedContext = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
            quote: AnchorQuote(exact: quote, suffix: "WRONG")
        )
        let mismatchedContextConfirmed = try await confirms(mismatchedContext)
        XCTAssertFalse(mismatchedContextConfirmed, "a context that does not hold cannot be confirmed")

        // **An empty quote is `invalid` here, and that is a decision rather
        // than a rule handed down.** ADR-0012 sends an empty quote to
        // `notFound(.emptyQuote)` before the validator is reached; a direct
        // call has no such order to lean on, and `valid` would mean claiming a
        // confirmation from zero units of evidence. Codex confirmed the
        // conservative answer is the right one.
        let emptyQuote = Anchor(
            position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
            quote: AnchorQuote(exact: "")
        )
        let emptyQuoteConfirmed = try await confirms(emptyQuote)
        XCTAssertFalse(emptyQuoteConfirmed, "an empty quote confirms nothing")
    }

    func testTheValidatorConfirmsAQuoteThatStillHolds() async throws {
        let prefix = "alpha "
        let document = try single("<p id=\"a\">\(prefix)target omega</p>")

        let anchor = Anchor(
            position: NativePosition(
                unitID: "u1",
                nodeID: .explicitID("a"),
                utf16Offset: prefix.utf16.count
            ),
            quote: AnchorQuote(exact: "target", prefix: prefix, suffix: " omega")
        )

        let validation = try await AnchorValidator.validate(anchor, in: document)
        guard case .valid(let position) = validation else {
            return XCTFail("this quote holds at this offset")
        }
        XCTAssertEqual(position.utf16Offset, prefix.utf16.count)
        XCTAssertEqual(position.unitID, "u1")
        XCTAssertTrue(position.nodeID == .explicitID("a"))
    }
}
