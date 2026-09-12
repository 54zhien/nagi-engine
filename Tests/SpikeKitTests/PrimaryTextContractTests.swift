import Foundation
import XCTest
import SpikeKit

/// Guards the contracts the rest of the engine is allowed to assume.
///
/// ADR-0005: there is exactly ONE primary canonical text stream, and every
/// Native Position offset indexes it. That makes the corpus a piece of
/// infrastructure, not a test string: if `Fixture.body` changes by one
/// character, every offset in every report shifts, and a golden comparison
/// against the previous run reports a difference that has nothing to do with
/// layout. So the corpus is pinned by length and by hash, and changing it has to
/// be a deliberate act that updates this file too.
///
/// The second contract is weaker but easier to lose silently: the corpus has to
/// actually exercise 禁則処理. A trimmed corpus still produces a runnable
/// kinsoku probe — one that reports PASS because it measured nothing.
final class PrimaryTextContractTests: XCTestCase {

    // MARK: - The corpus is pinned

    func testCorpusIdentityIsStable() {
        XCTAssertEqual(Fixture.name, "kinsoku-v1")
    }

    /// 407 UTF-16 units. Not a character count that happens to be 407: this is
    /// the number that all `LineRecord.utf16Start` / `utf16Length` values are
    /// relative to.
    func testCorpusUTF16LengthIsPinned() {
        XCTAssertEqual(
            Fixture.body.utf16.count, 407,
            "Fixture.body changed length — every offset in every golden shifts with it. "
                + "If this is intentional, update the pin and re-record the goldens together."
        )
    }

    func testCorpusHashIsPinned() {
        XCTAssertEqual(
            SHA256.hex(Fixture.body),
            "98a731fa9ee382a571993917243f2a98b62948741366fc1019bb01570c2be330",
            "Fixture.body changed — same reasoning as the length pin above."
        )
    }

    /// The multiline literal must not smuggle a leading or trailing newline into
    /// the canonical stream. One stray newline is invisible in review, shifts
    /// every offset by one, and adds a line the layout has to place.
    func testCorpusHasNoStrayEdgeNewlines() {
        XCTAssertFalse(Fixture.body.hasPrefix("\n"), "leading newline in Fixture.body")
        XCTAssertFalse(Fixture.body.hasSuffix("\n"), "trailing newline in Fixture.body")
        XCTAssertEqual(
            Fixture.body.split(separator: "\n", omittingEmptySubsequences: false).count, 9,
            "corpus line count changed"
        )
    }

    // MARK: - The corpus actually exercises kinsoku

    /// The probe's whole premise. If neither class appears in the corpus, the
    /// kinsoku probe returns PASS having tested nothing — the exact failure mode
    /// ADR-0011 warns about when it refuses to let probes be gates.
    func testCorpusContainsBothProhibitedClasses() {
        let head = Fixture.body.filter { Fixture.prohibitedAtLineStart.contains($0) }
        let tail = Fixture.body.filter { Fixture.prohibitedAtLineEnd.contains($0) }

        XCTAssertFalse(head.isEmpty, "corpus has no 行頭禁則 character — the kinsoku probe would be vacuous")
        XCTAssertFalse(tail.isEmpty, "corpus has no 行末禁則 character — the kinsoku probe would be vacuous")
    }

    /// The adjacent-punctuation pairs matter because they are where a line
    /// breaker has to make a choice it cannot satisfy by moving one character.
    func testCorpusContainsAdjacentPunctuationPairs() {
        XCTAssertTrue(Fixture.body.contains("。」"))
        XCTAssertTrue(Fixture.body.contains("？」"))
        XCTAssertTrue(Fixture.body.contains("。「"))
    }

    /// Mixed script is what makes autospacing and font fallback observable.
    func testCorpusIsMixedScript() {
        XCTAssertTrue(Fixture.body.contains { $0.isASCII && $0.isLetter }, "corpus lost its Latin runs")
        XCTAssertTrue(Fixture.body.contains { $0.isASCII && $0.isNumber }, "corpus lost its digits")
    }

    // MARK: - Coverage sample

