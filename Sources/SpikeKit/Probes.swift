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
    /// ran out of room" as "CoreText broke the line here". `canvasIsUnconstraining`
    /// is what keeps that distinction.
    public static let measurementCanvasHeight: CGFloat = 1_000_000

    /// How much of the canvas the content may occupy before the sweep stops
    /// trusting its own measurement.
    static let canvasHeadroom: CGFloat = 0.9

    /// True when the content stayed well clear of the canvas, so that line
    /// breaking reflects 禁則 rather than running out of room.
    static func canvasIsUnconstraining(contentHeight: Double) -> Bool {
        contentHeight < Double(measurementCanvasHeight * canvasHeadroom)
    }

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
        var taggedViolations = 0
        var untaggedViolations = 0
        var hardBreakLines = 0
        var inspectedLineEnds = 0
        var worstTaggedCase = ""
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
                hardBreakLines += violations.hardBreakLines
                inspectedLineEnds += violations.inspectedLineEnds

                if tag == nil {
                    untaggedViolations += violations.total
                } else {
                    taggedViolations += violations.total
                    if violations.total > 0 && worstTaggedCase.isEmpty {
                        worstTaggedCase = "at width \(Int(width))pt: \(violations.lineStartsWithProhibited) line-start, \(violations.lineEndsWithProhibited) line-end"
                    }
                }
            }
        }

        // Two ways this measurement can be vacuous, and both must be reported as
        // such rather than as a clean sweep: no line end was ever inspected (so
        // an end violation could not have been seen), or the content ran into the
        // canvas (so the breaks are about running out of room, not 禁則).
        let lineEndChecksBypassed = hardBreakLines > 0 && inspectedLineEnds == 0
        let canvasClamped = !canvasIsUnconstraining(contentHeight: contentHeight)
        let kinsokuInconclusive = lineEndChecksBypassed || canvasClamped
        probes.append(try ProbeOutcome(
            name: "kinsoku-language-tag",
            question: "Does kCTLanguageAttributeName actually buy 禁則処理?",
            execution: kinsokuInconclusive ? .inconclusive : .measured,
            finding: kinsokuInconclusive ? nil : (taggedViolations == 0 ? .yes : .no),
            detail: lineEndChecksBypassed
                ? "\(hardBreakLines) hard-broken lines but no line end was inspected — the line-end check was bypassed, so this probe cannot conclude"
                : (canvasClamped
                    ? "content height \(String(format: "%.1f", contentHeight))pt reached \(Int(canvasHeadroom * 100))% of the \(Int(measurementCanvasHeight))pt canvas — the layout may have been clamped, so this probe cannot conclude"
                    : (taggedViolations == 0
                        ? "no violations across \(sweepWidths.count) swept widths with the run tagged \"ja\"; untagged produced \(untaggedViolations); \(inspectedLineEnds) line ends inspected"
                        : "\(taggedViolations) violations remain with the run tagged \"ja\" (untagged produced \(untaggedViolations)); first case \(worstTaggedCase)")),
            numbers: [
                "taggedViolations": Double(taggedViolations),
                "untaggedViolations": Double(untaggedViolations),
                "sweptWidths": Double(sweepWidths.count),
                "hardBreakLines": Double(hardBreakLines),
                "inspectedLineEnds": Double(inspectedLineEnds),
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
        let (rubyReport, rubyFrame) = try TextLayout.layout(rubyInput)

        let plainHeight = (plainReport.lines.first.map { $0.ascent + $0.descent + $0.leading }) ?? 0
        let rubyHeight = (rubyReport.lines.first.map { $0.ascent + $0.descent + $0.leading }) ?? 0
        let heightDelta = rubyHeight - plainHeight

        // This probe measures a line box, so it only means anything if each run
        // produced exactly one line. A wrapped run would be measuring where the
        // line broke, not how tall it is.
        let singleLine = plainReport.lineCount == 1 && rubyReport.lineCount == 1
        probes.append(try ProbeOutcome(
            name: "ruby-line-height",
            question: "Does CoreText reserve line height for ruby, or must Nagi do it?",
            execution: singleLine ? .measured : .inconclusive,
            finding: singleLine ? (heightDelta > 0.5 ? .yes : .no) : nil,
            detail: !singleLine
                ? "the measurement wrapped (\(plainReport.lineCount) plain / \(rubyReport.lineCount) ruby lines) — line breaking is not the variable under test, so this probe cannot conclude"
                : (heightDelta > 0.5
                    ? "ruby at size factor \(rubySizeFactor) raised the line box by \(String(format: "%.3f", heightDelta))pt — CoreText accounts for it"
                    : "ruby at size factor \(rubySizeFactor) changed the line box by \(String(format: "%.3f", heightDelta))pt — CoreText does NOT reserve space; Nagi must compute annotationBeforeExtent itself (ADR-0005)"),
            numbers: [
                "plainLineHeight": plainHeight,
                "rubyLineHeight": rubyHeight,
                "delta": heightDelta,
                "plainLineCount": Double(plainReport.lineCount),
                "rubyLineCount": Double(rubyReport.lineCount),
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

        let rubyArtifact = ArtifactRecord(byteCount: try Renderer.writePNG(
            frame: rubyFrame ?? try requireFrame(rubyInput),
            size: CGSize(width: 400, height: 120),
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
