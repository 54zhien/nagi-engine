import Foundation

/// One content unit: an independently addressable piece of the publication, in
/// reading order. ADR-0002 calls this the **identity domain** — a shard is a
/// scheduling decision and must never appear in a position.
public struct DocumentUnit: Sendable {
    /// Stable within the publication. For the spike it *is* the href, because
    /// the fixture has no better source of unit identity — and that choice is
    /// itself worth watching, since two units with the same href would collapse.
    public var id: String
    public var href: String
    public var mediaType: String
    public var canonical: CanonicalText

    public init(id: String, href: String, mediaType: String, canonical: CanonicalText) {
        self.id = id
        self.href = href
        self.mediaType = mediaType
        self.canonical = canonical
    }

    var length: Int { canonical.utf16Count }
}

public struct Document: Sendable {
    public var readingOrder: [DocumentUnit]

    public init(readingOrder: [DocumentUnit]) {
        self.readingOrder = readingOrder
    }

    /// Total canonical length across the reading order.
    public var totalLength: Int {
        readingOrder.reduce(0) { $0 + $1.length }
    }

    /// Looks a unit up the way Readium does — **normalised, not by raw
    /// equality**. `Manifest.linkWithHREF` (`Manifest.swift:137-157`) tries a
    /// normalised match first and then a query-and-fragment-stripped one, and a
    /// `Locator`'s own synthesised equality compares raw URLs. Getting this wrong
    /// is the difference between "the href did not resolve" and "the href
    /// resolved to the wrong resource".
    public func unit(withHref href: String) -> DocumentUnit? {
        readingOrder.first { Href.isEquivalent($0.href, href) }
    }

    public func unit(withID id: String) -> DocumentUnit? {
        readingOrder.first { $0.id == id }
    }

    // `progression(of:)` and `totalProgression(of:)` used to live here, and they
    // are gone on purpose. They were two unlabelled fractions over two different
    // denominators — the unit's length and the publication's — under names that
    // did not say which, and the bridge wrote one of them into a locator field
    // whose EPUB semantics are neither (see `LocationBridge.locator(from:in:)`).
    //
    // `progression` is now stated once, on `CanonicalTextIndexAxis`, where it
    // carries the metric it is a fraction of.
    //
    // The model the old comment recorded is still worth keeping, because it is
    // the reason a metric has to be named at all: Readium's `EPUBPositionsService`
    // derives positions from **byte** length (`pageLength = 1024`) and emits
    // `progression = (position - 1) / positionCount` (`EPUBPositionsService.swift:44-58`,
    // `:137-144`), while its navigator inverts with `ceil(progression * (count - 1))`
    // (`EPUBViewportAndLocationCalculator.swift:68`). Those are two indexings that
    // do not agree with each other, and neither is the text-length model this
    // spike uses. A bare `Double` cannot tell them apart.
}
