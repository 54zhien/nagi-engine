import Foundation

/// The canonical primary text of one content unit, plus the map from element
/// identity to a range in it.
///
/// ADR-0005 says every Native Position offset indexes ONE canonical text, and
/// that ruby annotations (`<rt>` / `<rp>`) and CSS-folded whitespace **do not
/// occupy its axis**. This is the smallest thing that can honour that and still
/// let an offset be turned back into a node.
///
/// Every range here is in UTF-16 units, because that is what CoreText, CFString,
/// `NSRange` and UIKit selection all index with (ADR-0004). Which is also why
/// `text(in:)` slices `utf16` rather than using `String.Index` arithmetic:
/// `offsetBy` counts Characters, and the two diverge the moment a non-BMP
/// character appears — one of the axes this spike exists to measure.
public struct CanonicalText: Sendable, Hashable {
    public var string: String
    /// Addressable elements, in document order. Elements that contribute no
    /// text are present with an empty range — they can still be addressed by id,
    /// and an anchor may well point at one.
    public var elements: [Element]

    public struct Element: Sendable, Hashable {
        /// Lowercased local name.
        public var name: String
        /// `id=` or `xml:id=`, verbatim.
        public var explicitID: String?
        /// Sibling index among *element* children, from the root. Element-only
        /// on purpose: counting text nodes too would make the path move whenever
        /// the source is re-indented.
        public var path: [UInt32]
        public var utf16Range: Range<Int>

        public var isEmpty: Bool { utf16Range.isEmpty }
    }

    public var utf16Count: Int { string.utf16.count }

    /// The canonical text inside a UTF-16 range.
    public func text(in range: Range<Int>) -> String? {
        let units = Array(string.utf16)
        guard range.lowerBound >= 0, range.upperBound <= units.count, range.lowerBound <= range.upperBound else {
            return nil
        }
        return String(decoding: units[range], as: UTF16.self)
    }

    public func element(withID id: String) -> Element? {
        elements.first { $0.explicitID == id }
    }

    public func element(at path: [UInt32]) -> Element? {
        elements.first { $0.path == path }
    }

    /// Elements carrying exactly this text. More than one is the ambiguity an
    /// anchor has to survive — the "repeated text" axis.
    public func elements(withText text: String) -> [Element] {
        elements.filter { self.text(in: $0.utf16Range) == text }
    }

    /// True when an offset does not sit on a text boundary: it lands on a low
    /// surrogate, splitting a non-BMP character.
    ///
    /// ADR-0004 gives `PositionResolver` its own layer because "is this offset
    /// legal, and where should it snap?" is a different question from "does this
    /// position still mean the same thing". The bridge deliberately answers
    /// neither, and this is how the report can show that.
    public func isMidCharacter(_ offset: Int) -> Bool {
        let units = Array(string.utf16)
        guard offset > 0, offset < units.count else { return false }
        return (0xDC00...0xDFFF).contains(units[offset])
    }

    /// The deepest element containing this offset, i.e. the node an offset in
    /// the middle of the text belongs to.
    public func innermostElement(containing offset: Int) -> Element? {
        elements
            .filter { $0.utf16Range.contains(offset) }
            .max { $0.path.count < $1.path.count }
    }
}

/// The whitespace rule, written down as its own function because it is an
/// assumption of this spike rather than CSS.
public enum WhitespaceFolding {
    public static func isWhitespace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
    }

    /// A run of ASCII whitespace becomes a single U+0020; a run that crosses an
    /// element boundary survives as one space; leading and trailing whitespace is
    /// dropped.
    ///
    /// This is NOT CSS `white-space` processing, and the fixture avoids
    /// `white-space` overrides so the difference cannot bite. What it does
    /// preserve is the distinction that matters for offsets: `foo <b>bar</b>`
    /// and `foo<b>bar</b>` are different texts.
    ///
    /// `pendingSeparator` carries the "a space is owed" state across calls, so
    /// the caller can fold a run, walk into a child element, and fold again
    /// without losing the boundary whitespace.
    public static func fold(_ run: String, pendingSeparator: inout Bool, into output: inout String) {
        for character in run {
            if isWhitespace(character) {
                pendingSeparator = true
                continue
            }
            if pendingSeparator {
                if !output.isEmpty, output.last != " " { output.append(" ") }
                pendingSeparator = false
            }
            output.append(character)
        }
    }
}

