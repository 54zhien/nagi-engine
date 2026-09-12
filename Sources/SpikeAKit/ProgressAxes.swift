import Foundation

/// FB2, and anything else whose axis is the canonical primary text stream.
///
/// This absorbs `Document.progression(of:)` and `Document.totalProgression(of:)`
/// and takes them off `Document`. Both were unlabelled helpers that divided by a
/// length without saying which length — the older one by the unit's, the newer
/// one by the publication's, under names that did not distinguish them. That is
/// how two different numbers came to occupy one field.
public struct CanonicalTextIndexAxis: ProgressMetricAxis {
    public let metric: PublicationProgressMetric = .canonicalTextIndex

    /// Half a UTF-16 unit. The coordinate is an integer offset, so a seek that
    /// rounds to the nearest unit is within 0.5 of the position it answers for.
    public var seekTolerance: Double { 0.5 }

    private let units: [DocumentUnit]
    /// Prefix sums of the unit lengths. `units.count + 1` entries, so that the
    /// end of the last unit is expressible.
    private let starts: [Int]
    private let total: Int

    public init(document: Document) {
        var starts: [Int] = []
        var running = 0
        for unit in document.readingOrder {
            starts.append(running)
            running += unit.length
        }
        starts.append(running)
        self.units = document.readingOrder
        self.starts = starts
        self.total = running
    }

    public var readingOrderLength: Int { total }

    /// The publication-wide UTF-16 offset.
    ///
    /// **An empty unit is well defined here**, which is the point: its position
    /// is the boundary between its neighbours, and `progression` divides that
    /// boundary by the publication's length like any other coordinate. The
    /// helper this replaces guarded on `unit.length > 0` and returned nil, so a
    /// position inside an empty unit silently vanished from every sweep.
    public func coordinate(of position: NativePosition) -> Double? {
        guard let index = units.firstIndex(where: { $0.id == position.unitID }) else { return nil }
        let length = units[index].length
        guard position.utf16Offset >= 0, position.utf16Offset <= length else { return nil }
        return Double(starts[index] + position.utf16Offset)
    }

    public func progression(of position: NativePosition) -> Progression? {
        guard total > 0, let coordinate = coordinate(of: position) else { return nil }
        return Progression(value: coordinate / Double(total), metric: metric)
    }

    public func position(near progression: Double) -> NativePosition? {
        guard total > 0, progression.isFinite, progression >= 0, progression <= 1 else { return nil }
        let target = min(max(Int((progression * Double(total)).rounded()), 0), total)
        guard let index = unitIndex(covering: target) else { return nil }
        return position(inUnitAt: index, localOffset: target - starts[index])
    }

    /// The **first** unit whose span contains the target. Where units abut — and
    /// an empty unit makes two of them abut exactly — the earlier one wins, so a
    /// boundary reads as the end of what precedes it. Either answer names the
    /// same coordinate, which is what the round trip is checked against.
    private func unitIndex(covering target: Int) -> Int? {
        for index in 0..<units.count where target >= starts[index] && target <= starts[index + 1] {
            return index
        }
        return nil
    }

    private func position(inUnitAt index: Int, localOffset: Int) -> NativePosition {
        let unit = units[index]
        let nodeID: NodeID
        if let element = unit.canonical.innermostElement(containing: localOffset) {
            nodeID = element.explicitID.map { NodeID.explicitID($0) } ?? .path(element.path)
        } else if let last = unit.canonical.elements.last {
            nodeID = last.explicitID.map { NodeID.explicitID($0) } ?? .path(last.path)
        } else {
            nodeID = .path([])
        }
        return NativePosition(unitID: unit.id, nodeID: nodeID, utf16Offset: localOffset)
    }
}

/// TXT, and anywhere the source bytes are the axis.
///
/// The coordinate is a byte offset, and `coordinate(of:)` **can return an offset
/// that is not in `legalBoundaries`** — the `\n` of a CRLF is a real text unit
/// sitting between the two bytes of one line break. Reporting it honestly is
/// what leaves the snapping where it belongs, in `position(near:)`, and it is
/// what stops the seek probe from being true by construction.
public struct SourceBytesAxis: ProgressMetricAxis {
    public let metric: PublicationProgressMetric = .sourceBytes

    /// **A property of the metric, not of this fixture.**
    ///
    /// In UTF-8 a four-byte scalar carries three continuation bytes, so no byte
    /// offset is ever more than three bytes past a legal boundary — for any
    /// resource whatsoever. This fixture's longest illegal run is two, and the
    /// probe reports both numbers rather than quietly declaring the smaller one.
    public let seekTolerance: Double = 3

    private let resource: ByteResource

    public init(resource: ByteResource) {
        self.resource = resource
    }

