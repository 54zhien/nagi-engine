import Foundation
import XCTest
@testable import SpikeKit

/// Guards ADR-0011: a report is a pure function of (fixture, font, viewport,
/// locale). No timestamps, no run identifiers, no host names — and every float
/// quantized, with a metric that is not a finite number treated as an error
/// rather than clamped into the artifact.
///
/// Quantization only means anything if it happens at the point a value enters the
/// report rather than at the point it is printed: a type whose initializer
/// quantizes enforces that, one whose formatter quantizes does not, because the
/// raw value is still in the JSON.
///
/// `@testable` is used here and nowhere else: constructing a `SpikeReport` to
/// exercise the write path needs its internal memberwise initializer, and adding
/// a 12-parameter public init to the module so a test could reach it would widen
/// the interface far past what any real caller needs.
final class ReportDeterminismTests: XCTestCase {

    // MARK: - Quantization

    func testQuantizeRoundsToThreeDigits() throws {
        XCTAssertEqual(Quantize.digits, 3)
        XCTAssertEqual(try Quantize.value(1.0004), 1.0, accuracy: 1e-12)
        XCTAssertEqual(try Quantize.value(1.0006), 1.001, accuracy: 1e-12)
        // Exactly on the half. Swift rounds half away from zero, which is why
        // this is 0.001 and not 0.0.
        XCTAssertEqual(try Quantize.value(0.0005), 0.001, accuracy: 1e-12)
        XCTAssertEqual(try Quantize.value(123.456789), 123.457, accuracy: 1e-12)
        XCTAssertEqual(try Quantize.value(-1.0006), -1.001, accuracy: 1e-12)
    }

    /// The whole point of the throwing contract: the spike exists to surface
    /// anomalies, so a broken measurement must not be able to produce a report
    /// that looks legitimate.
    func testQuantizeRejectsNonFiniteMetrics() {
        XCTAssertThrowsError(try Quantize.value(Double.nan))
        XCTAssertThrowsError(try Quantize.value(Double.infinity))
        XCTAssertThrowsError(try Quantize.value(-Double.infinity))
    }

    func testQuantizeNamesNonFiniteAsItsOwnFailure() {
        XCTAssertThrowsError(try Quantize.value(Double.nan)) { error in
            guard let quantizeError = error as? QuantizeError, case .nonFiniteMetric = quantizeError else {
                return XCTFail("expected nonFiniteMetric, got \(error)")
            }
        }
    }

    /// A finite value can still overflow the scaling. That is a distinct failure
    /// and must be reported as one, not as an infinity that reaches the encoder.
    func testQuantizeRejectsOverflowingMetrics() {
        XCTAssertThrowsError(try Quantize.value(Double.greatestFiniteMagnitude)) { error in
            guard let quantizeError = error as? QuantizeError, case .metricOverflow = quantizeError else {
                return XCTFail("expected metricOverflow, got \(error)")
            }
        }
    }

    /// Quantization happens in the initializer, so a raw value never reaches the
    /// encoder. This is the assertion that would fail if someone moved
    /// quantization into the report formatter.
    func testLineRecordQuantizesOnConstruction() throws {
        let record = try LineRecord(
            index: 0,
            utf16Start: 0,
            utf16Length: 1,
            contentStart: 0,
            contentLength: 1,
            originX: 1.00049,
            originY: 0,
            width: 2.00051,
            ascent: 3.00049,
            descent: 4.00049,
            leading: 5.00051
        )
        XCTAssertEqual(record.originX, 1.0, accuracy: 1e-12)
        XCTAssertEqual(record.width, 2.001, accuracy: 1e-12)
        XCTAssertEqual(record.ascent, 3.0, accuracy: 1e-12)
        XCTAssertEqual(record.descent, 4.0, accuracy: 1e-12)
        XCTAssertEqual(record.leading, 5.001, accuracy: 1e-12)
    }

    func testProbeNumbersQuantizeOnConstruction() throws {
        let outcome = try ProbeOutcome(
            name: "quantization",
            question: "does a raw double survive into the artifact?",
            execution: .measured,
            finding: .yes,
            detail: "",
            numbers: ["raw": 1.00049]
        )
        XCTAssertTrue(outcome.numbers["raw"] == 1.0, "raw double reached the report unquantized")
    }

    // MARK: - Probe outcome semantics

    /// The two axes are not independent: a conclusion only exists where a
    /// measurement does. Without this, a report could claim a finding it never
    /// measured, or measure something and silently report nothing.
    func testProbeOutcomeRejectsAFindingWithoutAMeasurement() {
        XCTAssertThrowsError(try ProbeOutcome(
            name: "inconsistent",
            question: "?",
            execution: .inconclusive,
            finding: .yes,
            detail: ""
        )) { error in
            guard let spikeError = error as? SpikeError,
                  case .inconsistentProbeOutcome = spikeError
            else { return XCTFail("expected inconsistentProbeOutcome, got \(error)") }
        }
    }

