import Foundation

/// The corpus, embedded as source.
///
/// Same reasoning as Spike B's fixture: an external artifact brings variables
/// nobody asked about — Spike B's bundled font turned out to be a SinoType face
/// that silently substituted for a character we were measuring. Here the
/// "artifact" would be an EPUB, and there is not one on the build machine
/// anyway.
///
/// There is deliberately no ZIP. Spike A asks about **position identity**, not
/// container parsing, so the fixture is the thing a DocumentStore would
/// eventually materialise: XHTML plus a reading order. That also means every
/// axis below is engineered rather than hunted for.
public enum SpikeAFixture {
    public static let name = "identity-v1"

    /// The annotation inside `<ruby>`, and the text that repeats. Named here so
    /// a probe and a test cannot drift apart from the fixture they describe.
    public static let annotation = "きょうと"
    public static let repeatedText = "他缓缓向前走去。"

    public struct Resource: Sendable {
        public var href: String
        public var mediaType: String
        public var xhtml: String
    }

    /// Two units with byte-identical content, an empty one between them and the
    /// awkward characters, then the awkward characters.
    ///
    /// `chap1` and `chap2` being identical is the point: the same `id` exists in
    /// both, at the same DOM path, with the same text. Anything that resolves a
    /// position without honouring the href will look correct and be wrong.
    ///
    /// `blank` sits **between** two units with text, which is where a prefix sum
    /// that is off by one shows itself: the coordinate at its start and the
    /// coordinate at its end must be the *same* number, not two numbers a unit
    /// apart. Put at the end it would have no neighbour to be equal to.
    public static let resources: [Resource] = [
        Resource(href: "OEBPS/chap1.xhtml", mediaType: "application/xhtml+xml", xhtml: chap1),
        Resource(href: "OEBPS/chap2.xhtml", mediaType: "application/xhtml+xml", xhtml: chap2),
        Resource(href: "OEBPS/blank.xhtml", mediaType: "application/xhtml+xml", xhtml: blank),
        Resource(href: "OEBPS/chap3.xhtml", mediaType: "application/xhtml+xml", xhtml: chap3)
    ]

    public static func document() throws -> Document {
        let units = try resources.map { resource in
            DocumentUnit(
                id: resource.href,
                href: resource.href,
                mediaType: resource.mediaType,
                canonical: try XHTMLToCanonical.build(from: resource.xhtml)
            )
        }
        return Document(readingOrder: units)
    }

    // MARK: - The units

    /// Explicit ids on some blocks and not others, and two blocks carrying
    /// identical text — one of them with an id, one without.
    static let chap1 = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>第一章</title></head>
    <body>
    <h1 id="ch1">第一章</h1>
    <p id="p1">韩立望着眼前的山谷，沉默了片刻。</p>
    <p>他缓缓向前走去。</p>
    <p id="dup">他缓缓向前走去。</p>
    <p id="p4">山谷之中云雾缭绕，隐约可以听见流水的声音。</p>
    <p>走了大约三百步之后，他停下了。</p>
    </body>
    </html>
    """

    /// Byte-identical to `chap1`, href aside.
    static let chap2 = chap1

    /// A unit with a canonical text of **length zero**.
    ///
    /// `<head>` is excluded from the reading flow, so all that is left is an
    /// empty `<body>`. This is not a contrived shape: it is a cover page whose
    /// only content is an image, or a chapter that is a section break. It is
    /// also the input that makes `0 / 0` reachable on the per-unit helper this
    /// spike deletes, and the input on which a naive prefix sum either jumps or
    /// produces NaN.
    static let blank = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>空章</title></head>
    <body></body>
    </html>
    """

    /// The awkward characters.
    ///
    ///   - `astral` puts non-BMP scalars (surrogate pairs) inside a block, so a
    ///     bridge that confuses Character counts with UTF-16 counts lands wrong.
    ///   - `ruby` puts an annotation in the middle of a line; ADR-0005 says
    ///     `<rt>` does not occupy the axis, so the canonical text must read
    ///     京都へ行った。 and the annotation must not shift any offset after it.
    ///   - `spaced` exercises the folding rule at both ends and the middle.
    static let chap3 = """
    <?xml version="1.0" encoding="utf-8"?>
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>第三章</title></head>
    <body>
    <p id="astral">记号 𠀋 与 𝕏𝕐𝕫 之后。</p>
    <p id="ruby"><ruby>京都<rt>きょうと</rt></ruby>へ行った。</p>
    <p id="spaced">   空白   折叠   测试   </p>
    </body>
    </html>
    """

    // MARK: - The byte resource
    //
    // Twelve bytes carrying one instance of each way a byte offset can fail to
    // be a place text begins:
    //
    //   bytes:  E8 AE B0 | 0D 0A | 41 | FF | E8 AE B0 | 0D 0A
    //   offset: 0  1  2  | 3  4  | 5  | 6  | 7  8  9  | 10 11
    //
    //   1, 2, 8, 9   inside the two `记` — continuation bytes
    //   4, 11        between the `\r` and the `\n` of one CRLF
    //   7            directly after the ill-formed byte, whose legality is a
    //                decoder policy rather than a fact about the bytes
    //
    // Twelve and not eight, because the three hazards have to be reachable
    // *independently*: a seek that lands on one of them proves nothing about the
    // others.

    public static let byteBytes: [UInt8] = [
        0xE8, 0xAE, 0xB0,   // 记  (U+8BB0, three bytes)
        0x0D, 0x0A,         // CRLF — one line break, two bytes
        0x41,               // A
        0xFF,               // ill-formed: no valid UTF-8 sequence starts here
        0xE8, 0xAE, 0xB0,   // 记 again
        0x0D, 0x0A          // CRLF again
    ]

    /// **Hand-written, never derived from the code under test.**
    ///
    /// The byte offsets at which decoded text may begin. 4 and 11 are absent
    /// because a CRLF is a single line break — a boundary between its two bytes
    /// is not a place a text unit begins, and a producer that emitted one would
    /// be splitting a newline in half.
    ///
    /// If this list were computed by the same code that snaps a seek, the oracle
    /// and the thing under test would share whatever bug they have, and the probe
    /// would be true by construction. That is precisely the shape of the first
    /// round's `.exact` verdict, and the reason this array is typed by hand.
    public static let legalByteBoundaries = [0, 3, 5, 6, 7, 10, 12]

    /// Three **declarations** of one resource, not three resources: same href,
    /// same bytes, same hand-written boundaries. The only thing that varies
    /// across them is what the container says its pagination is, so a probe can
    /// vary that one field and have nothing else move.
    ///
    /// Page counts stay at powers of two so that `(k + 0.5) / N × N` is exact in
    /// IEEE-754 — see `FixedPageOrdinalAxis`. Every page start is also a legal
    /// byte boundary, because a container that began a page mid-character would
    /// be describing something that cannot be rendered.
    public static let reflowableByteResource = ByteResource(
        href: byteResourceHref,
        bytes: byteBytes,
        legalBoundaries: legalByteBoundaries,
        pageRanges: nil
    )

    public static let twoPageByteResource = ByteResource(
        href: byteResourceHref,
        bytes: byteBytes,
        legalBoundaries: legalByteBoundaries,
        pageRanges: [0..<6, 6..<12]
    )

    public static let fourPageByteResource = ByteResource(
        href: byteResourceHref,
        bytes: byteBytes,
        legalBoundaries: legalByteBoundaries,
        pageRanges: [0..<5, 5..<7, 7..<10, 10..<12]
    )

    public static let byteResourceHref = "OEBPS/raw.bin"
}
