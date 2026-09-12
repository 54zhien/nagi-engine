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

    /// **This spike's progression model, not Readium's.**
    ///
    /// Readium's `EPUBPositionsService` derives positions from *byte* length
    /// (`pageLength = 1024`) and emits `progression = (position - 1) / positionCount`
    /// (`EPUBPositionsService.swift:44-58`, `:137-144`), while its navigator
    /// inverts with `ceil(progression * (count - 1))`
    /// (`EPUBViewportAndLocationCalculator.swift:68`) — two indexings that do not
    /// agree with each other. Neither can be run here.
    ///
    /// What this does instead is the simplest thing that is self-consistent:
    /// progression is a fraction of the unit's canonical *text* length, and
    /// `totalProgression` is a fraction of the whole publication's. It is stated
    /// as a model so that a later reader cannot mistake it for a measurement.
    public func progression(of position: NativePosition) -> Double? {
        guard let unit = unit(withID: position.unitID), unit.length > 0 else { return nil }
        return Double(position.utf16Offset) / Double(unit.length)
    }

    public func totalProgression(of position: NativePosition) -> Double? {
        guard totalLength > 0,
              let index = readingOrder.firstIndex(where: { $0.id == position.unitID })
        else { return nil }
        let before = readingOrder[..<index].reduce(0) { $0 + $1.length }
        return Double(before + position.utf16Offset) / Double(totalLength)
    }
}
