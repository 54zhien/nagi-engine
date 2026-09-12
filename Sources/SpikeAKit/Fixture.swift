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

    /// Two units with byte-identical content, then a third for the awkward
    /// characters.
    ///
    /// `chap1` and `chap2` being identical is the point: the same `id` exists in
    /// both, at the same DOM path, with the same text. Anything that resolves a
    /// position without honouring the href will look correct and be wrong.
    public static let resources: [Resource] = [
        Resource(href: "OEBPS/chap1.xhtml", mediaType: "application/xhtml+xml", xhtml: chap1),
        Resource(href: "OEBPS/chap2.xhtml", mediaType: "application/xhtml+xml", xhtml: chap2),
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
}
