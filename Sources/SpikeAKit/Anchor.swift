import Foundation

/// What an anchor remembers about the text it pointed at.
///
/// **Deliberately not `ReadiumLocator.Text`.** That type belongs to the
/// Publication Position mirror and its shape is Readium's. Here the quotation
/// and its surroundings are **content**, not a member of someone else's wire
/// format. The two look alike because both describe "some text and what sits
/// next to it" — which is not the same thing as being the same type, and
/// importing the mirror would make one of them change whenever the other does.
public struct AnchorQuote: Codable, Sendable, Hashable {
    /// The text to find. Matched literally, one UTF-16 code unit at a time.
    public var exact: String
    /// Text immediately **before** `exact`. `nil` and `""` both mean "no
    /// constraint" — neither is "match the empty string here", which would be
    /// a constraint every offset satisfies.
    public var prefix: String?
    /// Text immediately **after** `exact`. `nil` and `""` both mean "no constraint".
    public var suffix: String?

    public init(exact: String, prefix: String? = nil, suffix: String? = nil) {
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
    }
}

/// A durable reference to a piece of content: **where it was, plus what it said**.
///
/// The position is optional because this layer exists for the case where it is
/// gone — a unit removed, an offset invalidated. The quote is not optional:
/// without it there is nothing to re-anchor to, and `ReanchorService` says so
/// rather than guessing.
public struct Anchor: Codable, Sendable, Hashable {
    public var position: NativePosition?
    public var quote: AnchorQuote

    public init(position: NativePosition?, quote: AnchorQuote) {
        self.position = position
        self.quote = quote
    }
}

/// **By which route** a relocation succeeded. Reported rather than inferred, so
/// a reader can tell "the old position still held" from "the text was found
/// again somewhere else" — two very different claims about the same result.
public enum ReanchorMethod: String, Codable, Sendable, Hashable {
    /// The stored position still validated. No search was needed.
    case originalPosition
    /// Exactly one literal occurrence, and no context was needed to choose it.
    case uniqueExactQuote
    /// Several occurrences, separated by the stored prefix and suffix.
    case quoteContext
}

/// Why nothing was found. Two reasons, because "you gave me nothing" and "the
/// text is not here" are different findings about different things.
public enum ReanchorNotFoundReason: String, Codable, Sendable, Hashable {
    case emptyQuote
    case exactTextMissing
}

public enum ReanchorResult: Codable, Sendable, Hashable {
    case relocated(NativePosition, method: ReanchorMethod)
    /// **A result, not a failure.** Several occurrences survived the context
    /// filter, so nothing here can choose between them. Picking one — by
    /// proximity or by the old `unitID` — would point a reader at content they
    /// did not annotate, silently.
    case ambiguous([NativePosition])
    case notFound(ReanchorNotFoundReason)
}

/// The one place `exact` / `prefix` / `suffix` become matches.
///
/// `AnchorValidator` and `ReanchorService` both need the same rules — "every
/// non-empty part must hold", "overlaps count", "`nil` and `""` mean no
/// constraint" — and two copies of those rules would drift apart in exactly the
/// way ADR-0012 forbids. Hence one helper, `internal`, used by both.
///
/// Everything here is `[UInt16]`. Not `String.range`, not `localized`, not a
/// regex: each of those brings its own notion of text equality (grapheme
/// clusters, locale-sensitive folding, pattern semantics), and the coordinate
/// system this anchors into is UTF-16 code units (ADR-0004).
enum AnchorMatching {

    /// UTF-16 code units. **Not `Array(string)`** — that yields `Character`s,
    /// and the two diverge the moment a non-BMP character appears, which is one
    /// of the axes this spike exists to measure.
    static func units(_ text: String) -> [UInt16] {
        Array(text.utf16)
    }

    /// Does `needle` sit at `offset` in `haystack`?
    ///
    /// **The bounds are compared, never added.** `offset + needle.count` traps
    /// on overflow, and `offset` arrives from a persisted coordinate — a
    /// corrupt or hostile `Int.max` would crash the process instead of being
    /// answered `invalid`. So the check counts *down* from the haystack, which
    /// cannot overflow for any `Int` inputs.
    static func matches(_ needle: [UInt16], in haystack: [UInt16], at offset: Int) -> Bool {
        guard offset >= 0, offset <= haystack.count else { return false }
        guard needle.count <= haystack.count - offset else { return false }
        var index = 0
        while index < needle.count {
            if haystack[offset + index] != needle[index] { return false }
            index += 1
        }
        return true
    }

    /// Every offset at which `needle` occurs, **ascending, overlaps included**.
    ///
    /// Overlaps are included because excluding them would be a rule about
    /// search convenience that no anchor ever asked for: the text "aaa" does
    /// contain "aa" at 0 *and* at 1, and an anchor storing "aa" should be told
    /// that two places match rather than one.
    static func occurrences(of needle: [UInt16], in haystack: [UInt16]) -> [Int] {
        guard !needle.isEmpty, needle.count <= haystack.count else { return [] }
        var found: [Int] = []
        let last = haystack.count - needle.count
        var offset = 0
        while offset <= last {
            if matches(needle, in: haystack, at: offset) { found.append(offset) }
            offset += 1
        }
        return found
    }

    /// Does every **non-empty** part of the context hold around an occurrence of
    /// `exactLength` units at `offset`?
    ///
    /// `prefix` is the text **ending** at `offset`; `suffix` is the text
    /// **starting** at `offset + exactLength`. Empty parts are skipped, which is
    /// what makes "no constraint" and "empty string" the same input.
    ///
    /// Subtraction and addition here are both bounded before they happen, for
    /// the same reason as in `matches`: `offset` comes from stored data.
    static func contextHolds(
        exactAt offset: Int,
        exactLength: Int,
        prefix: [UInt16],
        suffix: [UInt16],
        in haystack: [UInt16]
    ) -> Bool {
        guard offset >= 0, exactLength >= 0 else { return false }
        guard offset <= haystack.count else { return false }
        guard exactLength <= haystack.count - offset else { return false }

        if !prefix.isEmpty {
            guard prefix.count <= offset else { return false }
            let start = offset - prefix.count
            guard matches(prefix, in: haystack, at: start) else { return false }
        }
        if !suffix.isEmpty {
            // Safe to add: `exactLength <= haystack.count - offset` was just
            // established, so the sum cannot exceed `haystack.count`.
            let after = offset + exactLength
            guard matches(suffix, in: haystack, at: after) else { return false }
        }
        return true
    }

    /// The node an offset sits in, spelled as the `NodeID` ladder's two
    /// implemented rungs: an explicit id wins, otherwise the path (ADR-0003).
    ///
    /// Returns `nil` when no element contains the offset — an offset at the very
    /// end of the text is in no range, since ranges are half-open. The callers
    /// treat that as "cannot be expressed", not as "matches the last element".
    static func nodeID(forOffset offset: Int, in canonical: CanonicalText) -> NodeID? {
        guard let element = canonical.innermostElement(containing: offset) else { return nil }
        if let id = element.explicitID { return .explicitID(id) }
        return .path(element.path)
    }
}
