import Foundation

/// A resource whose unit of position is the **byte**, plus the two things a
/// container can declare about it.
///
/// Deliberately not XHTML. A resource that has been through `XMLParser` cannot
/// expose an offset inside a UTF-8 sequence — the parser never sees one — so a
/// fixture built from markup cannot ask whether a byte coordinate is a place
/// text may begin. The hazard only exists on raw bytes.
///
/// `Sendable` is not decoration: the axes that hold this are `Sendable`, and a
/// stored non-`Sendable` property in an explicitly `Sendable` type is a hard
/// error.
public struct ByteResource: Sendable {
    public var href: String
    public var bytes: [UInt8]

    /// **Hand-written, never derived from the code under test.**
    ///
    /// The byte offsets at which decoded text may begin. If this list were
    /// computed by the same code that snaps a seek, the oracle and the thing
    /// being tested would share a bug and the probe would be a tautology — which
    /// is the disease the first round's `.exact` verdict had.
    public var legalBoundaries: [Int]

    /// Hand-written as well. `nil` means the container declares **no**
    /// pagination — reflowable content — and that `nil` is ADR-0008's admission
    /// criterion made into data rather than into a paragraph: a page ordinal may
    /// only be exposed where the container itself states one.
    ///
    /// Page counts are restricted to powers of two in this spike's fixture, so
    /// that `(ordinal + 0.5) / pageCount × pageCount` is exact in IEEE-754. See
    /// `FixedPageOrdinalAxis`.
    public var pageRanges: [Range<Int>]?

    public init(
        href: String,
        bytes: [UInt8],
        legalBoundaries: [Int],
        pageRanges: [Range<Int>]? = nil
    ) {
        self.href = href
        self.bytes = bytes
        self.legalBoundaries = legalBoundaries
        self.pageRanges = pageRanges
    }

    public var byteCount: Int { bytes.count }

    public var decoded: String { String(decoding: bytes, as: UTF8.self) }

    /// The resource's text as one addressable element — the shape a
    /// `DocumentUnit` needs, so that a text-indexed metric can be built over
    /// **the same bytes** the byte-indexed metrics see.
    public var canonicalText: CanonicalText {
        let text = decoded
        return CanonicalText(
            string: text,
            elements: [
                CanonicalText.Element(
                    name: "resource",
                    explicitID: nil,
                    path: [0],
                    utf16Range: 0..<text.utf16.count
                )
            ]
        )
    }

    /// A one-unit `Document` over this resource's text, carrying the same href —
    /// so a position minted for a byte axis is also a position on the text axis.
    public var singleUnitDocument: Document {
        Document(readingOrder: [
            DocumentUnit(
                id: href,
                href: href,
                mediaType: "application/octet-stream",
                canonical: canonicalText
            )
        ])
    }

    // MARK: - The byte <-> text map
    //
    // Built by decoding every prefix and counting, rather than by scanning UTF-8
    // lead bytes by hand.
    //
    // The scanner was the obvious approach and it is the wrong one for two
    // reasons. It has to reproduce the **maximal subpart** rule (Unicode 15
    // §3.9: an ill-formed sequence is consumed up to the first byte that cannot
    // continue it, so `FF` consumes exactly one byte) — and the tempting
    // shorthand for that, `UTF8.width(scalar)`, answers a different question: it
    // is the **re-encoded** width, so `UTF8.width(U+FFFD)` is 3 where the source
    // byte was 1. Prefix decoding has neither problem and uses a call the
    // repository already relies on (`CanonicalText.swift`).
    //
    // It is O(n²). At twelve bytes that is not a cost.

    /// The UTF-16 offset that the prefix `bytes[0..<offset]` decodes to.
    ///
    /// Monotone non-decreasing, and **not injective**: 1 and 2 both decode to a
    /// single replacement character, and so the naive "first byte offset with
    /// this count" inverse would land inside `E8 AE B0`.
    public func utf16Offset(forByte offset: Int) -> Int? {
        guard offset >= 0, offset <= byteCount else { return nil }
        return String(decoding: bytes[0..<offset], as: UTF8.self).utf16.count
    }