    func testCoverageSampleIsDeduplicatedAndNewlineFree() {
        let sample = Fixture.coverageSample
        XCTAssertEqual(Set(sample).count, sample.count, "coverageSample contains duplicates")
        XCTAssertFalse(sample.contains("\n"), "a newline is not a glyph to look for")
    }

    func testCoverageSampleCoversBothProhibitedClasses() {
        let sample = Set(Fixture.coverageSample)
        XCTAssertTrue(Fixture.prohibitedAtLineStart.isSubset(of: sample))
        XCTAssertTrue(Fixture.prohibitedAtLineEnd.isSubset(of: sample))
    }

    /// Ruby is measured on its own line in the ruby probe. If the font cannot
    /// draw 東京 or とうきょう, that probe measures .notdef boxes.
    func testCoverageSampleIncludesRubyMaterial() {
        let sample = Set(Fixture.coverageSample)
        XCTAssertTrue(Fixture.rubyBase.allSatisfy { sample.contains($0) })
        XCTAssertTrue(Fixture.rubyAnnotation.allSatisfy { sample.contains($0) })
    }

    // MARK: - Consumed range vs content range

    /// The regression the split exists for: a 行末禁則 character at the end of a
    /// hard-broken line must still be counted. Measured against the consumed
    /// range, the `\n` occupies the final position and the violation vanishes.
    func testHardBreakDoesNotHideALineEndViolation() throws {
        let text = "あい「\n"
        let violations = Kinsoku.inspect(
            lines: [try line(0, consumed: (0, 4), content: (0, 3))],
            in: text
        )
        XCTAssertEqual(violations.lineEndsWithProhibited, 1, "「 ended this line and must be counted")
        XCTAssertEqual(violations.hardBreakLines, 1, "this line carried a mandatory break")
        XCTAssertEqual(violations.inspectedLineEnds, 1)
        XCTAssertFalse(violations.lineEndChecksWereBypassed)
    }

    /// And the self-check can actually fire — otherwise it is decoration.
    func testBypassedLineEndChecksAreDetectable() throws {
        let violations = Kinsoku.inspect(
            lines: [try line(0, consumed: (0, 1), content: (0, 0))],
            in: "。"
        )
        XCTAssertEqual(violations.hardBreakLines, 1)
        XCTAssertEqual(violations.inspectedLineEnds, 0)
        XCTAssertTrue(violations.lineEndChecksWereBypassed, "a report with no inspected line ends must say so")
    }