    func testProbeOutcomeRejectsAMeasurementWithoutAFinding() {
        XCTAssertThrowsError(try ProbeOutcome(
            name: "inconsistent",
            question: "?",
            execution: .measured,
            finding: nil,
            detail: ""
        )) { error in
            guard let spikeError = error as? SpikeError,
                  case .inconsistentProbeOutcome = spikeError
            else { return XCTFail("expected inconsistentProbeOutcome, got \(error)") }
        }
    }

    /// The vocabulary has no "failed run": a probe either measured something or
    /// it did not, and "the answer is no" is spelled `finding == .no`.
    func testFindingsAreNotExecutionStates() throws {
        let negative = try ProbeOutcome(
            name: "font-feature-census",
            question: "does the font carry halt?",
            execution: .measured,
            finding: .no,
            detail: "halt is absent"
        )
        XCTAssertEqual(negative.execution, .measured)
        XCTAssertEqual(negative.finding, .no)

        let undecided = try ProbeOutcome(
            name: "ruby-line-height",
            question: "does CoreText reserve ruby height?",
            execution: .inconclusive,
            detail: "the measurement wrapped"
        )
        XCTAssertEqual(undecided.execution, .inconclusive)
        XCTAssertNil(undecided.finding)
    }

    func testSizeQuantizesOnConstruction() throws {
        let size = try Size(width: 10.00049, height: 20.00051)
        XCTAssertEqual(size.width, 10.0, accuracy: 1e-12)
        XCTAssertEqual(size.height, 20.001, accuracy: 1e-12)
    }

    /// All six measured fields, through the same helper — none of them may
    /// format itself.
    func testLayoutReportQuantizesItsMeasuredFields() throws {
        let report = try LayoutReport(
            label: "unit",
            writingMode: "horizontal-tb",
            languageTag: nil,
            measureWidth: 100.00049,
            pageHeight: 200.00051,
            fontSize: 16.00049,
            lineSpacing: 6.00051,
            lineCount: 0,
            pageCount: 0,
            lines: [],
            pages: [],
            singleLineWidth: 1_234.56789,
            totalTextHeight: 5.00051
        )
        XCTAssertEqual(report.measureWidth, 100.0, accuracy: 1e-12)
        XCTAssertEqual(report.pageHeight, 200.001, accuracy: 1e-12)
        XCTAssertEqual(report.fontSize, 16.0, accuracy: 1e-12)
        XCTAssertEqual(report.lineSpacing, 6.001, accuracy: 1e-12)
        XCTAssertEqual(report.singleLineWidth, 1_234.568, accuracy: 1e-12)
        XCTAssertEqual(report.totalTextHeight, 5.001, accuracy: 1e-12)
    }

    func testLayoutReportRejectsAnUnrepresentableMetric() {
        XCTAssertThrowsError(try LayoutReport(
            label: "unit",
            writingMode: "horizontal-tb",
            languageTag: nil,
            measureWidth: 100,
            pageHeight: 200,
            fontSize: 16,
            lineSpacing: 6,
            lineCount: 0,
            pageCount: 0,
            lines: [],
            pages: [],
            singleLineWidth: .greatestFiniteMagnitude,
            totalTextHeight: 0
        ))
    }

    // MARK: - Glyph coverage

    func testGlyphCoverageFormatsScalarsAsSortedHex() {
        let coverage = GlyphCoverage(testedCharacters: 4, missingScalars: [0x4E2D, 0x41])
        XCTAssertEqual(coverage.testedCharacters, 4)
        XCTAssertEqual(coverage.missingCharacters, 2)
        XCTAssertEqual(coverage.missingScalars, ["U+0041", "U+4E2D"])
    }

    func testGlyphCoverageWithNoMissingGlyphs() {
        let coverage = GlyphCoverage(testedCharacters: 9, missingScalars: [])
        XCTAssertEqual(coverage.missingCharacters, 0)
        XCTAssertEqual(coverage.missingScalars, [])
    }

    // MARK: - Hashing

