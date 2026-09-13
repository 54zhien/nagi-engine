import Foundation
import SpikeKit

/// Runs Spike A and assembles the report.
public enum SpikeA {
    public static let identifier = "spike-a"

    /// `async` since R2, because the reanchor-policy probe calls the public
    /// `ReanchorService.reanchor`, which is `async throws` — production has to
    /// materialise a unit before it can read text (ADR-0004), and the signature
    /// says so even while this round is handed a materialised document.
    ///
    /// Nothing else about the run changed: every earlier probe is still
    /// synchronous and still called in the same order.
    public static func run(
        outputDirectory: URL,
        expectedFingerprint: String? = nil
    ) async throws -> SpikeAReport {
        let document = try SpikeAFixture.document()

        // **This is the transcript artifact's text, not the metric's.**
        //
        // The separator between units is a byte of punctuation that no metric
        // counts: `canonicalTextIndex` divides by `Document.totalLength`, which
        // is the plain sum of the units' lengths, so this string is longer than
        // the reading order by one separator per gap. The report carries both
        // numbers, because a report that states one length while every metric
        // uses another states a number no measurement uses.
        let concatenated = document.readingOrder
            .map(\.canonical.string)
            .joined(separator: "\n")

        var probes: [ProbeOutcome] = []
        probes.append(try canonicalTextShapeProbe(document))
        probes.append(try hrefRoutingProbe(document))
        probes.append(try duplicateTextProbe(document))
        probes.append(try offsetBoundaryProbe(document))

        let roundTrips = try SpikeACases.all(document)
        probes.append(try identityRoundTripProbe(roundTrips))

        // ---- The metric matrix: ADR-0009's properties, on three axes ----
        probes.append(try ProgressProbes.monotonicity(document))
        probes.append(try ProgressProbes.layoutIndependence())
        probes.append(try ProgressProbes.boundedSeek())
        probes.append(try ProgressProbes.provenanceHonesty(document))

        // ---- Reanchor: ADR-0012's contract, measured ----
        //
        // **Appended last, and that is part of the artifact.** Probe order is
        // report order, and the R2 acceptance criterion is that the payload
        // with this one entry removed is byte-identical to the sealed baseline
        // — which is only well defined while the new entry is the final one.
        probes.append(try await ReanchorPolicyProbe.run())

        let canonicalArtifact = ArtifactRecord(byteCount: try writeTranscript(
            document,
            to: outputDirectory.appendingPathComponent("canonical-text.txt")
        ))

        let documents = document.readingOrder.map { unit in
            DocumentSummary(
                id: unit.id,
                href: unit.href,
                utf16Length: unit.canonical.utf16Count,
                elementCount: unit.canonical.elements.count,
                explicitIDCount: unit.canonical.elements.filter { $0.explicitID != nil }.count
            )
        }

        var report = SpikeAReport(
            spike: identifier,
            fixtureName: SpikeAFixture.name,
            canonicalTextSHA256: SHA256.hex(concatenated),
            canonicalTextUTF16Length: concatenated.utf16.count,
            // The sum of the units' own lengths — the denominator every
            // `canonicalTextIndex` coordinate is a fraction of, and a smaller
            // number than the transcript above by one separator per gap.
            readingOrderUTF16Length: document.totalLength,
            documents: documents,
            probes: probes,
            roundTrips: roundTrips,
            artifacts: SpikeAArtifacts(
                canonicalText: canonicalArtifact,
                fingerprint: ArtifactRecord(byteCount: 0)
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
        // `artifacts` and `determinism` by construction — so filling either in
        // afterwards cannot change the value just computed.
        let fingerprint = try report.canonicalFingerprint()
        try ReportIO.writeFingerprint(fingerprint, for: identifier, to: outputDirectory)

        let fingerprintURL = outputDirectory.appendingPathComponent("\(identifier).fingerprint")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: fingerprintURL.path),
           let size = (attributes[.size] as? NSNumber)?.intValue {
            report.artifacts.fingerprint = ArtifactRecord(byteCount: size)
        }

        let (execution, finding, detail): (ProbeOutcome.Execution, ProbeOutcome.Finding?, String)
        if let expectedFingerprint {
            if expectedFingerprint == fingerprint {
                execution = .measured
                finding = .yes
                detail = "fingerprint matches the supplied run (\(fingerprint.prefix(12))…)"
            } else {
                execution = .measured
                finding = .no
                detail = "fingerprint \(fingerprint.prefix(12))… does not match the supplied \(expectedFingerprint.prefix(12))… — the payload is not stable across processes"
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

    // MARK: - Probes

    /// ADR-0005 says the annotation and the folded whitespace do not occupy the
    /// canonical axis, and ADR-0004 says offsets are UTF-16. All three are
    /// checkable without a font or a layout, which is why they belong here
    /// rather than in a test: they describe the artifact, not the code.
    static func canonicalTextShapeProbe(_ document: Document) throws -> ProbeOutcome {
        let unit = document.unit(withID: "OEBPS/chap3.xhtml")
        let text = unit?.canonical.string ?? ""

        let annotationExcluded = !text.contains(SpikeAFixture.annotation)

        // The folding rule is this spike's assumption rather than CSS, so the
        // probe states what the model predicts instead of what CSS would do.
        let spaced = unit?.canonical.element(withID: "spaced")
            .flatMap { unit?.canonical.text(in: $0.utf16Range) } ?? ""
        let foldingAsModelled = spaced == "空白 折叠 测试"

        let astral = unit?.canonical.element(withID: "astral")
            .flatMap { unit?.canonical.text(in: $0.utf16Range) } ?? ""
        let utf16IsWider = astral.utf16.count > astral.count

        return try ProbeOutcome(
            name: "canonical-text-shape",
            question: "Does the canonical text honour ADR-0005 — ruby excluded, whitespace folded, offsets in UTF-16?",
            execution: .measured,
            finding: (annotationExcluded && foldingAsModelled && utf16IsWider) ? .yes : .no,
            detail: "annotation excluded: \(annotationExcluded); folding matches this spike's model: \(foldingAsModelled); non-BMP text is wider in UTF-16 than in Characters: \(utf16IsWider)",
            numbers: [
                "chap3UTF16Units": Double(text.utf16.count),
                "chap3Characters": Double(text.count)
            ]
        )
    }

    /// Two units with identical content, and therefore the same ids at the same
    /// paths. Only the href tells them apart.
    static func hrefRoutingProbe(_ document: Document) throws -> ProbeOutcome {
        func position(href: String) -> NativePosition? {
            LocationBridge.native(
                from: ReadiumLocator(
                    href: href,
                    mediaType: "application/xhtml+xml",
                    locations: .init(fragments: ["p1"])
                ),
                in: document
            ).position
        }
        let first = position(href: "OEBPS/chap1.xhtml")
        let second = position(href: "OEBPS/chap2.xhtml")
        let resolved = first != nil && second != nil
        // Same id, same offset — and it must be a different unit. If these
        // agree, the bridge is resolving by id alone and the href is decorative.
        let distinguished = resolved && first?.unitID != second?.unitID

        return try ProbeOutcome(
            name: "href-routing",
            question: "Do two units with identical content stay distinguishable by href alone?",
            execution: resolved ? .measured : .inconclusive,
            finding: resolved ? (distinguished ? .yes : .no) : nil,
            detail: resolved
                ? "the same id resolved into \(first?.unitID ?? "?") and \(second?.unitID ?? "?") — the href is doing the work"
                : "resolving \"p1\" in the two identical units did not produce two positions",
            numbers: ["units": Double(document.readingOrder.count)]
        )
    }

    /// A locator carrying only a quotation, against text that repeats.
    static func duplicateTextProbe(_ document: Document) throws -> ProbeOutcome {
        let repeated = SpikeAFixture.repeatedText
        let occurrences = document.unit(withID: "OEBPS/chap1.xhtml")?
            .canonical.elements(withText: repeated).count ?? 0

        let resolution = LocationBridge.native(
            from: ReadiumLocator(
                href: "OEBPS/chap1.xhtml",
                mediaType: "application/xhtml+xml",
                text: .init(highlight: repeated)
            ),
            in: document
        )
        var candidates = 0
        if case .ambiguous(let positions, _, _) = resolution { candidates = positions.count }

        // The fixture guarantees the text repeats, so "the text occurs twice and
        // the bridge refuses to choose" is a yes. A single occurrence would mean
        // the fixture stopped exercising the axis, which is a no.
        let asDesigned = occurrences > 1 && candidates == occurrences

        return try ProbeOutcome(
            name: "duplicate-text-ambiguity",
            question: "Does a quotation-only locator stay ambiguous when the quoted text repeats?",
            execution: .measured,
            finding: asDesigned ? .yes : .no,
            detail: "the quotation occurs \(occurrences) times in the unit and the bridge returned \(candidates) candidate position(s)",
            numbers: [
                "occurrences": Double(occurrences),
                "candidates": Double(candidates)
            ]
        )
    }

    /// The bridge produces offsets, not boundaries. An offset landing inside a
    /// non-BMP character is fine as a coordinate and wrong as a caret — which is
    /// exactly why ADR-0004 keeps `PositionResolver` in its own layer, and why
    /// the bridge is not allowed to quietly round.
    static func offsetBoundaryProbe(_ document: Document) throws -> ProbeOutcome {
        guard let chapter3 = document.unit(withID: "OEBPS/chap3.xhtml"),
              let astral = chapter3.canonical.element(withID: "astral")
        else {
            return try ProbeOutcome(
                name: "offset-boundaries",
                question: "Does the bridge hand back offsets that are not text boundaries?",
                execution: .inconclusive,
                detail: "the fixture has no non-BMP element to test with"
            )
        }

        // +4 is the low surrogate of 𠀋 — see the case of the same name.
        let offset = astral.utf16Range.lowerBound + 4
        let midCharacter = chapter3.canonical.isMidCharacter(offset)
        // The export carries the names it had to drop; this probe asks only
        // whether the bridge accepted the offset, so only its existence is read.
        let exported = LocationBridge.locator(
            from: NativePosition(unitID: chapter3.id, nodeID: .explicitID("astral"), utf16Offset: offset),
            in: document
        )
        let carriedThrough = exported != nil

        return try ProbeOutcome(
            name: "offset-boundaries",
            question: "Does the bridge hand back offsets that are not text boundaries?",
            execution: .measured,
            finding: midCharacter ? .yes : .no,
            detail: "offset \(offset) lands \(midCharacter ? "inside" : "outside") a non-BMP character, and the bridge \(carriedThrough ? "carries it through unchanged" : "refuses it") — snapping such an offset is PositionResolver's job (ADR-0004), not the bridge's",
            numbers: [
                "offset": Double(offset),
                "midCharacter": midCharacter ? 1 : 0
            ]
        )
    }

    static func identityRoundTripProbe(_ roundTrips: [RoundTrip]) throws -> ProbeOutcome {
        func count(_ matches: (RoundTripOutcome) -> Bool) -> Int {
            roundTrips.filter { matches($0.outcome) }.count
        }
        let exact = count { if case .exact = $0 { return true }; return false }
        let recomputed = count { if case .recomputedEquivalent = $0 { return true }; return false }
        let semantic = count { if case .semanticEquivalent = $0 { return true }; return false }
        let loses = count { if case .loses = $0 { return true }; return false }
        let reanchor = count { if case .requiresReanchor = $0 { return true }; return false }
        let needingValidator = roundTrips.filter(\.needsValidator).count

        // These buckets are counted with independent predicates and no `switch`,
        // so the compiler cannot see it when a new `RoundTripOutcome` case is
        // added and matches none of them. Everywhere else that failure is
        // silent: the row disappears from the census, no `numbers` key appears,
        // and not one word of `detail` changes. Only the sum can see it, so the
        // sum has to be checked. (`main.swift`'s `outcomeLabel` is the
        // compile-time tripwire; this is the runtime one. Neither is optional.)
        //
        // Five buckets and not six: `requiresValidator` was deleted, because no
        // path could produce it. Note what this sum could and could not do about
        // that — a bucket that is always zero satisfies the sum by being zero, so
        // the invariant never caught it. The sum counts rows, not reachability.
        let counted = exact + recomputed + semantic + loses + reanchor
        guard counted == roundTrips.count else {
            throw RoundTripCensusError.bucketsDoNotSum(
                rows: roundTrips.count,
                counted: counted
            )
        }

        return try ProbeOutcome(
            name: "identity-round-trip",
            question: "Which conversions survive a round trip, and which need a validator or a reanchor?",
            execution: roundTrips.isEmpty ? .inconclusive : .measured,
            finding: roundTrips.isEmpty ? nil : .yes,
            detail: "\(roundTrips.count) cases: \(exact) exact, \(recomputed) recomputed-equivalent, \(semantic) semantic-equivalent, \(loses) losing fields, \(reanchor) needing a reanchor. \(needingValidator) of them produced a candidate, so \(needingValidator) of them have an AnchorValidator's work to do — the rest produced none, which is why this is not \(roundTrips.count).",
            numbers: [
                "cases": Double(roundTrips.count),
                "exact": Double(exact),
                "recomputedEquivalent": Double(recomputed),
                "semanticEquivalent": Double(semantic),
                "losesFields": Double(loses),
                "requiresReanchor": Double(reanchor),
                "needingValidator": Double(needingValidator)
            ]
        )
    }

    // MARK: - Helpers

    /// A human-review artifact, the way Spike B's PNGs are: the canonical texts
    /// and their element tables, so a reader can check an offset by eye instead
    /// of taking the JSON's word for it.
    private static func writeTranscript(_ document: Document, to url: URL) throws -> Int {
        var lines: [String] = []
        for unit in document.readingOrder {
            lines.append("=== \(unit.href)  (\(unit.canonical.utf16Count) UTF-16 units)")
            lines.append(unit.canonical.string)
            lines.append("--- elements")
            for element in unit.canonical.elements {
                let id = element.explicitID.map { "#\($0)" } ?? ""
                let path = element.path.map(String.init).joined(separator: "/")
                lines.append(
                    "  \(element.name)\(id)  "
                        + "\(element.utf16Range.lowerBound)..<\(element.utf16Range.upperBound)  path=\(path)"
                )
            }
            lines.append("")
        }

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(lines.joined(separator: "\n").utf8).write(to: url)

        // The encoder saying yes is not the filesystem saying yes — same rule as
        // Spike B's writePNG.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0
        else {
            throw SpikeAError.emptyArtifact(url.lastPathComponent)
        }
        return size
    }
}

public enum SpikeAError: Error, CustomStringConvertible {
    case emptyArtifact(String)

    public var description: String {
        switch self {
        case .emptyArtifact(let name):
            return "\(name) was written but is empty"
        }
    }
}
