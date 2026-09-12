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
    /// ran out of room" as "CoreText broke the line here". `Kinsoku.assess`
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
        // `Kinsoku.assess`, where it can be tested without a font.
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

        let kinsoku = Kinsoku.assess(
            tagged: tagged,
            untagged: untagged,
            contentHeight: contentHeight,
            canvasHeight: Double(measurementCanvasHeight)
        )

        // Two questions, two probes. A single probe answering both would have to
        // pick one verdict, and these two answers genuinely differ: the default
        // behaviour is a clean yes while the tag has no observable effect.
        probes.append(try ProbeOutcome(
            name: "kinsoku-baseline-behavior",
            question: "Does CoreText's default line breaking avoid the tested 禁則 violations?",
            execution: kinsoku.baseline.execution,
            finding: kinsoku.baseline.finding,
            detail: kinsoku.baseline.detail,
            numbers: [
                "untaggedViolations": Double(untagged.total),
                "untaggedLineStart": Double(untagged.lineStartsWithProhibited),
                "untaggedLineEnd": Double(untagged.lineEndsWithProhibited),
                "sweptWidths": Double(sweepWidths.count),
                "hardBreakLines": Double(untagged.hardBreakLines),
                "inspectedLineEnds": Double(untagged.inspectedLineEnds),
                "contentHeight": contentHeight,
                "canvasHeight": Double(measurementCanvasHeight)
            ]
        ))
        probes.append(try ProbeOutcome(
            name: "kinsoku-language-tag-effect",
            question: "Does kCTLanguageAttributeName change the observed line breaking?",
            execution: kinsoku.tagEffect.execution,
            finding: kinsoku.tagEffect.finding,
            detail: kinsoku.tagEffect.detail,
            numbers: [
                "taggedViolations": Double(tagged.total),
                "untaggedViolations": Double(untagged.total),
                "violationDelta": Double(tagged.total - untagged.total),
                "sweptWidths": Double(sweepWidths.count),
                "hardBreakLines": Double(tagged.hardBreakLines + untagged.hardBreakLines),
                "inspectedLineEnds": Double(tagged.inspectedLineEnds + untagged.inspectedLineEnds)
            ]
        ))

        // ---- Ruby: does it contribute to line height? --------------------
        //
        // Two fixture pairs, and the distance between them is the point. The
        // formal pair is fully covered by the bundled face, so nothing in its
        // measurement can come from a substitute. The diagnostic pair is the one
        // that taught us that a missing glyph does exactly that.
        let formal = try measureRuby(
            base: Fixture.rubyBase,
            annotation: Fixture.rubyAnnotation,
            labelPrefix: "ruby",
            font: font
        )
        let diagnostic = try measureRuby(
            base: Fixture.rubyFallbackDiagnosticBase,
            annotation: Fixture.rubyFallbackDiagnosticAnnotation,
            labelPrefix: "ruby-fallback",
            font: font
        )

        probes.append(try ProbeOutcome(
            name: "ruby-line-height",
            question: "Does CoreText reserve line height for ruby, or must Nagi do it?",
            execution: formal.soundnessFailure == nil ? .measured : .inconclusive,
            finding: formal.soundnessFailure == nil
                ? (formal.heightDelta > 0.5 ? .yes : .no)
                : nil,
            detail: formal.soundnessFailure
                ?? (formal.heightDelta > 0.5
                    ? "ruby at size factor \(rubySizeFactor) raised the line box by \(String(format: "%.3f", formal.heightDelta))pt — CoreText accounts for it"
                    : "ruby at size factor \(rubySizeFactor) changed the line box by \(String(format: "%.3f", formal.heightDelta))pt — CoreText does NOT reserve space; Nagi must compute annotationBeforeExtent itself (ADR-0005)"),
            numbers: [
                "plainLineHeight": formal.plainHeight,
                "rubyLineHeight": formal.rubyHeight,
                "delta": formal.heightDelta,
                "plainLineCount": Double(formal.plainReport.lineCount),
                "rubyLineCount": Double(formal.rubyReport.lineCount),
                "baseUsesRequestedFont": formal.baseUsesRequestedFont ? 1 : 0,
                "annotationUsesRequestedFont": formal.annotationUsesRequestedFont ? 1 : 0,
                // Reported so a future API misuse shows up here rather than
                // leaving every assertion green while the experiment changed.
                "requestedRubySizeFactor": Double(rubySizeFactor)
            ]
        ))
        probes.append(try ProbeOutcome(
            // Named for the phenomenon, not the outcome: it must read naturally
            // whichever way it comes back.
            name: "ruby-base-font-fallback",
            question: "Does the base text pull a substituted face into the ruby measurement?",
            execution: .measured,
            finding: diagnostic.baseUsesRequestedFont ? .no : .yes,
            detail: diagnostic.baseUsesRequestedFont
                ? "CoreText resolves \(diagnostic.base) to the bundled face — nothing to report"
                : "CoreText substitutes another face for \(diagnostic.base), and the line box still moved by \(String(format: "%.3f", diagnostic.heightDelta))pt — a metric measured this way belongs to a font nobody asked about. This is why the formal fixture is chosen from the glyph census rather than for how it reads.",
            numbers: [
                "plainLineHeight": diagnostic.plainHeight,
                "rubyLineHeight": diagnostic.rubyHeight,
                "delta": diagnostic.heightDelta,
                "baseUsesRequestedFont": diagnostic.baseUsesRequestedFont ? 1 : 0,
                "annotationUsesRequestedFont": diagnostic.annotationUsesRequestedFont ? 1 : 0
            ]
        ))

        // Only the formal pair feeds the layouts: the diagnostic's value is its
        // verdict and its numbers, not another two rows in the golden.
        layouts.append(formal.plainReport)
        layouts.append(formal.rubyReport)

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
            text: rubyText(Fixture.rubyBase), font: font, fontSize: fontSize,
            measureWidth: rubyCanvas.width, pageHeight: rubyCanvas.height,
            lineSpacing: 0, label: "ruby-render",
            ruby: (annotation: Fixture.rubyAnnotation, range: rubyRange(Fixture.rubyBase)),
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

    /// The ruby MEASUREMENT box is deliberately huge so that nothing wraps — a
    /// wrapped line measures where the line broke, not how tall it is. Rendering
    /// uses its own, much smaller box.
    static let rubyMeasurementExtent: CGFloat = 10_000

    static func rubyText(_ base: String) -> String {
        Fixture.rubyContextPrefix + base + Fixture.rubyContextSuffix
    }

    static func rubyRange(_ base: String) -> NSRange {
        NSRange(
            location: Fixture.rubyContextPrefix.utf16.count,
            length: base.utf16.count
        )
    }

    /// One ruby fixture pair, measured twice — once plain, once annotated.
    struct RubyMeasurement {
        var base: String
        var annotation: String
        var plainReport: LayoutReport
        var rubyReport: LayoutReport
        var plainHeight: Double
        var rubyHeight: Double
        var baseUsesRequestedFont: Bool
        var annotationUsesRequestedFont: Bool

        var heightDelta: Double { rubyHeight - plainHeight }

        /// Why this measurement may not be believed, or nil when it may. Every
        /// condition here is one that would let the numbers belong to something
        /// other than the fixture, the font and the line box under test.
        var soundnessFailure: String? {
            if plainReport.lineCount != 1 || rubyReport.lineCount != 1 {
                return "the measurement wrapped (\(plainReport.lineCount) plain / "
                    + "\(rubyReport.lineCount) ruby lines) — line breaking is not the "
                    + "variable under test"
            }
            if !baseUsesRequestedFont {
                return "CoreText substitutes another face for the base \(base) — the line "
                    + "metrics would not belong to the bundled font"
            }
            if !annotationUsesRequestedFont {
                return "CoreText substitutes another face for the annotation \(annotation) — "
                    + "same problem as the base"
            }
            return nil
        }
    }

    static func measureRuby(
        base: String,
        annotation: String,
        labelPrefix: String,
        font: CTFont
    ) throws -> RubyMeasurement {
        let text = rubyText(base)
        let range = rubyRange(base)

        let plainInput = LayoutInput(
            text: text, font: font, fontSize: fontSize,
            measureWidth: rubyMeasurementExtent,
            pageHeight: rubyMeasurementExtent,
            lineSpacing: 0,
            label: "\(labelPrefix)-off"
        )
        let rubyInput = LayoutInput(
            text: text, font: font, fontSize: fontSize,
            measureWidth: rubyMeasurementExtent,
            pageHeight: rubyMeasurementExtent,
            lineSpacing: 0,
            label: "\(labelPrefix)-on",
            ruby: (annotation: annotation, range: range),
            rubySizeFactor: rubySizeFactor
        )
        let plainReport = try TextLayout.layout(plainInput).report
        let rubyReport = try TextLayout.layout(rubyInput).report

        return RubyMeasurement(
            base: base,
            annotation: annotation,
            plainReport: plainReport,
            rubyReport: rubyReport,
            plainHeight: lineBoxHeight(of: plainReport),
            rubyHeight: lineBoxHeight(of: rubyReport),
            baseUsesRequestedFont: TextLayout.usesOnlyTheRequestedFont(base, font: font),
            annotationUsesRequestedFont: TextLayout.usesOnlyTheRequestedFont(annotation, font: font)
        )
    }

    static func lineBoxHeight(of report: LayoutReport) -> Double {
        (report.lines.first.map { $0.ascent + $0.descent + $0.leading }) ?? 0
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
