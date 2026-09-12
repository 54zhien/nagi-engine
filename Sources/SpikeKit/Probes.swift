import Foundation
import CoreText
import CoreGraphics

/// Runs the Spike B probes and assembles the report.
///
/// Every probe answers one question that an ADR deliberately left open, and
/// every probe is allowed to answer "inconclusive" — that is a real result.
public enum SpikeB {
    public static let identifier = "spike-b"

    public static let fontSize: CGFloat = 16
    public static let lineSpacing: CGFloat = 6
    public static let measureWidth: CGFloat = 320
    public static let pageHeight: CGFloat = 480

    /// The ruby size factor the ruby probe asks for. Travels into `LayoutInput`
    /// and back out into the report, so the number the report claims is the
    /// number the experiment used.
    public static let rubySizeFactor: CGFloat = 0.5

    /// The canvas the kinsoku sweep measures on — deliberately not called
    /// "unbounded", because it is not.
    ///
    /// A finite, quantizable number rather than `.greatestFiniteMagnitude`:
    /// scaling that by 1000 saturates to infinity, which the quantizer rejects as
    /// an anomalous metric rather than quietly writing out. A million points is
    /// ~13,000 inches.
    ///
    /// But a canvas that is merely very large is not the same as one that cannot
    /// constrain the layout, and confusing the two would mean reading "the text
    /// ran out of room" as "CoreText broke the line here". `Kinsoku.decide`
    /// applies that headroom rule.
    public static let measurementCanvasHeight: CGFloat = 1_000_000

    /// The width sweep for the kinsoku probe. Hand-placing a prohibited
    /// character at a line edge goes stale the moment the font changes; a sweep
    /// cannot go stale.
    static let sweepWidths: [CGFloat] = stride(from: 6.0, through: 20.0, by: 0.5)
        .map { CGFloat($0) * fontSize }

