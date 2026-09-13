import Foundation
import XCTest
import SpikeKit

/// The contract both spikes' stdout tables rest on.
///
/// The property that matters is **a cell never touches the cell after it**, and
/// it is easy to lose by writing the obvious `text.count >= width ? text : …`.
/// That form looks correct while every literal in the column happens to be
/// short, and stops being correct the day one grows: the CI log printed
/// `kinsoku-language-tag-effectMEASURED` for exactly that reason, and the same
/// shape read `native->locator->nativeneeds reanchor` in Spike A.
///
/// Plain `import` rather than `@testable`: this is the published surface, and a
/// contract test should exercise it the way a caller does.
final class TerminalColumnsTests: XCTestCase {

    // MARK: - terminalColumn

    /// The three things a renderer can be handed — shorter than its column,
    /// exactly as long, and longer — and the separator each must end with. The
    /// middle one is the case an obvious implementation misses, because
    /// "exactly as long" is where padding and appending disagree.
    func testEveryCellEndsWithASeparator() throws {
        let width = 10

        let shorter = terminalColumn("abc", width)
        XCTAssertEqual(shorter, "abc" + String(repeating: " ", count: width - 3))
        XCTAssertEqual(shorter.count, width, "a short cell pads out to the column width")

        XCTAssertEqual(
            terminalColumn("abcdefghij", width), "abcdefghij ",
            "a cell exactly as wide as its column still gets a separator"
        )

        let longer = terminalColumn("abcdefghijk", width)
        XCTAssertEqual(longer, "abcdefghijk ", "an over-long cell gets a separator too")
        XCTAssertTrue(longer.hasPrefix("abcdefghijk"), "and is not truncated to make room for it")

        // **The property, over widths and lengths this test does not list.**
        // Three examples would pin the cases someone thought of; this pins the
        // rule. A cell is never truncated, so the rendered length is the greater
        // of the column width and the cell plus its separator.
        for columnWidth in 1...12 {
            for length in 0...20 {
                let cell = String(repeating: "x", count: length)
                let rendered = terminalColumn(cell, columnWidth)
                XCTAssertGreaterThanOrEqual(
                    rendered.count, length + 1,
                    "a \(length)-character cell rendered into width \(columnWidth) left no separator"
                )
                XCTAssertTrue(
                    rendered.hasSuffix(" "),
                    "width \(columnWidth), cell length \(length): \(rendered.debugDescription)"
                )
                XCTAssertTrue(rendered.hasPrefix(cell), "the cell itself must survive intact")
            }
        }
    }

    // MARK: - columnWidth

    /// The separator is reserved for the widest cell, and the declared width is
    /// a **floor** rather than something the content can lower — otherwise a
    /// table with short values would collapse to its content and lose the
    /// alignment it exists for.
    func testColumnWidthReservesTheSeparatorAboveTheDeclaredFloor() throws {
        XCTAssertEqual(columnWidth(4, ["a", "bb", "ccc"]), 4, "the widest cell plus one is the floor")
        XCTAssertEqual(columnWidth(4, ["a", "bb", "ccccccc"]), 8, "seven characters plus the separator")

        XCTAssertEqual(columnWidth(10, []), 10, "no cells at all leaves the declared width")
        XCTAssertEqual(columnWidth(10, ["abc"]), 10)
        XCTAssertEqual(
            columnWidth(10, ["abcdefghi"]), 10,
            "nine plus one is exactly the floor, so the floor still decides"
        )
        XCTAssertEqual(
            columnWidth(10, ["abcdefghij"]), 11,
            "ten plus one exceeds the floor, so the content decides"
        )
    }
}
