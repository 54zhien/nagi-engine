import Foundation
import CoreGraphics
import CryptoKit

/// Deterministic report types.
///
/// Three rules govern everything in this file, all from ADR-0011:
///
///  1. Every floating point value is quantized — and quantization happens in the
///     initializer, so a raw value can never reach the artifact.
///  2. A metric that is not a finite number is an error, not a value. The spike
///     exists to surface anomalies; clamping one into the report would let a
///     broken measurement produce a report that looks legitimate.
///  3. No timestamps, no run identifiers, no host names, no output paths. What a
///     golden gate compares is `canonicalPayload()`; everything ambient stays
///     outside it.
public enum Quantize {
    /// ADR-0011's "about three decimal places".
    public static let digits = 3
    public static let scale: Double = 1000

    /// Rounds to the report's precision, or throws.
    public static func value(_ x: Double) throws -> Double {
        guard x.isFinite else { throw QuantizeError.nonFiniteMetric(x) }
        let scaled = x * scale
        // A finite value can still overflow the scaling. Catching it here keeps
        // the failure at the measurement that caused it rather than at the
        // encoder, where it would surface as an opaque JSON write error.
        guard scaled.isFinite else { throw QuantizeError.metricOverflow(x) }
        return scaled.rounded() / scale
    }

    public static func value(_ x: CGFloat) throws -> Double {
        try value(Double(x))
    }
}

public enum QuantizeError: Error, CustomStringConvertible {
    case nonFiniteMetric(Double)
    case metricOverflow(Double)

    public var description: String {
        switch self {
        case .nonFiniteMetric(let value):
            return "metric is not finite (\(value)) — a probe measured nothing usable"
        case .metricOverflow(let value):
            return "metric \(value) overflows quantization — the report cannot represent it"
        }
    }
}

/// The outcome of one probe.
///
/// Two axes, deliberately not one. "Did the probe manage to measure?" and "what
/// did the measurement say?" are different questions, and collapsing them into a
/// single pass/fail is how a CI log ends up unable to tell "the bundled font has
/// no `halt`" — a finding about the font, and the entire reason this probe
/// exists — apart from "the code broke".
///
/// A code failure never arrives here: it throws, and the process exits non-zero
/// without writing a report. So every outcome in a written report is about the
/// subject under test.
public struct ProbeOutcome: Codable, Sendable {
    public enum Execution: String, Codable, Sendable {
        /// The probe ran and produced a usable measurement.
        case measured
        /// The probe ran but cannot conclude: the measurement would be vacuous
        /// (the font lacks the feature being tested, the canvas clamped the
        /// layout, no line end was ever inspected).
        case inconclusive
        /// The API or feature is not available on this platform/OS version.
        case unsupported
    }

    public enum Finding: String, Codable, Sendable {
        /// The answer to the probe's question is yes.
        case yes
        /// The answer is no. A result about the subject, not a failure of the run.
        case no
    }

    public var name: String
    public var question: String
    public var execution: Execution
    /// Present exactly when `execution == .measured` — enforced in the
    /// initializer, because a finding without a measurement, or a measurement
    /// with no conclusion, would each be a silent lie in the artifact.
    public var finding: Finding?
    /// Human-readable evidence. This string is part of the artifact, so it must
    /// be deterministic too.
    public var detail: String
    /// Optional machine-readable numbers backing the finding, already quantized.
    public var numbers: [String: Double]

    public init(
        name: String,
        question: String,
        execution: Execution,
        finding: Finding? = nil,
        detail: String,
        numbers: [String: Double] = [:]
    ) throws {
        guard (execution == .measured) == (finding != nil) else {
            throw SpikeError.inconsistentProbeOutcome(
                name: name,
                execution: execution,
                hasFinding: finding != nil
            )
        }
        self.name = name
        self.question = question
        self.execution = execution
        self.finding = finding
        self.detail = detail
        var quantized: [String: Double] = [:]
        for (key, value) in numbers {
            quantized[key] = try Quantize.value(value)
        }
        self.numbers = quantized
    }
}

/// One laid-out line.
///
/// Two ranges, because a line consumes more than it displays:
///
///   - `utf16Start`/`utf16Length` is what the typesetter consumed. It includes
///     any trailing mandatory break control, so it is what advances the cursor —
///     and only that.
///   - `contentStart`/`contentLength` is the line's actual content: the consumed
///     range minus trailing break controls. 禁則検査 measures against this one,
///     and so will Native Position ranges.
///
/// Comparing the two is what makes a bypassed line-end check visible: a line
/// whose consumed range is longer than its content range carried a hard break,
/// and if no line end is ever inspected the report says so instead of reporting
/// a clean sweep. Offsets index the canonical primary text stream (ADR-0005) —
/// never the rendered string, and never a page.
public struct LineRecord: Codable, Sendable {
    public var index: Int
    public var utf16Start: Int
    public var utf16Length: Int
    public var contentStart: Int
    public var contentLength: Int
    public var originX: Double
    public var originY: Double
    public var width: Double
    public var ascent: Double
    public var descent: Double
    public var leading: Double