    /// Known-answer vectors. These are what make the pins in
    /// `PrimaryTextContractTests` and `FontTableTests` trustworthy: if the
    /// hashing itself were wrong, every pin would still agree with itself.
    func testSHA256MatchesPublishedVectors() {
        XCTAssertEqual(
            SHA256.hex(""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            SHA256.hex("abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    /// The String overload must hash the UTF-8 bytes of the string, not its
    /// UTF-16 units or its unicode scalars — the corpus pin depends on which.
    func testSHA256StringOverloadHashesUTF8Bytes() {
        XCTAssertEqual(SHA256.hex(""), SHA256.hex(Data()))
        XCTAssertEqual(SHA256.hex("abc"), SHA256.hex(Data("abc".utf8)))
        XCTAssertEqual(SHA256.hex("東京"), SHA256.hex(Data("東京".utf8)))
    }

    // MARK: - The canonical payload

    /// The gate compares the payload, not the artifact. Artifact byte counts are
    /// ambient: a PNG encoder change on a new OS must not be able to fail a
    /// metric gate (ADR-0011), and the determinism record cannot sit inside the
    /// thing it fingerprints.
    func testFingerprintIgnoresArtifactsAndTheDeterminismRecord() throws {
        var report = makeReport()
        let baseline = try report.canonicalFingerprint()

        report.artifacts = ArtifactManifest(
            pagePNG: ArtifactRecord(byteCount: 111_111),
            verticalColumnPNG: ArtifactRecord(byteCount: 222_222),
            rubyPNG: ArtifactRecord(byteCount: 333_333)
        )
        report.determinism = DeterminismRecord(
            fingerprint: baseline,
            expectedFingerprint: baseline,
            execution: .measured,
            finding: .yes,
            detail: "changed"
        )

        XCTAssertEqual(try report.canonicalFingerprint(), baseline)
    }

    /// Same payload, same fingerprint — that is what makes a cross-process
    /// comparison meaningful at all.
    func testFingerprintIsStableForTheSamePayload() throws {
        XCTAssertEqual(try makeReport().canonicalFingerprint(), try makeReport().canonicalFingerprint())
    }

    // MARK: - The artifact on disk

    /// The filename is a contract with the CI gate, which looks for exactly this
    /// file. `SpikeB` announces `spike-b.json` to the log; this is the assertion
    /// that keeps the announcement true.
    func testWriteUsesTheSpikeIdentifierAsFilename() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        // Deliberately nested and nonexistent: ADR-0011's CI writes into a fresh
        // artifact directory, so `write` has to create it.
        let output = root.appendingPathComponent("artifacts/run/1")
        try ReportIO.write(makeReport(), to: output)

        let url = output.appendingPathComponent("spike-b.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "expected spike-b.json")

        let reloaded = try JSONDecoder().decode(SpikeReport.self, from: try Data(contentsOf: url))
        XCTAssertEqual(reloaded.spike, "spike-b")
        XCTAssertEqual(reloaded.fixtureName, "unit-fixture")
    }

    /// `cmp` on two of these is the whole cross-process check, so the file has to
    /// hold the fingerprint and nothing else.
    func testWritesFingerprintSidecar() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try ReportIO.writeFingerprint("abc123", for: "spike-b", to: root)
        let url = root.appendingPathComponent("spike-b.fingerprint")

        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(contents.trimmingCharacters(in: .whitespacesAndNewlines), "abc123")
    }

    /// Same input, same bytes.
    func testWriteIsByteStable() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("spike-b.json")

        try ReportIO.write(makeReport(), to: root)
        let first = try Data(contentsOf: url)
        try ReportIO.write(makeReport(), to: root)
        let second = try Data(contentsOf: url)

        XCTAssertEqual(first, second)
    }

    /// ADR-0011 asks for sorted keys so that a golden diff is readable by a human
    /// reviewer without a JSON tool. Observed through the artifact rather than
    /// through the encoder, because the encoder is not what the reviewer reads.
    func testWriteSortsKeys() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ReportIO.write(makeReport(), to: root)

        let data = try Data(contentsOf: root.appendingPathComponent("spike-b.json"))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        let sha = try XCTUnwrap(json.range(of: "\"canonicalTextSHA256\""))
        let length = try XCTUnwrap(json.range(of: "\"canonicalTextUTF16Length\""))
        XCTAssertLessThan(sha.lowerBound, length.lowerBound, "keys are not in sorted order")

        XCTAssertTrue(json.contains("\n"), "report should be pretty-printed for review")
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spikekit-tests-\(UUID().uuidString)")
    }

    private func makeReport() -> SpikeReport {
        SpikeReport(
            spike: SpikeB.identifier,
            fixtureName: "unit-fixture",
            canonicalTextSHA256: SHA256.hex(""),
            canonicalTextUTF16Length: 0,
            fontPostScriptName: "Unit-Regular",
            fontSHA256: SHA256.hex(""),
            fontFeatureSummary: [],
            glyphCoverage: GlyphCoverage(testedCharacters: 0, missingScalars: []),
            probes: [],
            layouts: [],
            artifacts: ArtifactManifest(
                pagePNG: ArtifactRecord(byteCount: 0),
                verticalColumnPNG: ArtifactRecord(byteCount: 0),
                rubyPNG: ArtifactRecord(byteCount: 0)
            ),
            determinism: DeterminismRecord(
                fingerprint: "",
                expectedFingerprint: nil,
                execution: .inconclusive,
                finding: nil,
                detail: "unit"
            )
        )
    }
}