/// Turns XHTML into `CanonicalText` using Foundation's `XMLParser`.
///
/// `XMLParser` rather than a hand-rolled scanner or a dependency because it is
/// strict, streaming, and already present. Being strict is a feature here: the
/// fixture must be well-formed, and an ill-formed one should fail loudly rather
/// than half-parse into plausible nonsense.
public enum XHTMLToCanonical {
    /// Elements whose subtrees do not occupy the axis — ADR-0005.
    static let axisExcluded: Set<String> = ["rt", "rp"]

    /// Elements outside the reading flow.
    ///
    /// `head` is metadata. A `<title>` is not something a reader scrolls past,
    /// so letting its text into the canonical text shifts every offset in the
    /// body by a constant and makes "the canonical text" something other than
    /// what the reader sees. The first CI run said so: a paragraph that should
    /// have started at 0 started at 9, because `第一章` appeared twice — once in
    /// the title and once in the heading.
    static let flowExcluded: Set<String> = ["head"]

    static func isExcluded(_ name: String) -> Bool {
        axisExcluded.contains(name) || flowExcluded.contains(name)
    }

    public static func build(from xhtml: String) throws -> CanonicalText {
        let builder = XHTMLBuilder()
        let parser = XMLParser(data: Data(xhtml.utf8))
        parser.delegate = builder
        guard parser.parse() else {
            throw CanonicalTextError.malformedXHTML(
                parser.parserError?.localizedDescription ?? "unknown XMLParser failure"
            )
        }
        return builder.finish()
    }
}

public enum CanonicalTextError: Error, CustomStringConvertible {
    case malformedXHTML(String)

    public var description: String {
        switch self {
        case .malformedXHTML(let reason):
            return "the fixture is not well-formed XHTML: \(reason)"
        }
    }
}

private final class XHTMLBuilder: NSObject, XMLParserDelegate {
    private struct Open {
        var index: Int
        var start: Int
    }

    private var output = ""
    private var elements: [CanonicalText.Element] = []
    private var stack: [Open] = []
    private var siblingCounts: [UInt32] = []
    private var excludedDepth = 0
    private var pendingSeparator = false

    func finish() -> CanonicalText {
        CanonicalText(string: output, elements: elements)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let name = elementName.lowercased()

        if excludedDepth > 0 {
            excludedDepth += 1
            return
        }
        if XHTMLToCanonical.isExcluded(name) {
            excludedDepth = 1
            return
        }

        let depth = stack.count
        while siblingCounts.count <= depth { siblingCounts.append(0) }
        let index = siblingCounts[depth]
        siblingCounts[depth] = index + 1
        // A path is a chain of sibling indices, so deeper counters restart when
        // we descend rather than continuing one running count.
        if siblingCounts.count > depth + 1 {
            siblingCounts.removeSubrange((depth + 1)..<siblingCounts.count)
        }

        var path = stack.last.map { open in elements[open.index].path } ?? []
        path.append(index)

        // Settle any pending separator BEFORE this element's range is recorded.
        // Otherwise the space that belonged between two elements gets emitted
        // when this element's first character arrives, and lands inside this
        // element's range — so `<p>前</p><p>空白</p>` would report the second
        // paragraph as " 空白" and every offset in it would be one out.
        // The `last != " "` guard matters: the element's own leading whitespace
        // still sets the flag again, and without it the separator emitted here
        // and the one owed by that whitespace would both land — producing
        // "空白" with two spaces in front. The first CI run reported exactly
        // that.
        if pendingSeparator, !output.isEmpty {
            if output.last != " " { output.append(" ") }
            pendingSeparator = false
        }

        // Appended here, in document order, with its range patched on close —
        // appending on close would order elements by where they end.
        elements.append(CanonicalText.Element(
            name: name,
            explicitID: attributeDict["id"] ?? attributeDict["xml:id"],
            path: path,
            utf16Range: output.utf16.count..<output.utf16.count
        ))
        stack.append(Open(index: elements.count - 1, start: output.utf16.count))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard excludedDepth == 0 else { return }
        WhitespaceFolding.fold(string, pendingSeparator: &pendingSeparator, into: &output)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard excludedDepth == 0 else { return }
        let text = String(decoding: CDATABlock, as: UTF8.self)
        WhitespaceFolding.fold(text, pendingSeparator: &pendingSeparator, into: &output)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if excludedDepth > 0 {
            excludedDepth -= 1
            return
        }
        guard let open = stack.popLast() else { return }
        // `pendingSeparator` is deliberately NOT restored from here: it has
        // already been advanced by whatever this element emitted, and putting a
        // saved value back would insert a separator the source never had
        // (`<p>foo <b>bar</b></p>` would come out "foo bar baz").
        elements[open.index].utf16Range = open.start..<output.utf16.count
    }
}