    public init(
        index: Int,
        utf16Start: Int,
        utf16Length: Int,
        contentStart: Int,
        contentLength: Int,
        originX: Double,
        originY: Double,
        width: Double,
        ascent: Double,
        descent: Double,
        leading: Double
    ) throws {
        self.index = index
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
        self.contentStart = contentStart
        self.contentLength = contentLength
        self.originX = try Quantize.value(originX)
        self.originY = try Quantize.value(originY)
        self.width = try Quantize.value(width)
        self.ascent = try Quantize.value(ascent)
        self.descent = try Quantize.value(descent)
        self.leading = try Quantize.value(leading)
    }
}

/// A page expressed purely as a range of lines over the canonical text.
/// Deliberately contains no pixels — see ADR-0008.
///
/// The range is the *consumed* span, not the content span: a page legitimately
/// contains the break that terminates its last line.
public struct PageRecord: Codable, Sendable {
    public var index: Int
    public var firstLine: Int
    public var lineCount: Int
    public var utf16Start: Int
    public var utf16Length: Int

    public init(index: Int, firstLine: Int, lineCount: Int, utf16Start: Int, utf16Length: Int) {
        self.index = index
        self.firstLine = firstLine
        self.lineCount = lineCount
        self.utf16Start = utf16Start
        self.utf16Length = utf16Length
    }
}

/// A layout produced under one fixed condition set.
public struct LayoutReport: Codable, Sendable {
    public var label: String
    public var writingMode: String
    public var languageTag: String?
    public var measureWidth: Double
    public var pageHeight: Double
    public var fontSize: Double
    public var lineSpacing: Double
    public var lineCount: Int
    public var pageCount: Int
    public var lines: [LineRecord]
    public var pages: [PageRecord]
    /// Total advance width of the canonical text on a single unbounded line.
    /// Changes here mean shaping changed — a font, feature, or OS difference.
    public var singleLineWidth: Double
    /// Sum of every line's ascent+descent, i.e. the height the text wants.
    public var totalTextHeight: Double

    public init(
        label: String,
        writingMode: String,
        languageTag: String?,
        measureWidth: Double,
        pageHeight: Double,
        fontSize: Double,
        lineSpacing: Double,
        lineCount: Int,
        pageCount: Int,
        lines: [LineRecord],
        pages: [PageRecord],
        singleLineWidth: Double,
        totalTextHeight: Double
    ) throws {
        self.label = label
        self.writingMode = writingMode
        self.languageTag = languageTag
        self.lineCount = lineCount
        self.pageCount = pageCount
        self.lines = lines
        self.pages = pages
        // The six measured fields, through the same quantizer as everything
        // else. `singleLineWidth` and `totalTextHeight` are the two that carry
        // real shaping noise and are the most likely to drift between runs.
        self.measureWidth = try Quantize.value(measureWidth)
        self.pageHeight = try Quantize.value(pageHeight)
        self.fontSize = try Quantize.value(fontSize)
        self.lineSpacing = try Quantize.value(lineSpacing)
        self.singleLineWidth = try Quantize.value(singleLineWidth)
        self.totalTextHeight = try Quantize.value(totalTextHeight)
    }
}

public struct GlyphCoverage: Codable, Sendable {
    public var testedCharacters: Int
    public var missingCharacters: Int
    /// Sorted, deduplicated hex scalar values — not the characters themselves,
    /// so the report stays readable and diffable.
    public var missingScalars: [String]

    public init(testedCharacters: Int, missingScalars: [UInt32]) {
        // Deduplicated, so the two fields describe the same set. They could
        // disagree: `FontCoverage.measure` appends one entry per `Character`, and
        // two distinct characters can share a first scalar (base + combining
        // mark). No pair in the current corpus does, which is exactly why this
        // would have gone unnoticed until a corpus that does.
        let unique = Set(missingScalars).sorted()
        self.testedCharacters = testedCharacters
        self.missingCharacters = unique.count
        self.missingScalars = unique.map { String(format: "U+%04X", $0) }
    }
}

/// What the renderer actually put on disk.
///
/// Recorded so that three independent things can be cross-checked: the JSON, the
/// CI log and the filesystem. A review image that silently failed to appear used
/// to be indistinguishable from a successful run.
public struct ArtifactRecord: Codable, Sendable {
    public var written: Bool
    public var byteCount: Int

    public init(byteCount: Int) {
        self.written = true
        self.byteCount = byteCount
    }
}

public struct ArtifactManifest: Codable, Sendable {
    public var pagePNG: ArtifactRecord
    public var verticalColumnPNG: ArtifactRecord
    public var rubyPNG: ArtifactRecord

    public init(pagePNG: ArtifactRecord, verticalColumnPNG: ArtifactRecord, rubyPNG: ArtifactRecord) {
        self.pagePNG = pagePNG
        self.verticalColumnPNG = verticalColumnPNG
        self.rubyPNG = rubyPNG
    }
}

