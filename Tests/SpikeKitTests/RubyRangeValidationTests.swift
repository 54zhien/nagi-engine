import CoreText
import Foundation
import XCTest
import SpikeKit

/// Exercise the public builder with representable NSRange values, including
/// ranges whose endpoint cannot be computed by unchecked integer addition.
final class RubyRangeValidationTests: XCTestCase {
    private let text = "漢字かな"
    private let annotationText = "かんじ"
    private let rubyKey = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)

    func testLocationIntMaxIsIgnored() {
        assertRubyIgnored(for: NSRange(location: Int.max, length: 1))
    }

    func testLengthIntMaxIsIgnored() {
        assertRubyIgnored(for: NSRange(location: 1, length: Int.max))
    }

    func testNegativeLengthIsIgnored() {
        assertRubyIgnored(for: NSRange(location: 1, length: -1))
    }

    func testRangePastEndIsIgnored() {
        let length = text.utf16.count
        XCTAssertEqual(length, 4)
        assertRubyIgnored(for: NSRange(location: length - 1, length: 2))
    }

    func testNotFoundRangeIsIgnored() {
        assertRubyIgnored(for: NSRange(location: NSNotFound, length: 0))
    }

    /// A builder that simply drops all annotations must fail this control.
    func testRangeInsideTextAppliesRubyOnlyToThatRange() throws {
        let target = NSRange(location: 0, length: 2)
        let result = attributed(rubyRange: target)

        XCTAssertEqual(result.string, text)
        XCTAssertEqual(result.length, text.utf16.count)

        var effective = NSRange(location: NSNotFound, length: 0)
        _ = try XCTUnwrap(
            result.attribute(rubyKey, at: target.location, effectiveRange: &effective),
            "ruby attribute missing from the target range"
        )
        XCTAssertEqual(effective, target)

        for index in 0..<result.length {
            let present = result.attribute(rubyKey, at: index, effectiveRange: nil) != nil
            XCTAssertEqual(present, NSLocationInRange(index, target))
        }
    }

    private func attributed(rubyRange: NSRange) -> NSAttributedString {
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let input = LayoutInput(
            text: text,
            font: font,
            fontSize: 16,
            measureWidth: 200,
            pageHeight: 200,
            label: "ruby-range-validation",
            ruby: (annotation: annotationText, range: rubyRange)
        )
        return TextLayout.attributedString(input)
    }

    private func assertRubyIgnored(
        for range: NSRange,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = attributed(rubyRange: range)
        XCTAssertEqual(result.string, text, file: file, line: line)
        XCTAssertEqual(result.length, text.utf16.count, file: file, line: line)

        result.enumerateAttribute(
            rubyKey,
            in: NSRange(location: 0, length: result.length)
        ) { value, span, _ in
            XCTAssertNil(
                value,
                "ruby applied at \(span) for rejected range \(range)",
                file: file,
                line: line
            )
        }
    }
}