    func testContentRangeTrimsBreakControls() {
        XCTAssertEqual(MandatoryBreak.contentRange(of: "今日は晴れ。\n", consumedStart: 0, consumedLength: 7).length, 6)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あ\r", consumedStart: 0, consumedLength: 2).length, 1)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あ\r\n", consumedStart: 0, consumedLength: 3).length, 1, "CRLF is two controls")
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あ\u{0085}", consumedStart: 0, consumedLength: 2).length, 1)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あ\u{2028}", consumedStart: 0, consumedLength: 2).length, 1)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あ\u{2029}", consumedStart: 0, consumedLength: 2).length, 1)
    }

    /// Only break controls are removed. Whether a trailing space belongs to the
    /// line is a layout policy decision, and the 禁則 probe does not get to make
    /// it on the side.
    func testContentRangeLeavesOrdinaryWhitespaceAlone() {
        for text in ["あ ", "あ\u{3000}", "あ\t"] {
            let range = MandatoryBreak.contentRange(
                of: text,
                consumedStart: 0,
                consumedLength: text.utf16.count
            )
            XCTAssertEqual(range.length, text.utf16.count, "trimmed a non-break character out of \(text.debugDescription)")
        }
    }

    func testContentRangeClampsOutOfRangeInput() {
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あい", consumedStart: 99, consumedLength: 3).start, 2)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あい", consumedStart: 99, consumedLength: 3).length, 0)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あい", consumedStart: -4, consumedLength: 2).start, 0)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あい", consumedStart: 0, consumedLength: 999).length, 2)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あい", consumedStart: 0, consumedLength: -1).length, 0)
        XCTAssertEqual(MandatoryBreak.contentRange(of: "あい", consumedStart: 1, consumedLength: 0).length, 0)
    }

    /// A line that is nothing but a break control has no content at all, which is
    /// what keeps it out of the line-end check rather than testing the newline.
    func testContentRangeOfABareBreakIsEmpty() {
        XCTAssertEqual(MandatoryBreak.contentRange(of: "\n", consumedStart: 0, consumedLength: 1).length, 0)
    }

    // MARK: - Kinsoku inspection

    /// "あいう。」かき" — the second line starts with 。 (行頭禁則) and ends with
    /// 」 (which is prohibited at line START, not at line end, so it must not be
    /// counted as an end violation).
    func testInspectCountsLineStartViolation() throws {
        let violations = Kinsoku.inspect(
            lines: [try line(0, consumed: (0, 3), content: (0, 3)),
                    try line(1, consumed: (3, 2), content: (3, 2))],
            in: "あいう。」かき"
        )
        XCTAssertEqual(violations.lineStartsWithProhibited, 1)
        XCTAssertEqual(violations.lineEndsWithProhibited, 0)
        XCTAssertEqual(violations.total, 1)
    }

    func testInspectCountsLineEndViolation() throws {
        let violations = Kinsoku.inspect(
            lines: [try line(0, consumed: (0, 2), content: (0, 2))],
            in: "あ「い"
        )
        XCTAssertEqual(violations.lineStartsWithProhibited, 0)
        XCTAssertEqual(violations.lineEndsWithProhibited, 1)
        XCTAssertEqual(violations.total, 1)
    }

    /// A zero-length line would otherwise be read as "starts with the character
    /// at that index" and invent a violation.
    func testInspectSkipsEmptyLines() throws {
        let violations = Kinsoku.inspect(
            lines: [try line(0, consumed: (0, 0), content: (0, 0))],
            in: "。あ"
        )
        XCTAssertEqual(violations.total, 0)
        XCTAssertEqual(violations.inspectedLineEnds, 0)
    }

    /// Offsets come from the layout engine, so an out-of-range one is a bug
    /// elsewhere. The inspector must not turn that bug into a crash.
    func testInspectToleratesOutOfRangeOffsets() throws {
        let violations = Kinsoku.inspect(
            lines: [try line(0, consumed: (9_999, 1), content: (9_999, 1)),
                    try line(1, consumed: (-5, 2), content: (-5, 2))],
            in: "あいう"
        )
        XCTAssertEqual(violations.total, 0)
    }

    func testTotalIsTheSumOfBothClasses() throws {
        let violations = Kinsoku.inspect(
            lines: [try line(0, consumed: (0, 2), content: (0, 2)),
                    try line(1, consumed: (2, 1), content: (2, 1))],
            in: "あ「。い"
        )
        XCTAssertEqual(
            violations.total,
            violations.lineStartsWithProhibited + violations.lineEndsWithProhibited
        )
    }

    // MARK: - The kinsoku verdict rule

    /// The regression that matters most. A sweep in which BOTH arms are clean has
    /// nothing to measure: the probe asks whether the language tag *buys* 禁則,
    /// and a control that is equally clean means there was nothing to buy.
    ///
    /// The first real run reported `yes` here, because the rule looked only at
    /// the tagged arm — this is the assertion that would have caught it.
    func testCleanControlMeansNothingWasMeasured() {
        let decision = Kinsoku.decide(
            tagged: violations(start: 0, end: 0, hardBreak: 30, inspected: 200),
            untagged: violations(start: 0, end: 0, hardBreak: 30, inspected: 200),
            contentHeight: 1_000,
            canvasHeight: 1_000_000
        )
        XCTAssertEqual(decision.execution, .inconclusive)
        XCTAssertNil(decision.finding, "an equally clean control leaves nothing for the tag to buy")
    }

    func testTagThatRemovesControlViolationsIsAYes() {
        let decision = Kinsoku.decide(
            tagged: violations(start: 0, end: 0, hardBreak: 30, inspected: 200),
            untagged: violations(start: 4, end: 0, hardBreak: 30, inspected: 200),
            contentHeight: 1_000,
            canvasHeight: 1_000_000
        )
        XCTAssertEqual(decision.execution, .measured)
        XCTAssertEqual(decision.finding, .yes)
    }

    func testTagThatLeavesViolationsIsANo() {
        let decision = Kinsoku.decide(
            tagged: violations(start: 3, end: 0, hardBreak: 30, inspected: 200),
            untagged: violations(start: 0, end: 0, hardBreak: 30, inspected: 200),
            contentHeight: 1_000,
            canvasHeight: 1_000_000
        )
        XCTAssertEqual(decision.execution, .measured)
        XCTAssertEqual(decision.finding, .no)
    }

    /// Experiment validity outranks the comparison: a bypassed line-end check or
    /// a clamped canvas makes the whole sweep unreadable, whatever the arms say.
    func testBypassedLineEndChecksOutrankTheComparison() {
        let decision = Kinsoku.decide(
            tagged: violations(start: 3, end: 0, hardBreak: 30, inspected: 0),
            untagged: violations(start: 3, end: 0, hardBreak: 30, inspected: 0),
            contentHeight: 1_000,
            canvasHeight: 1_000_000
        )
        XCTAssertEqual(decision.execution, .inconclusive)
        XCTAssertNil(decision.finding)
    }

    func testClampedCanvasOutranksTheComparison() {
        let canvas = 1_000_000.0
        let decision = Kinsoku.decide(
            tagged: violations(start: 0, end: 0, hardBreak: 30, inspected: 200),
            untagged: violations(start: 5, end: 0, hardBreak: 30, inspected: 200),
            contentHeight: canvas * Kinsoku.canvasHeadroom,
            canvasHeight: canvas
        )
        XCTAssertEqual(decision.execution, .inconclusive)
        XCTAssertNil(decision.finding)
    }

    /// Just inside the headroom is fine; the limit itself is not.
    func testCanvasHeadroomBoundary() {
        let canvas = 1_000_000.0
        func decide(_ contentHeight: Double) -> Kinsoku.Decision {
            Kinsoku.decide(
                tagged: violations(start: 0, end: 0, hardBreak: 30, inspected: 200),
                untagged: violations(start: 1, end: 0, hardBreak: 30, inspected: 200),
                contentHeight: contentHeight,
                canvasHeight: canvas
            )
        }
        XCTAssertEqual(decide(canvas * 0.5).execution, .measured)
        XCTAssertEqual(decide(canvas * 0.89).execution, .measured)
        XCTAssertEqual(decide(canvas * 0.91).execution, .inconclusive)
        XCTAssertEqual(decide(canvas).execution, .inconclusive)
    }

    func testViolationsAccumulate() {
        var total = violations(start: 1, end: 2, hardBreak: 3, inspected: 4)
        total.add(violations(start: 10, end: 20, hardBreak: 30, inspected: 40))
        XCTAssertEqual(total.lineStartsWithProhibited, 11)
        XCTAssertEqual(total.lineEndsWithProhibited, 22)
        XCTAssertEqual(total.hardBreakLines, 33)
        XCTAssertEqual(total.inspectedLineEnds, 44)
        XCTAssertEqual(total.total, 33)
    }

    // MARK: - Helpers

    private func violations(
        start: Int,
        end: Int,
        hardBreak: Int,
        inspected: Int
    ) -> Kinsoku.Violations {
        Kinsoku.Violations(
            lineStartsWithProhibited: start,
            lineEndsWithProhibited: end,
            hardBreakLines: hardBreak,
            inspectedLineEnds: inspected
        )
    }

    private func line(
        _ index: Int,
        consumed: (start: Int, length: Int),
        content: (start: Int, length: Int)
    ) throws -> LineRecord {
        try LineRecord(
            index: index,
            utf16Start: consumed.start,
            utf16Length: consumed.length,
            contentStart: content.start,
            contentLength: content.length,
            originX: 0,
            originY: 0,
            width: 0,
            ascent: 0,
            descent: 0,
            leading: 0
        )
    }
}