    /// - Parameter expectedFingerprint: the canonical fingerprint produced by an
    ///   earlier run, if there was one. Determinism is a cross-process property;
    ///   comparing two layouts inside one process cannot see hash seeding,
    ///   framework cold-start state, or environment-sensitive ordering.
    public static func run(
        outputDirectory: URL,
        expectedFingerprint: String? = nil
    ) throws -> SpikeReport {
        var probes: [ProbeOutcome] = []
        var layouts: [LayoutReport] = []

        guard
            let fontData = BundledFont.data(),
            let tables = FontTables.parse(fontData),
            let postScriptName = BundledFont.registerAndCopyPostScriptName()
        else {
            throw SpikeError.fontUnavailable
        }

        let font = CTFontCreateWithName(postScriptName as CFString, fontSize, nil)

        // ---- Font capability census -------------------------------------
        let availability = tables.featureAvailability
        let missingFeatures = availability.filter { !$0.value }.keys.sorted()
        probes.append(try ProbeOutcome(
            name: "font-feature-census",
            question: "Which OpenType features does the bundled font actually carry?",
            execution: .measured,
            finding: missingFeatures.isEmpty ? .yes : .no,
            detail: """
            sfnt \(tables.sfntVersion); vertical metrics \
            \(tables.hasVerticalMetrics ? "present" : "ABSENT"); \
            GSUB [\(tables.gsubFeatures.joined(separator: " "))]; \
            GPOS [\(tables.gposFeatures.joined(separator: " "))]; \
            missing \(missingFeatures.joined(separator: " "))
            """,
            numbers: [
                "featureCount": Double(tables.gsubFeatures.count + tables.gposFeatures.count),
                "missingFeatureCount": Double(missingFeatures.count)
            ]
        ))

        let coverage = FontCoverage.measure(font: font, characters: Fixture.coverageSample)
        probes.append(try ProbeOutcome(
            name: "glyph-coverage",
            question: "Does the font cover the corpus, or are we measuring .notdef boxes?",
            execution: .measured,
            finding: coverage.missingCharacters == 0 ? .yes : .no,
            detail: coverage.missingCharacters == 0
                ? "all \(coverage.testedCharacters) corpus characters present"
                : "missing \(coverage.missingCharacters)/\(coverage.testedCharacters): \(coverage.missingScalars.joined(separator: " "))",
            numbers: [
                "tested": Double(coverage.testedCharacters),
                "missing": Double(coverage.missingCharacters)
            ]
        ))

        // ---- Kinsoku: tagged vs untagged ---------------------------------
        // The untagged arm is a control, not decoration, so the two arms are
        // accumulated separately. The rule that reads them lives in
        // `Kinsoku.decide`, where it can be tested without a font.
        var tagged = Kinsoku.Violations(
            lineStartsWithProhibited: 0, lineEndsWithProhibited: 0,
            hardBreakLines: 0, inspectedLineEnds: 0
        )
        var untagged = tagged
        var contentHeight = 0.0

        for width in sweepWidths {
            for tag in [nil, "ja"] as [String?] {
                let input = LayoutInput(
                    text: Fixture.body,
                    font: font,
                    fontSize: fontSize,
                    measureWidth: width,
                    pageHeight: measurementCanvasHeight,
                    lineSpacing: lineSpacing,
                    languageTag: tag,
                    label: "kinsoku-\(tag ?? "untagged")"
                )
                let report = try TextLayout.layout(input).report
                contentHeight = max(contentHeight, report.totalTextHeight)
                let violations = Kinsoku.inspect(lines: report.lines, in: Fixture.body)
                if tag == nil {
                    untagged.add(violations)
                } else {
                    tagged.add(violations)
                }
            }
        }

        let kinsokuDecision = Kinsoku.decide(
            tagged: tagged,
            untagged: untagged,
            contentHeight: contentHeight,
            canvasHeight: Double(measurementCanvasHeight)
        )
        probes.append(try ProbeOutcome(
            name: "kinsoku-language-tag",
            question: "Does kCTLanguageAttributeName actually buy 禁則処理?",
            execution: kinsokuDecision.execution,
            finding: kinsokuDecision.finding,
            detail: kinsokuDecision.detail,
            numbers: [
                "taggedViolations": Double(tagged.total),
                "taggedLineStart": Double(tagged.lineStartsWithProhibited),
                "taggedLineEnd": Double(tagged.lineEndsWithProhibited),
                "untaggedViolations": Double(untagged.total),
                "untaggedLineStart": Double(untagged.lineStartsWithProhibited),
                "untaggedLineEnd": Double(untagged.lineEndsWithProhibited),
                "sweptWidths": Double(sweepWidths.count),
                "hardBreakLines": Double(tagged.hardBreakLines + untagged.hardBreakLines),
                "inspectedLineEnds": Double(tagged.inspectedLineEnds + untagged.inspectedLineEnds),
                "contentHeight": contentHeight,
                "canvasHeight": Double(measurementCanvasHeight)
            ]
        ))

        // ---- Ruby: does it contribute to line height? --------------------
        let rubyBaseText = Fixture.rubyContextPrefix + Fixture.rubyBase + Fixture.rubyContextSuffix
        let rubyRange = NSRange(
            location: Fixture.rubyContextPrefix.utf16.count,
            length: Fixture.rubyBase.utf16.count
        )
        let plainInput = LayoutInput(
            text: rubyBaseText, font: font, fontSize: fontSize,
            measureWidth: 10_000, pageHeight: 10_000, lineSpacing: 0,
            label: "ruby-off"
        )
        let rubyInput = LayoutInput(
            text: rubyBaseText, font: font, fontSize: fontSize,
            measureWidth: 10_000, pageHeight: 10_000, lineSpacing: 0,
            label: "ruby-on",
            ruby: (annotation: Fixture.rubyAnnotation, range: rubyRange),
            rubySizeFactor: rubySizeFactor
        )
        let (plainReport, _) = try TextLayout.layout(plainInput)
        let (rubyReport, _) = try TextLayout.layout(rubyInput)

        let plainHeight = (plainReport.lines.first.map { $0.ascent + $0.descent + $0.leading }) ?? 0
        let rubyHeight = (rubyReport.lines.first.map { $0.ascent + $0.descent + $0.leading }) ?? 0
        let heightDelta = rubyHeight - plainHeight

        // This probe measures a line box, so it only means anything if each run
        // produced exactly one line. A wrapped run would be measuring where the
        // line broke, not how tall it is.
        let singleLine = plainReport.lineCount == 1 && rubyReport.lineCount == 1

        // And it only means anything if the base text is renderable in the font
        // under test. `東京` contains 東, which this face has no glyph for, so the
        // metrics may come from a fallback face and cannot be attributed to the
        // bundled font. Checking it here rather than correcting the fixture keeps
        // the corpus change a deliberate act.
        let rubyBaseCoverage = FontCoverage.measure(
            font: font,
            characters: Array(Fixture.rubyBase)
        )
        let baseIsRenderable = rubyBaseCoverage.missingCharacters == 0
        let measurable = singleLine && baseIsRenderable

        probes.append(try ProbeOutcome(
            name: "ruby-line-height",
            question: "Does CoreText reserve line height for ruby, or must Nagi do it?",
            execution: measurable ? .measured : .inconclusive,
            finding: measurable ? (heightDelta > 0.5 ? .yes : .no) : nil,
            detail: !measurable
                ? (baseIsRenderable
                    ? "the measurement wrapped (\(plainReport.lineCount) plain / \(rubyReport.lineCount) ruby lines) — line breaking is not the variable under test, so this probe cannot conclude"
                    : "the ruby base \(Fixture.rubyBase) contains \(rubyBaseCoverage.missingCharacters) character(s) the bundled font does not cover (\(rubyBaseCoverage.missingScalars.joined(separator: " "))) — with font fallback the line metrics may come from a substituted face, so this probe cannot conclude")
                : (heightDelta > 0.5
                    ? "ruby at size factor \(rubySizeFactor) raised the line box by \(String(format: "%.3f", heightDelta))pt — CoreText accounts for it"
                    : "ruby at size factor \(rubySizeFactor) changed the line box by \(String(format: "%.3f", heightDelta))pt — CoreText does NOT reserve space; Nagi must compute annotationBeforeExtent itself (ADR-0005)"),
            numbers: [
                "plainLineHeight": plainHeight,
                "rubyLineHeight": rubyHeight,
                "delta": heightDelta,
                "plainLineCount": Double(plainReport.lineCount),
                "rubyLineCount": Double(rubyReport.lineCount),
                "rubyBaseMissingGlyphs": Double(rubyBaseCoverage.missingCharacters),
                // Reported so a future API misuse shows up here rather than
                // leaving every assertion green while the experiment changed.
                "requestedRubySizeFactor": Double(rubySizeFactor)
            ]
        ))

        layouts.append(plainReport)
        layouts.append(rubyReport)

        // ---- Vertical column flow ----------------------------------------
        let verticalInput = LayoutInput(
            text: Fixture.body,
            font: font,
            fontSize: fontSize,
            measureWidth: measureWidth,
            pageHeight: pageHeight,
            lineSpacing: lineSpacing,
            languageTag: "ja",
            label: "vertical-rl",
            writingMode: "vertical-rl",
            vertical: true
        )
        let chained = TextLayout.chainColumns(verticalInput, maxColumns: 400)
        // Stalling is an answer ("no, it does not chain"), not a failure of the
        // run. A single column is neither: nothing was chained, so there is no
        // conclusion to draw about chaining.
        let verticalOutcome: (execution: ProbeOutcome.Execution, finding: ProbeOutcome.Finding?)
        if !chained.terminated {
            verticalOutcome = (.measured, .no)
        } else if chained.columns > 1 {
            verticalOutcome = (.measured, .yes)
        } else {
            verticalOutcome = (.inconclusive, nil)
        }
        probes.append(try ProbeOutcome(
            name: "vertical-column-flow",
            question: "Does CTFrameProgression.rightToLeft + vertical forms chain columns without stalling?",
            execution: verticalOutcome.execution,
            finding: verticalOutcome.finding,
            detail: chained.terminated
                ? "consumed all \(chained.consumed) UTF-16 units in \(chained.columns) columns"
                : "stalled after \(chained.columns) columns, consuming \(chained.consumed) units",
            numbers: [
                "columns": Double(chained.columns),
                "consumed": Double(chained.consumed)
            ]
        ))

        let verticalArtifact = ArtifactRecord(byteCount: try Renderer.writePNG(
            frame: try requireFrame(verticalInput),
            size: CGSize(width: pageHeight, height: measureWidth),
            to: outputDirectory.appendingPathComponent("vertical-column-0.png")
        ))

        // ---- Artefacts and the canonical payload --------------------------
        let pageInput = LayoutInput(
            text: Fixture.body, font: font, fontSize: fontSize,
            measureWidth: measureWidth, pageHeight: pageHeight,
            lineSpacing: lineSpacing, languageTag: "ja", label: "page"
        )
        let pageReport = try TextLayout.layout(pageInput).report
        layouts.append(pageReport)

        let pageArtifact = ArtifactRecord(byteCount: try Renderer.writePNG(
            frame: try requireFrame(pageInput),
            size: CGSize(width: measureWidth, height: pageHeight),
            to: outputDirectory.appendingPathComponent("page-0.png")
        ))

        // The ruby MEASUREMENT box is 10,000pt so nothing wraps, but rendering
        // that frame would put the text 10,000pt above the bitmap — CoreText
        // draws the first line at the top of its path — and produce a blank
        // image. The review image gets a frame whose box IS the canvas.
        let rubyCanvas = CGSize(width: 400, height: 120)
        let rubyRenderInput = LayoutInput(
            text: rubyBaseText, font: font, fontSize: fontSize,
            measureWidth: rubyCanvas.width, pageHeight: rubyCanvas.height,
            lineSpacing: 0, label: "ruby-render",
            ruby: (annotation: Fixture.rubyAnnotation, range: rubyRange),
            rubySizeFactor: rubySizeFactor
        )
        let rubyArtifact = ArtifactRecord(byteCount: try Renderer.writePNG(
            frame: try requireFrame(rubyRenderInput),
            size: rubyCanvas,
            to: outputDirectory.appendingPathComponent("ruby.png")
        ))

        var report = SpikeReport(
            spike: identifier,
            fixtureName: Fixture.name,
            canonicalTextSHA256: SHA256.hex(Fixture.body),
            canonicalTextUTF16Length: Fixture.body.utf16.count,
            fontPostScriptName: postScriptName,
            fontSHA256: SHA256.hex(fontData),
            fontFeatureSummary: [
                "sfnt=\(tables.sfntVersion)",
                "verticalMetrics=\(tables.hasVerticalMetrics)",
                "GSUB=[\(tables.gsubFeatures.joined(separator: " "))]",
                "GPOS=[\(tables.gposFeatures.joined(separator: " "))]"
            ],
            glyphCoverage: coverage,
            probes: probes,
            layouts: layouts,
            artifacts: ArtifactManifest(
                pagePNG: pageArtifact,
                verticalColumnPNG: verticalArtifact,
                rubyPNG: rubyArtifact
            ),
            determinism: DeterminismRecord(
                fingerprint: "",
                expectedFingerprint: expectedFingerprint,
                execution: .inconclusive,
                finding: nil,
                detail: "not computed yet"
            )
        )

        // The fingerprint covers the canonical payload, which excludes
        // `determinism` by construction — so filling it in afterwards cannot
        // change the value it just computed.
        let fingerprint = try report.canonicalFingerprint()
        let (execution, finding, detail): (ProbeOutcome.Execution, ProbeOutcome.Finding?, String)
        if let expectedFingerprint {
            if expectedFingerprint == fingerprint {
                execution = .measured
                finding = .yes
                detail = "fingerprint matches the supplied run (\(fingerprint.prefix(12))…)"
            } else {
                execution = .measured
                finding = .no
                detail = "fingerprint \(fingerprint.prefix(12))… does not match the supplied \(expectedFingerprint.prefix(12))… — metrics are not stable across processes"
            }
        } else {
            execution = .inconclusive
            finding = nil
            detail = "no previous fingerprint supplied; run twice and pass --expect <dir>/\(identifier).fingerprint to compare across processes"
        }
        report.determinism = DeterminismRecord(
            fingerprint: fingerprint,
            expectedFingerprint: expectedFingerprint,
            execution: execution,
            finding: finding,
            detail: detail
        )
        return report
    }

    /// Frames are built by `TextLayout.makeFrame`, which returns nil only if
    /// CoreText refuses to build a frame at all. Rendering nothing and calling it
    /// a review artifact is worse than failing.
    private static func requireFrame(_ input: LayoutInput) throws -> CTFrame {
        guard let frame = TextLayout.makeFrame(
            attributed: TextLayout.attributedString(input),
            input: input
        ) else {
            throw SpikeError.renderingFailed("CoreText produced no frame for \(input.label)")
        }
        return frame
    }
}

public enum SpikeError: Error, CustomStringConvertible {
    case fontUnavailable
    case renderingFailed(String)
    case inconsistentProbeOutcome(name: String, execution: ProbeOutcome.Execution, hasFinding: Bool)

    public var description: String {
        switch self {
        case .fontUnavailable:
            return "bundled font missing or unparseable — check Sources/SpikeKit/Resources/"
        case .renderingFailed(let reason):
            return "PNG rendering failed: \(reason)"
        case .inconsistentProbeOutcome(let name, let execution, let hasFinding):
            return "probe \(name) is \(execution.rawValue) but \(hasFinding ? "carries" : "carries no") finding — a measurement and its conclusion must agree"
        }
    }
}