    public func coordinate(of position: NativePosition) -> Double? {
        guard position.unitID == resource.href else { return nil }
        guard let byte = resource.byteOffset(forUTF16: position.utf16Offset) else { return nil }
        return Double(byte)
    }

    public func progression(of position: NativePosition) -> Progression? {
        guard resource.byteCount > 0, let coordinate = coordinate(of: position) else { return nil }
        return Progression(value: coordinate / Double(resource.byteCount), metric: metric)
    }

    public func position(near progression: Double) -> NativePosition? {
        guard resource.byteCount > 0, progression.isFinite, progression >= 0, progression <= 1 else {
            return nil
        }
        // Rounding recovers the byte the fraction names; the fraction arrived as
        // `byte / byteCount`, so the product is within a few ulps of an integer
        // and truncation would be the fragile choice. The **snap** that follows
        // is the part with a direction, and it goes down.
        let requested = Int((progression * Double(resource.byteCount)).rounded())
        guard let boundary = resource.legalBoundaries.last(where: { $0 <= requested }) else { return nil }
        return resource.position(atByte: boundary)
    }
}

/// PDF / CBZ / CBR — a container that declares its own pagination.
///
/// # The page-centre convention
///
/// `progression(of:)` puts a position at `(ordinal + 0.5) / pageCount`, the
/// **centre** of its page, and that is chosen for falsifiability rather than for
/// taste. Under `ordinal / pageCount` the inverse is the same whether it floors
/// or rounds, so an implementation that rounded to the nearest page boundary
/// would pass every round trip and the probe would be decoration. Under the
/// centre, `floor(k + 0.5) = k` while `round(k + 0.5) = k + 1`, and with
/// `seekTolerance` declared as zero **not flooring is a `no`**.
///
/// The exactness of `(k + 0.5) / N × N` depends on `N` being a power of two, so
/// the fixture only ever declares 2 or 4 pages. At `N = 6` the term for `k = 3`
/// lands on a half-ulp boundary and survives only by round-to-even; a property
/// that holds by luck is not one to build a measurement on.
///
/// The cost is that this metric's progressions reach only
/// `[0.5 / N, 1 - 0.5 / N]`, not the full `0.0...1.0` ADR-0009 says the UI sees.
/// That tension is real and belongs in the ADR, not hidden here.
public struct FixedPageOrdinalAxis: ProgressMetricAxis {
    public let metric: PublicationProgressMetric = .fixedPageOrdinal

    /// **Zero.** A fixed page has no finer coordinate — either the seek lands on
    /// the page the position is on, or the round trip failed. Any slack would let
    /// an implementation that rounds to the neighbouring boundary pass.
    public let seekTolerance: Double = 0

    private let resource: ByteResource

    public init(resource: ByteResource) {
        self.resource = resource
    }

    /// `nil` when the container declares no pagination — reflowable content.
    ///
    /// This is ADR-0008's admission criterion expressed as data rather than as a
    /// prohibition: the metric **refuses to answer** instead of inventing a page
    /// number, and the answer is `nil` rather than an error, because "this
    /// content has no page ordinals" is a fact about the content.
    private var pageRanges: [Range<Int>]? {
        guard let ranges = resource.pageRanges, !ranges.isEmpty else { return nil }
        return ranges
    }

    public func coordinate(of position: NativePosition) -> Double? {
        guard let ranges = pageRanges else { return nil }
        guard position.unitID == resource.href else { return nil }
        guard let byte = resource.byteOffset(forUTF16: position.utf16Offset) else { return nil }
        for (index, range) in ranges.enumerated() where byte >= range.lowerBound && byte < range.upperBound {
            return Double(index)
        }
        // The end of the text lies inside no page; it sits at the end of the last.
        if byte == resource.byteCount { return Double(ranges.count - 1) }
        return nil
    }

    public func progression(of position: NativePosition) -> Progression? {
        guard let ranges = pageRanges, let ordinal = coordinate(of: position) else { return nil }
        return Progression(value: (ordinal + 0.5) / Double(ranges.count), metric: metric)
    }

    public func position(near progression: Double) -> NativePosition? {
        guard let ranges = pageRanges else { return nil }
        guard progression.isFinite, progression >= 0, progression <= 1 else { return nil }
        // Floor, and the probe is built so that anything else fails. The clamp is
        // not a clamp of the *answer* — the axis rejects out-of-range fractions
        // above; it only keeps a fraction that is legitimately in `0...1` from
        // indexing past the last page.
        let index = min(max(Int((progression * Double(ranges.count)).rounded(.down)), 0), ranges.count - 1)
        return resource.position(atByte: ranges[index].lowerBound)
    }
}
