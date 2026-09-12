import Foundation

/// ADR-0009's metric vocabulary, implemented for the first time.
///
/// The ADR has carried this enum as a design sketch since it was written and
/// nothing has ever declared it. Until now the only thing standing in for it was
/// a **string basis** — `LocationBridge`'s `"progression"` /
/// `"progression (clamped)"` — which names the channel a value came from but not
/// what the value is a fraction *of*.
///
/// That distinction is the whole finding: the same `0.5` means different places
/// under `readiumPositions` (archive entry bytes) and `canonicalTextIndex`
/// (UTF-16 units of the primary text stream). A number that does not carry its
/// metric does not identify a position.
public enum PublicationProgressMetric: Sendable, Hashable, Codable {
    /// EPUB, as Readium actually does it: a fraction of each resource's byte
    /// length taken from the ZIP central directory, without decompressing.
    case readiumPositions
    /// TXT. Bytes of the source, which for FB2 would be distorted by embedded
    /// base64 `<binary>` images — which is why the ADR does not unify on it.
    case sourceBytes
    /// FB2 and anything else whose canonical primary text stream is the axis.
    case canonicalTextIndex
    /// PDF / CBZ / CBR, where the container declares the pagination.
    case fixedPageOrdinal
    /// The escape hatch, and deliberately not implemented anywhere in this
    /// spike: a metric that is not one of the above has to bring its own
    /// arithmetic, and adding one has to be a visible act.
    case custom(String)
}

/// A progression that knows what it is a fraction of.
///
/// **`metric` is not optional, and that is the point.** Closing ADR-0009:73 —
/// "the metric is not written anywhere the UI can see" — needs the label to
/// travel with the number, so that the only way to obtain a bare `Double` is to
/// **drop the label on purpose**. That drop is exactly where the ADR says the
/// trouble is, so it has to be a visible act that the harness can record rather
/// than something that happens by default at every call site.
///
/// **`scope` completes ADR-0009's sealed conclusion** — `数值 + metric + scope +
/// provenance` — of which only the first two had reached the type. Two numbers
/// with the same value *and* the same metric name different places when their
/// scopes differ, and `locations.progression` against
/// `CanonicalTextIndexAxis.progression` is exactly that pair. Not two fields
/// that happen to differ: two coordinates that would be silently swapped.
public struct Progression: Sendable, Hashable, Codable {
    public var value: Double
    public var metric: PublicationProgressMetric
    public var scope: ProgressScope

    /// **`scope` has no default value, deliberately.** A default of
    /// `.publication` would compile at every call site, including the one place
    /// where it is wrong — `LocationBridge.locator(from:)` divides by
    /// `unit.length`, not by the publication's length — and the substitution it
    /// would permit is invisible: the number stays plausible, the census buckets
    /// still sum, and only the position is wrong.
    public init(value: Double, metric: PublicationProgressMetric, scope: ProgressScope) {
        self.value = value
        self.metric = metric
        self.scope = scope
    }
}

/// One format's answer to "where is this, as a fraction", with the arithmetic
/// that is specific to that format kept inside its own conformer.
///
/// **`coordinate` is first, and `seekTolerance` is in its unit.** ADR-0009
/// property 3 is a tolerance on a seek round trip, and a tolerance is only
/// meaningful against a unit. Progression space cannot supply one: `ProbeOutcome`
/// quantizes every number to three decimals (`SpikeKit/Report.swift`), so a
/// 1e-9 discrepancy measured in progression space would be written out as `0.0`
/// and would **manufacture exactness**. Every comparison in this spike is made
/// in the metric's own unit — bytes, pages, UTF-16 units.
///
/// **The subject is captured at construction, not passed per call.** Two of the
/// three axes below do not consult a `Document` at all, and a parameter that two
/// out of three conformers ignore is a seam in the wrong place.
public protocol ProgressMetricAxis: Sendable {
    var metric: PublicationProgressMetric { get }

    /// ADR-0009 property 3, in the metric's own unit. Declared by the metric,
    /// never chosen by a probe — a probe that picked its own tolerance could
    /// always pick one it passes.
    var seekTolerance: Double { get }

    /// The position in the metric's own unit, publication-wide. Nil when the
    /// position does not name a place on this axis; the axis does not clamp it
    /// into range, because a coordinate the publication never stated is not a
    /// coordinate.
    func coordinate(of position: NativePosition) -> Double?

    /// The same place as a fraction, carrying the metric it is a fraction of.
    func progression(of position: NativePosition) -> Progression?

    /// The navigation direction ADR-0009 keeps separate from exact recovery:
    /// a bare `0.0...1.0` arrives from a progress bar, which knows nothing about
    /// metrics, and the axis answers with a nearby position.
    func position(near progression: Double) -> NativePosition?
}

/// ADR-0009's service, with the one contract change this round's measurements
/// force.
///
/// The ADR's protocol is written against `NativeDocumentPosition`, which does not
/// exist; `NativePosition` is the same thing under the name ADR-0004 gives it.
/// What changes is the failure mode: an **outside position throws rather than
/// clamps**. Clamping would invent a coordinate the publication never stated and
/// hand it back looking exactly like a real one — the same defect as an offset
/// recomputed from a fraction and reported as carried.
///
/// Generic rather than `any ProgressMetricAxis` on purpose: this package is
/// written without a local Swift toolchain, and whether an existential of a
/// `Sendable`-inheriting protocol is itself `Sendable` is not something to bet a
/// CI run on. The generic form is also statically dispatched.
///
/// **No registry, no stubs.** Which axis applies to a document is the caller's
/// decision this round; a registry of five implementations would be four empty
/// ones.
public struct PublicationProgressService<Axis: ProgressMetricAxis>: Sendable {
    private let axis: Axis

    public init(axis: Axis) {
        self.axis = axis
    }

    public var metric: PublicationProgressMetric { axis.metric }

    public func progression(for position: NativePosition) throws -> Progression {
        guard let progression = axis.progression(of: position) else {
            throw ProgressError.positionOutsideTheAxis(position)
        }
        return progression
    }

    public func position(near progression: Double) throws -> NativePosition {
        guard let position = axis.position(near: progression) else {
            throw ProgressError.progressionOutsideTheAxis(progression)
        }
        return position
    }
}

public enum ProgressError: Error, CustomStringConvertible {
    case positionOutsideTheAxis(NativePosition)
    case progressionOutsideTheAxis(Double)

    public var description: String {
        switch self {
        case .positionOutsideTheAxis(let position):
            return "\(position.nodeID.described) at offset \(position.utf16Offset) names no place on this metric's axis — clamping it into range would hand back a coordinate the publication never stated"
        case .progressionOutsideTheAxis(let progression):
            return "progression \(progression) names no place on this metric's axis"
        }
    }
}
