import Foundation
import XCTest
@testable import SpikeAKit

/// The canonical primary text is the axis every offset is measured against, so
/// getting it wrong makes every other result wrong in a way nothing else
/// notices. ADR-0005 fixes two of its properties; the third is this spike's own
/// assumption and is named as such.
final class CanonicalTextTests: XCTestCase {

    private func canonical(_ body: String) throws -> CanonicalText {
        try XHTMLToCanonical.build(from: """
        <?xml version="1.0" encoding="utf-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml"><body>\(body)</body></html>
        """)
    }

    // MARK: - Axis exclusions (ADR-0005)

    func testRubyAnnotationDoesNotOccupyTheAxis() throws {
        let text = try canonical("<p>東京<ruby>京都<rt>きょうと</rt></ruby>へ</p>")
        XCTAssertEqual(text.string, "東京京都へ")
        XCTAssertFalse(text.string.contains("きょうと"))
    }

    func testRubyParenthesesAreExcludedToo() throws {
        let text = try canonical("<p><ruby>東京<rp>(</rp><rt>とうきょう</rt><rp>)</rp></ruby></p>")
        XCTAssertEqual(text.string, "東京")
    }

    /// The point of excluding them: hiding the annotation cannot move an offset.
    func testAnnotatedAndPlainTextAgreeOnOffsets() throws {
        let annotated = try canonical("<p>前<ruby>京都<rt>きょうと</rt></ruby>後</p>")
        let plain = try canonical("<p>前京都後</p>")
        XCTAssertEqual(annotated.string, plain.string)
    }

    // MARK: - The folding rule

    func testWhitespaceCollapsesToASingleSpace() throws {
        let text = try canonical("<p id=\"p\">   空白   折叠\t测试  </p>")
        XCTAssertEqual(text.element(withID: "p").flatMap { text.text(in: $0.utf16Range) }, "空白 折叠 测试")
    }

    /// The distinction that matters: whitespace between elements separates,
    /// whitespace inside a run does not appear from nowhere.
    func testWhitespaceAcrossAnElementBoundarySurvivesAsOneSpace() throws {
        let spaced = try canonical("<p>foo <b>bar</b></p>")
        let tight = try canonical("<p>foo<b>bar</b></p>")
        XCTAssertEqual(spaced.string, "foo bar")
        XCTAssertEqual(tight.string, "foobar")
    }

    /// The regression for a bug this file's author wrote: restoring the saved
    /// separator flag on close inserted a space the source never had.
    func testClosingAnElementDoesNotInsertASpacer() throws {
        let text = try canonical("<p>foo <b>bar</b> baz</p>")
        XCTAssertEqual(text.string, "foo bar baz")
    }

    func testLeadingAndTrailingWhitespaceIsDropped() throws {
        let text = try canonical("\n  <p>  hello  </p>\n  ")
        XCTAssertEqual(text.string, "hello")
    }

    // MARK: - UTF-16

    /// ADR-0004 fixes offsets to UTF-16 because that is what CoreText, CFString
    /// and NSRange index with. `text(in:)` must therefore slice `utf16` — a
    /// `String.Index` walk counts Characters and diverges the moment a non-BMP
    /// scalar appears.
    func testOffsetsAreUTF16NotCharacters() throws {
        // 𝕏 and 𝕐 are non-BMP: two UTF-16 units each.
        let text = try canonical("<p id=\"p\">𝕏𝕐中文</p>")
        XCTAssertEqual(text.string.count, 4, "Characters")
        XCTAssertEqual(text.utf16Count, 6, "UTF-16 units")

        let element = try XCTUnwrap(text.element(withID: "p"))
        XCTAssertEqual(element.utf16Range, 0..<6)
        XCTAssertEqual(text.text(in: 0..<2), "𝕏")

        // Slicing half a surrogate pair does not fail — it substitutes U+FFFD.
        // That is worth pinning, because it means a bad offset produces a
        // *plausible-looking* character rather than an error, and only a
        // boundary check can tell the difference.
        XCTAssertEqual(text.text(in: 0..<1), "\u{FFFD}")
        XCTAssertFalse(text.isMidCharacter(0))
        XCTAssertTrue(text.isMidCharacter(1))
    }

    func testMidCharacterDetectsAnOffsetInsideASurrogatePair() throws {
        let text = try canonical("<p id=\"p\">𝕏中</p>")
        XCTAssertFalse(text.isMidCharacter(0), "the start of the character is a boundary")
        XCTAssertTrue(text.isMidCharacter(1), "the low surrogate is not")
        XCTAssertFalse(text.isMidCharacter(2), "the start of 中 is a boundary")
        XCTAssertFalse(text.isMidCharacter(3), "the end of the text is not mid-character")
    }

    // MARK: - Identity map

    /// Paths are sibling indices among *element* children, from the root, so the
    /// wrapper elements are part of the chain: html[0] > body[0] > div[0] > p[i].
    func testElementsCarryPathsAndExplicitIDs() throws {
        let text = try canonical("<div id=\"d\"><p>a</p><p id=\"second\">b</p></div>")
        let div = try XCTUnwrap(text.element(withID: "d"))
        let second = try XCTUnwrap(text.element(withID: "second"))
        let first = try XCTUnwrap(text.element(at: [0, 0, 0, 0]))

        XCTAssertEqual(div.path, [0, 0, 0])
        XCTAssertEqual(second.path, [0, 0, 0, 1], "the second paragraph, one sibling along")
        XCTAssertNil(first.explicitID, "the first paragraph carries no id")
        XCTAssertEqual(text.text(in: first.utf16Range), "a")
    }

    /// More than one element with the same text is exactly the ambiguity an
    /// anchor has to survive, so the map must be able to report it.
    func testRepeatedTextIsReportedForEveryOccurrence() throws {
        let text = try canonical("<p>重复</p><p id=\"b\">重复</p>")
        XCTAssertEqual(text.elements(withText: "重复").count, 2)
    }

    func testInnermostElementWins() throws {
        let text = try canonical("<div><p id=\"inner\">abc</p></div>")
        XCTAssertEqual(text.innermostElement(containing: 0)?.explicitID, "inner")
    }

    // MARK: - Failure

    /// `XMLParser` is strict, which is the point: a malformed fixture must fail
    /// loudly rather than half-parse into plausible nonsense.
    func testMalformedXHTMLThrows() {
        XCTAssertThrowsError(try XHTMLToCanonical.build(from: "<html><body><p>unclosed</body></html>"))
    }
}