    /// The byte offset at which the decoded text's `offset`-th UTF-16 unit
    /// begins, or `byteCount` for the end of the text.
    ///
    /// **The largest** byte offset with that prefix count, not the smallest. A
    /// truncated multi-byte sequence at the end of a prefix decodes to a
    /// replacement character and so reports the same count one byte early; the
    /// run only ends when the sequence completes, which is the boundary that is
    /// real. Taking the first match instead is a genuine bug — it maps UTF-16
    /// offset 1 to byte 1, the interior of `E8 AE B0`, rather than to byte 3.
    ///
    /// This can return an offset that is **not** in `legalBoundaries`: the `\n`
    /// of a CRLF is a real UTF-16 unit whose byte offset sits between the two
    /// bytes of one line break. That is honest reporting, and it is what keeps
    /// the seek probe from being a tautology — the snapping belongs to
    /// `position(near:)`, not here.
    public func byteOffset(forUTF16 offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        var found: Int?
        for candidate in 0...byteCount where utf16Offset(forByte: candidate) == offset {
            found = candidate
        }
        return found
    }

    /// The number of UTF-16 units in the whole decoded text.
    public var utf16Count: Int { utf16Offset(forByte: byteCount) ?? 0 }

    /// Every byte offset the map actually produces, ascending — one per UTF-16
    /// unit plus the end. This is the set a seek may be *asked* for by a position
    /// that exists, and it is a **superset of `legalBoundaries`**: the two `\n`
    /// units sit inside their CRLFs.
    ///
    /// Built from `byteOffset(forUTF16:)` rather than from the prefix counts, so
    /// that there is one definition of "the byte offset of this text offset" in
    /// the file.
    public var decodedBoundaries: [Int] {
        var result: [Int] = []
        for unit in 0...utf16Count {
            guard let byte = byteOffset(forUTF16: unit) else { return [] }
            result.append(byte)
        }
        return result
    }

    /// A position at a byte boundary, if the byte offset begins a UTF-16 unit.
    ///
    /// The guard is the map agreeing with itself: a byte offset that does not
    /// survive the round trip through its own text offset names the middle of a
    /// character, and there is no position there.
    public func position(atByte offset: Int) -> NativePosition? {
        guard let utf16 = utf16Offset(forByte: offset) else { return nil }
        guard byteOffset(forUTF16: utf16) == offset else { return nil }
        return position(atUTF16: utf16)
    }

    /// A position at an offset into the decoded text. Every UTF-16 offset in
    /// `0...utf16Count` has one, including the two that sit inside a CRLF — those
    /// are real text units, and it is the *byte* offset of the second that is not
    /// a legal place to begin.
    public func position(atUTF16 offset: Int) -> NativePosition? {
        guard offset >= 0, offset <= utf16Count else { return nil }
        return NativePosition(unitID: href, nodeID: .path([0]), utf16Offset: offset)
    }

    // MARK: - Hazards

    /// The three ways a byte offset can fail to be a place text begins.
    ///
    /// Typed rather than counted, because "three hazards are present" as a bare
    /// count is not checkable — the illegal-offset arithmetic gives 4 or 5
    /// depending on how you count the invalid lead byte. Each type has to occur
    /// at least once for the fixture to be exercising what it claims to.
    public enum BoundaryHazard: String, Sendable, Hashable, CaseIterable {
        /// Inside a multi-byte sequence: the byte at this offset is a
        /// continuation byte, so a boundary here would split a scalar.
        case multiByteInterior
        /// Between the `\r` and the `\n` of one CRLF. A CRLF is a single line
        /// break, so a boundary inside it is not a place a text unit begins.
        case crlfInterior
        /// Directly after an ill-formed byte. Its legality is a **policy**: the
        /// maximal-subpart rule consumes exactly one byte and makes this offset a
        /// boundary, while a decoder that grouped the bad byte with what follows
        /// would not. The hand-written table says one byte, and the probe checks
        /// the table against the map.
        case invalidLeadByteWidth
    }

    public func hazard(atByte offset: Int) -> BoundaryHazard? {
        guard offset > 0, offset < byteCount else { return nil }
        if bytes[offset - 1] == 0x0D, bytes[offset] == 0x0A { return .crlfInterior }
        if (bytes[offset] & 0xC0) == 0x80 { return .multiByteInterior }
        if bytes[offset - 1] == 0xFF { return .invalidLeadByteWidth }
        return nil
    }
}