/// The cross-process determinism result.
///
/// Deliberately NOT a member of `probes`: the fingerprint is taken over the
/// probe results, so a probe that contained its own comparison would make the
/// payload depend on the answer. Keeping it beside the report rather than inside
/// the fingerprinted payload is what removes the circularity.
public struct DeterminismRecord: Codable, Sendable {
    /// SHA-256 over this run's canonical payload.
    public var fingerprint: String
    /// The fingerprint handed in from a previous run, if one was supplied.
    public var expectedFingerprint: String?
    public var execution: ProbeOutcome.Execution
    public var finding: ProbeOutcome.Finding?
    public var detail: String

    /// Public because a second spike target reuses this type, and the
    /// synthesised memberwise initialiser is internal to `SpikeKit`. Purely
    /// additive: nothing Spike B does changes.
    public init(
        fingerprint: String,
        expectedFingerprint: String?,
        execution: ProbeOutcome.Execution,
        finding: ProbeOutcome.Finding?,
        detail: String
    ) {
        self.fingerprint = fingerprint
        self.expectedFingerprint = expectedFingerprint
        self.execution = execution
        self.finding = finding
        self.detail = detail
    }
}

/// The whole artifact. Compared by the golden gate.
public struct SpikeReport: Codable, Sendable {
    public var spike: String
    public var fixtureName: String
    public var canonicalTextSHA256: String
    public var canonicalTextUTF16Length: Int
    public var fontPostScriptName: String
    public var fontSHA256: String
    public var fontFeatureSummary: [String]
    public var glyphCoverage: GlyphCoverage
    public var probes: [ProbeOutcome]
    public var layouts: [LayoutReport]
    public var artifacts: ArtifactManifest
    public var determinism: DeterminismRecord

    public init(
        spike: String,
        fixtureName: String,
        canonicalTextSHA256: String,
        canonicalTextUTF16Length: Int,
        fontPostScriptName: String,
        fontSHA256: String,
        fontFeatureSummary: [String],
        glyphCoverage: GlyphCoverage,
        probes: [ProbeOutcome],
        layouts: [LayoutReport],
        artifacts: ArtifactManifest,
        determinism: DeterminismRecord
    ) {
        self.spike = spike
        self.fixtureName = fixtureName
        self.canonicalTextSHA256 = canonicalTextSHA256
        self.canonicalTextUTF16Length = canonicalTextUTF16Length
        self.fontPostScriptName = fontPostScriptName
        self.fontSHA256 = fontSHA256
        self.fontFeatureSummary = fontFeatureSummary
        self.glyphCoverage = glyphCoverage
        self.probes = probes
        self.layouts = layouts
        self.artifacts = artifacts
        self.determinism = determinism
    }

    /// The part a golden gate may compare: every measurement, and nothing
    /// ambient. Artifact byte counts and the determinism record stay out — a PNG
    /// encoding change must not be able to fail a metric gate (ADR-0011), and a
    /// self-referential comparison must not be inside the thing it compares.
    public func canonicalPayload() -> CanonicalPayload {
        CanonicalPayload(
            spike: spike,
            fixtureName: fixtureName,
            canonicalTextSHA256: canonicalTextSHA256,
            canonicalTextUTF16Length: canonicalTextUTF16Length,
            fontPostScriptName: fontPostScriptName,
            fontSHA256: fontSHA256,
            fontFeatureSummary: fontFeatureSummary,
            glyphCoverage: glyphCoverage,
            probes: probes,
            layouts: layouts
        )
    }

    public func canonicalFingerprint() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hex(try encoder.encode(canonicalPayload()))
    }
}

public struct CanonicalPayload: Codable, Sendable {
    public var spike: String
    public var fixtureName: String
    public var canonicalTextSHA256: String
    public var canonicalTextUTF16Length: Int
    public var fontPostScriptName: String
    public var fontSHA256: String
    public var fontFeatureSummary: [String]
    public var glyphCoverage: GlyphCoverage
    public var probes: [ProbeOutcome]
    public var layouts: [LayoutReport]
}

public enum ReportIO {
    public static func write(_ report: SpikeReport, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Sorted keys and pretty printing: a golden diff should be readable by a
        // human reviewer without a JSON tool.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: directory.appendingPathComponent("\(report.spike).json"))
    }

    /// The fingerprint on its own, so that comparing two runs is `cmp` and needs
    /// no JSON tooling.
    public static func writeFingerprint(_ fingerprint: String, for spike: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(spike).fingerprint")
        try Data("\(fingerprint)\n".utf8).write(to: url)
    }
}

public enum SHA256 {
    /// Pins the font and the canonical text so a report can never be silently
    /// compared against a different input.
    public static func hex(_ data: Data) -> String {
        digest(data)
    }

    public static func hex(_ string: String) -> String {
        hex(Data(string.utf8))
    }

    private static func digest(_ data: Data) -> String {
        CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
