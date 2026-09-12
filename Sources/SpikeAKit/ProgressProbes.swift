import Foundation
import SpikeKit

/// ADR-0009's three properties, measured on three axes — the metric matrix.
///
/// **The failure mode here is not "impossible to be false" in general. It is a
/// probe that is true by construction.** The first round's `native-path-anchored`
/// row was exactly that: an equality guaranteed by IEEE-754, reported as
/// evidence. Every probe below therefore names, in its own detail line, the
/// mutation that would turn it into a `no`; a probe that cannot name one has no
/// business in the report.
///
/// **A refusal is a result.** Every call that can come back empty is handled as
/// a possible outcome rather than propagated. An axis that returns nil where a
/// probe expected a value is a finding about the axis — letting it throw would
/// exit the process non-zero and fail a gate, which in the log is
/// indistinguishable from a broken harness. `SpikeKit/Report.swift` draws that
/// line on purpose: "a code failure never arrives here".
enum ProgressProbes {

    // MARK: - Shared

    /// The navigation direction, with the service's throw kept as a value.
    ///
    /// `PublicationProgressService` throws rather than clamps — that is its
    /// contract, and the API to test — but whether a refusal makes a probe `no`
    /// or `inconclusive` is the probe's judgement, so the rejection is caught
    /// here and handed back.
    private static func seek<Axis: ProgressMetricAxis>(
        _ axis: Axis,
        _ progression: Double
    ) -> Result<NativePosition, ProgressError> {
        do {
            return .success(try PublicationProgressService(axis: axis).position(near: progression))
        } catch let error as ProgressError {
            return .failure(error)
        } catch {
            return .failure(.progressionOutsideTheAxis(progression))
        }
    }

    /// A position at an offset, with the node that contains it.
    ///
    /// Deliberately a copy of what `CanonicalTextIndexAxis` does rather than a
    /// call into it. A probe that borrows the implementation's own helpers is
    /// asking the implementation to confirm itself, which is the shape this
    /// whole harness exists to avoid.
    private static func position(in unit: DocumentUnit, at offset: Int) -> NativePosition {
        let nodeID: NodeID
        if let element = unit.canonical.innermostElement(containing: offset) {
            nodeID = element.explicitID.map { NodeID.explicitID($0) } ?? .path(element.path)
        } else if let last = unit.canonical.elements.last {
            nodeID = last.explicitID.map { NodeID.explicitID($0) } ?? .path(last.path)
        } else {
            nodeID = .path([])
        }
        return NativePosition(unitID: unit.id, nodeID: nodeID, utf16Offset: offset)
    }

    private static func count(_ value: Bool) -> Double { value ? 1 : 0 }

    private static func decimal(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.6f", value)
    }

    // MARK: - 1. Monotonicity

    /// ADR-0009 property 1, over a sweep that crosses every unit boundary and
    /// steps *inside* the empty unit.
    ///
    /// **The falsifier is a prefix sum off by one.** The assertion is stated as a
    /// relation against the reading order — "the coordinate at unit `i`'s start
    /// equals the sum of the lengths before it" — and not as a constant, because
    /// two earlier versions of this repository's offset assertions were pinned
    /// from memory and were wrong both times, each reporting a number that looked
    /// entirely reasonable.
    ///
    /// **The empty unit is what makes the boundary visible.** Its start and end
    /// coordinates must be the *same* number; an implementation that adds one per
    /// unit, or that skips a unit with no text, moves the whole tail of the book.
    /// And on a per-unit fraction, `0 / 0` is NaN — which is why the second half
    /// of this probe asks a document of nothing but empty units for its
    /// progressions and requires `nil` rather than a non-finite number.
    static func monotonicity(_ document: Document) throws -> ProbeOutcome {
        let axis = CanonicalTextIndexAxis(document: document)

        var sweep: [NativePosition] = []
        for unit in document.readingOrder {
            let length = unit.length
            let offsets = Set([0, min(1, length), length / 2, max(length - 1, 0), length]).sorted()
            for offset in offsets {
                sweep.append(position(in: unit, at: offset))
            }
        }

        var progressions: [Double] = []
        var missing = 0
        var nonFinite = 0
        for point in sweep {
            guard let progression = axis.progression(of: point) else {
                missing += 1
                continue
            }
            if !progression.value.isFinite { nonFinite += 1 }
            progressions.append(progression.value)
        }

        var descending = 0
        if progressions.count > 1 {
            for index in 1..<progressions.count where progressions[index] < progressions[index - 1] {
                descending += 1
            }
        }

        // The prefix-sum relation, computed here from the reading order rather
        // than read out of the axis.
        var running = 0
        var startMismatches = 0
        for unit in document.readingOrder {
            let expected = Double(running)
            let actual = axis.coordinate(of: position(in: unit, at: 0))
            if actual != expected { startMismatches += 1 }
            running += unit.length
        }

        // Start and end of the empty unit must coincide. Found by length rather
        // than by name, so a fixture that stopped carrying one makes this
        // inconclusive instead of quietly true.
        var emptyUnitTies = 0
        var emptyUnits = 0
        for unit in document.readingOrder where unit.length == 0 {
            emptyUnits += 1
            let start = axis.coordinate(of: position(in: unit, at: 0))
            let end = axis.coordinate(of: position(in: unit, at: unit.length))
            if let start, let end, start == end { emptyUnitTies += 1 }
        }

        // A document whose every unit is empty: there is no fraction to state.
        let empty = Document(readingOrder: [
            DocumentUnit(
                id: "empty",
                href: "empty",
                mediaType: "application/xhtml+xml",
                canonical: CanonicalText(string: "", elements: [])
            )
        ])
        let emptyAxis = CanonicalTextIndexAxis(document: empty)
        let emptyProgression = emptyAxis.progression(
            of: NativePosition(unitID: "empty", nodeID: .path([]), utf16Offset: 0)
        )

        let endpoints = progressions.first == 0.0 && progressions.last == 1.0
        // `emptyUnits > 0` is not redundant with the tie count. Without it, a
        // fixture that stopped carrying an empty unit would report `0 == 0` and
        // pass — a `yes` built from nothing, which is the one thing this file
        // says it will not do.
        let clean = missing == 0 && nonFinite == 0 && descending == 0
            && startMismatches == 0 && emptyUnits > 0 && emptyUnitTies == emptyUnits
            && emptyProgression == nil
        let decided = emptyUnits > 0

        return try ProbeOutcome(
            name: "progress-monotonicity",
            question: "Is publication progress monotone across unit boundaries, including a unit with no text at all?",
            execution: decided ? .measured : .inconclusive,
            finding: decided ? (clean ? .yes : .no) : nil,
            detail: """
            \(sweep.count) positions over \(document.readingOrder.count) units: \
            \(descending) descending step(s), \(missing) with no coordinate, \(nonFinite) non-finite, \
            \(startMismatches) unit-start prefix-sum mismatch(es); \
            endpoints are 0 and 1: \(endpoints); \
            \(emptyUnitTies)/\(emptyUnits) empty unit(s) have start == end; \
            a document of nothing but empty units reports \
            \(emptyProgression == nil ? "nil" : "a number") rather than NaN. \
            Falsified by a prefix sum off by one, or by a per-unit fraction meeting 0/0.
            """,
            numbers: [
                "units": Double(document.readingOrder.count),
                "positions": Double(sweep.count),
                "descendingSteps": Double(descending),
                "missingCoordinates": Double(missing),
                "nonFinite": Double(nonFinite),
                "prefixSumMismatches": Double(startMismatches),
                "emptyUnits": Double(emptyUnits),
                "emptyUnitTies": Double(emptyUnitTies),
                "endpointsAreZeroAndOne": count(endpoints),
                "allEmptyDocumentRefuses": count(emptyProgression == nil)
            ]
        )
    }

    // MARK: - 2. Layout independence

    /// One mutation — the container's declared pagination — asked of three
    /// metrics built over **the same bytes**.
    ///
    /// The original design put the text axis and the page axis on different
    /// subjects, which made "one moves, the other does not" true because the two
    /// shared nothing; the page arm could not move at all, and the probe would
    /// have reported `inconclusive` forever while looking rigorous. Building all
    /// three on one `ByteResource` is what makes the arm a measurement.
    ///
    /// - `sourceBytes` **must not** move. **Sharp arm** — a lazy implementation
    ///   that quantized a byte coordinate to the page grid moves with it, and
    ///   this catches that.
    /// - `fixedPageOrdinal` **must** move. Falsified by an implementation that is
    ///   really a text or byte fraction wearing a page's name, which is not
    ///   hypothetical: this repository wrote a text-length metric into a field
    ///   whose declared semantics are byte length, and nothing noticed.
    /// - `canonicalTextIndex` **must not** move. **Control arm**, labelled as
    ///   such: a correct implementation cannot fail it. It is here to pin that
    ///   the axis reads text and not pagination, nothing more.
    ///
    /// The admission side is measured too: on a resource whose container declares
    /// **no** pagination, every coordinate is nil. Falsified by an implementation
    /// that splits reflowable content into even pages and calls them ordinals —
    /// which is the prohibition ADR-0008 states, turned into something checkable
    /// rather than restated.
    static func layoutIndependence() throws -> ProbeOutcome {
        let twoPage = SpikeAFixture.twoPageByteResource
        let fourPage = SpikeAFixture.fourPageByteResource
        let reflowable = SpikeAFixture.reflowableByteResource

        let bytesTwo = SourceBytesAxis(resource: twoPage)
        let bytesFour = SourceBytesAxis(resource: fourPage)
        let pagesTwo = FixedPageOrdinalAxis(resource: twoPage)
        let pagesFour = FixedPageOrdinalAxis(resource: fourPage)
        // Built from each resource's own decoded text, so all three metrics see
        // the same subject and the only thing that varies is `pageRanges`.
        let textTwo = CanonicalTextIndexAxis(document: twoPage.singleUnitDocument)
        let textFour = CanonicalTextIndexAxis(document: fourPage.singleUnitDocument)

        var swept = 0
        var bytesMoved = 0
        var pagesMoved = 0
        var textMoved = 0
        var missing = 0

        for offset in 0...twoPage.utf16Count {
            guard let position = twoPage.position(atUTF16: offset) else {
                missing += 1
                continue
            }
            swept += 1
            if bytesTwo.coordinate(of: position) != bytesFour.coordinate(of: position) { bytesMoved += 1 }
            if pagesTwo.coordinate(of: position) != pagesFour.coordinate(of: position) { pagesMoved += 1 }
            if textTwo.coordinate(of: position) != textFour.coordinate(of: position) { textMoved += 1 }
        }

        let reflowableAxis = FixedPageOrdinalAxis(resource: reflowable)
        var reflowableAnswers = 0
        for offset in 0...reflowable.utf16Count {
            guard let position = reflowable.position(atUTF16: offset) else { continue }
            if reflowableAxis.coordinate(of: position) != nil { reflowableAnswers += 1 }
        }

        // Read from the fixture, not typed here. A literal would keep saying
        // "2 -> 4" after a fixture change, and the artifact would then state a
        // number no measurement uses — which is the defect this round added
        // `readingOrderUTF16Length` to stop repeating.
        let before = twoPage.pageRanges?.count ?? 0
        let after = fourPage.pageRanges?.count ?? 0

        let execution: ProbeOutcome.Execution
        let finding: ProbeOutcome.Finding?
        if pagesMoved == 0 || swept == 0 {
            // The mutation never reached the metric: nothing was measured, so
            // there is no yes or no to report. A probe that cannot fail has no
            // value, and saying so is the honest answer.
            execution = .inconclusive
            finding = nil
        } else {
            execution = .measured
            finding = (bytesMoved == 0 && textMoved == 0 && reflowableAnswers == 0) ? .yes : .no
        }

        return try ProbeOutcome(
            name: "progress-layout-independence",
            question: "Does changing only the container's declared pagination move the page metric while leaving the byte and text metrics alone?",
            execution: execution,
            finding: finding,
            detail: """
            one mutation (\(before) pages -> \(after)), \(swept) positions, same \(twoPage.byteCount) bytes: \
            sourceBytes moved on \(bytesMoved), fixedPageOrdinal on \(pagesMoved), canonicalTextIndex on \(textMoved) \
            (the text arm is a **control**, not a measurement). \
            On the resource whose container declares no pagination, \(reflowableAnswers) positions got a page ordinal back — \
            the metric must refuse to answer rather than invent one (ADR-0008's admission criterion). \
            Falsified by a page metric that is really a byte fraction (it would not move), \
            by a byte metric quantized to the page grid (it would), or by an axis that paginates reflowable content.
            """,
            numbers: [
                "positions": Double(swept),
                "positionsWithoutAPosition": Double(missing),
                "pageCountBefore": Double(before),
                "pageCountAfter": Double(after),
                "sourceBytesMoved": Double(bytesMoved),
                "fixedPageOrdinalMoved": Double(pagesMoved),
                "canonicalTextIndexMoved": Double(textMoved),
                "reflowablePageOrdinals": Double(reflowableAnswers)
            ]
        )
    }

    // MARK: - 3. Bounded seek

    /// ADR-0009 property 3, in each metric's own unit.
    ///
    /// **Progression space cannot be used for this.** `ProbeOutcome` quantizes
    /// every number to three decimals, so a discrepancy of 1e-9 measured in
    /// progression space is written out as `0.0` and manufactures exactness.
    /// Every comparison below is in bytes or in pages.
    ///
    /// **The snap direction is pinned, not merely bounded.** Asserting only that
    /// the answer is a legal boundary lets a nearest-boundary implementation
    /// pass: asked for byte 4, it may answer 5 instead of 3, both legal and both
    /// within tolerance. The assertion is therefore "the greatest legal boundary
    /// not past the request".
    ///
    /// The two arms:
    /// - `fixedPageOrdinal`, tolerance **0**. Under the page-centre convention
    ///   only flooring round-trips; rounding to the neighbouring boundary is off
    ///   by a whole page.
    /// - `sourceBytes`, tolerance **3** — the metric's own bound (a four-byte
    ///   scalar has three continuation bytes), not this fixture's, which is 2.
    ///   The scan sweeps **every** byte offset, not only the legal ones, and each
    ///   hazard must be hit at least once or the arm is inconclusive. Not
    ///   touching the hazard is not the same as surviving it.
    static func boundedSeek() throws -> ProbeOutcome {
        let resource = SpikeAFixture.twoPageByteResource
        let bytesAxis = SourceBytesAxis(resource: resource)
        let pagesAxis = FixedPageOrdinalAxis(resource: resource)

        // ---- sourceBytes ----
        var byteRequests = 0
        var byteMismatches = 0
        var byteOverTolerance = 0
        var byteRefusals = 0
        var maxSnap = 0.0
        var hazards: [ByteResource.BoundaryHazard: Int] = [:]

        for requested in 0...resource.byteCount {
            byteRequests += 1
            let fraction = Double(requested) / Double(resource.byteCount)
            guard case .success(let back) = seek(bytesAxis, fraction),
                  let landed = bytesAxis.coordinate(of: back)
            else {
                byteRefusals += 1
                continue
            }
            // The greatest legal boundary not past the request. Note that the
            // expectation is computed from the integer the request was built
            // from, not by re-deriving one from the fraction — `4 / 12 * 12` is
            // not guaranteed to be exactly 4, and the probe must not depend on
            // it being so.
            if let expected = resource.legalBoundaries.last(where: { $0 <= requested }) {
                if Int(landed) != expected { byteMismatches += 1 }
            } else {
                byteMismatches += 1
            }
            let snap = abs(landed - Double(requested))
            maxSnap = max(maxSnap, snap)
            if snap > bytesAxis.seekTolerance { byteOverTolerance += 1 }
            if let hazard = resource.hazard(atByte: requested) {
                hazards[hazard, default: 0] += 1
            }
        }

        // The derived byte/text map against the hand-written table. This is the
        // one cross-check between the two sources of truth, and it catches a map
        // that put a boundary inside a multi-byte sequence — or a table that is
        // simply wrong.
        var tableMismatches = 0
        for boundary in resource.legalBoundaries {
            guard let utf16 = resource.utf16Offset(forByte: boundary) else {
                tableMismatches += 1
                continue
            }
            if resource.byteOffset(forUTF16: utf16) != boundary { tableMismatches += 1 }
        }

        // ---- fixedPageOrdinal ----
        var pageRequests = 0
        var pageFailures = 0
        var pageRefusals = 0
        var maxPageError = 0.0

        for offset in 0...resource.utf16Count {
            guard let position = resource.position(atUTF16: offset),
                  let ordinal = pagesAxis.coordinate(of: position),
                  let progression = pagesAxis.progression(of: position)
            else { continue }
            pageRequests += 1
            guard case .success(let back) = seek(pagesAxis, progression.value),
                  let landed = pagesAxis.coordinate(of: back)
            else {
                // The last page under a rounding implementation lands one past
                // the end, which the axis refuses rather than clamping — and a
                // refusal there is a failure of the round trip, not a crash.
                pageRefusals += 1
                pageFailures += 1
                continue
            }
            let error = abs(landed - ordinal)
            maxPageError = max(maxPageError, error)
            if error > pagesAxis.seekTolerance { pageFailures += 1 }
        }

        let exercised = (hazards[.multiByteInterior] ?? 0) > 0
            && (hazards[.crlfInterior] ?? 0) > 0
            && (hazards[.invalidLeadByteWidth] ?? 0) > 0
        let decided = exercised && pageRequests > 0 && byteRequests > 0

        let clean = byteMismatches == 0 && byteOverTolerance == 0 && byteRefusals == 0
            && tableMismatches == 0 && pageFailures == 0

        return try ProbeOutcome(
            name: "progress-bounded-seek",
            question: "Does seek land within the metric's own declared tolerance, in the metric's own unit, and on the correct side?",
            execution: decided ? .measured : .inconclusive,
            finding: decided ? (clean ? .yes : .no) : nil,
            detail: """
            sourceBytes: \(byteRequests) byte offsets requested, \(byteMismatches) not the greatest legal boundary at or before the request, \
            \(byteOverTolerance) past the declared tolerance \(Int(bytesAxis.seekTolerance)), \(byteRefusals) refused; max snap \(maxSnap) byte(s). \
            Hazards reached — multi-byte interior \(hazards[.multiByteInterior] ?? 0), CRLF interior \(hazards[.crlfInterior] ?? 0), \
            after an ill-formed byte \(hazards[.invalidLeadByteWidth] ?? 0); \(tableMismatches) disagreement(s) between the derived map and the hand-written table. \
            fixedPageOrdinal: \(pageRequests) round trips, \(pageFailures) landing off their page against a declared tolerance of \(Int(pagesAxis.seekTolerance)), \
            max error \(maxPageError) page(s). \
            Falsified by `Int(x * byteCount)` without snapping, by snapping to the nearest boundary instead of the preceding one, \
            and by rounding rather than flooring a page fraction.
            """,
            numbers: [
                "byteRequests": Double(byteRequests),
                "byteMismatches": Double(byteMismatches),
                "byteOverTolerance": Double(byteOverTolerance),
                "byteRefusals": Double(byteRefusals),
                "declaredToleranceBytes": bytesAxis.seekTolerance,
                "maxSnapBytes": maxSnap,
                "hazardMultiByteInterior": Double(hazards[.multiByteInterior] ?? 0),
                "hazardCRLFInterior": Double(hazards[.crlfInterior] ?? 0),
                "hazardInvalidLeadByte": Double(hazards[.invalidLeadByteWidth] ?? 0),
                "tableMismatches": Double(tableMismatches),
                "pageRoundTrips": Double(pageRequests),
                "pageFailures": Double(pageFailures),
                "pageRefusals": Double(pageRefusals),
                "declaredTolerancePages": pagesAxis.seekTolerance,
                "maxPageError": maxPageError
            ]
        )
    }

    // MARK: - 4. Provenance honesty

    /// Whether the artifact says where each number came from — the question this
    /// whole harness exists to ask.
    ///
    /// Three parts, and they are not equally strong. Each is labelled:
    ///
    /// **(a) Falsifiable: the metric label is never dropped in silence.** Every
    /// number written into `locations.progression` must both be recorded as
    /// having lost its metric **and** be the per-resource fraction. The two
    /// candidate numbers are different — `22/76` against `22/187` — so the probe
    /// reports which one it found. The falsifier is the defect this repository
    /// already has an instance of: a metric that does not match the field it was
    /// written into.
    ///
    /// **(b) Falsifiable: `.carried` needs a carrier.** If a row says an offset
    /// travelled, then the locator that came back must actually have somewhere to
    /// hold it — a fragment naming an element that starts exactly there, or one
    /// of the two field classes ADR-0009 names as offset-capable. The check runs
    /// against `Document` and the emitted locator, **never against `Resolution`**,
    /// which is the only reason it is not a tautology: the row's own
    /// `derivedFrom` is computed from the same expression as its `carried`, so
    /// `derivedFrom != nil ⟹ not carried` would be true for every possible input.
    /// The round-two defect — `carried` decided by comparing a basis *string*,
    /// which reported `native-path-anchored` as `.exact` — is exactly what this
    /// fires on: that row's locator has no fragment at all.
    ///
    /// `unitID` is deliberately **not** covered, and the reason is in the report
    /// rather than in a comment nobody reads: `unitID == .carried` is reachable
    /// under `Resolution.approximate` today, and it is a tautology of the same
    /// kind — `locator(from:)` builds the href from the unit and `native(from:)`
    /// reads it back to that same unit. It is the field that was deleted for
    /// being unable to vary, under another name. Excluding it silently is how the
    /// last one got in.
    ///
    /// **(c) A tripwire, not a partition.** Every name appearing in a row's
    /// `discarded` must be one the harness can explain. A new discard appended
    /// without a word defined for it is a `no` that names the word. This is
    /// weaker than the outcome census in `identityRoundTripProbe` — a count of
    /// names cannot partition rows — and it is not dressed up as one.
    static func provenanceHonesty(_ document: Document) throws -> ProbeOutcome {
        let roundTrips = SpikeACases.all(document)
        let nativeCases = SpikeACases.nativeCases(document)
        let nativeTrips = SpikeACases.nativeFirst(document)

        // ---- (a) the label is written down when it is dropped ----
        let publicationAxis = CanonicalTextIndexAxis(document: document)
        var progressionRows = 0
        var unrecordedMetric = 0
        var perUnitMismatches = 0
        var publicationLevelValues = 0
        var writtenExample: Double?
        var perUnitExample: Double?
        var publicationExample: Double?

        for (testCase, trip) in zip(nativeCases, nativeTrips) {
            guard let exported = LocationBridge.locator(from: testCase.position, in: document),
                  let written = exported.locator.locations.progression
            else { continue }
            progressionRows += 1
            if !exported.discarded.contains("progression.metric") { unrecordedMetric += 1 }
            guard let unit = document.unit(withID: testCase.position.unitID) else { continue }
            let perUnit = Double(testCase.position.utf16Offset) / Double(unit.length)
            let atPublicationLevel = publicationAxis.progression(of: testCase.position)?.value
            if abs(written - perUnit) > 1e-12 { perUnitMismatches += 1 }
            if let atPublicationLevel, abs(written - atPublicationLevel) < 1e-12 {
                publicationLevelValues += 1
            }
            // The example reported is the **derived** row's, because that is the
            // one where the two candidate numbers tell the story: the row whose
            // offset was rebuilt from a fraction is the row where writing the
            // wrong one is invisible.
            if writtenExample == nil || trip.derivedFrom != nil {
                writtenExample = written
                perUnitExample = perUnit
                publicationExample = atPublicationLevel
            }
        }

        // ---- (b) a carried offset must have a carrier ----
        var carriedRows = 0
        var unbacked = 0
        var uncarriedRows = 0

        for (testCase, trip) in zip(nativeCases, nativeTrips) {
            guard trip.fields["utf16Offset"] == .carried else {
                uncarriedRows += 1
                continue
            }
            carriedRows += 1
            guard let exported = LocationBridge.locator(from: testCase.position, in: document),
                  let unit = document.unit(withID: testCase.position.unitID)
            else {
                unbacked += 1
                continue
            }
            let locations = exported.locator.locations
            let namedByAFragment = locations.fragments
                .compactMap { unit.canonical.element(withID: $0) }
                .contains { $0.utf16Range.lowerBound == testCase.position.utf16Offset }
            // The two field classes ADR-0009:71 names as able to carry an offset.
            // They are absent from this bridge by design, but a future one that
            // emitted them would make the offset carried, and the probe must not
            // call that a failure.
            let carriesAnOffsetField = locations.domRange != nil || locations.partialCFI != nil
            if !namedByAFragment && !carriesAnOffsetField { unbacked += 1 }
        }

        // ---- (c) every dropped name is one the harness can explain ----
        //
        // This list is the point of the tripwire, not a formality: adding
        // `"fragments"` to the bridge's discard list in this same round is
        // exactly the change that would have made this probe report `no` with a
        // word nobody had defined.
        let explainable: Set<String> = [
            "title", "text", "href", "fragments", "cssSelector",
            "progression", "position", "progression.metric"
        ]
        var discardedNames = 0
        var unexplained: [String] = []
        for trip in roundTrips {
            for name in trip.discarded {
                discardedNames += 1
                if !explainable.contains(name) && !unexplained.contains(name) {
                    unexplained.append(name)
                }
            }
        }

        let honest = unrecordedMetric == 0 && perUnitMismatches == 0 && publicationLevelValues == 0
            && unbacked == 0 && unexplained.isEmpty
        // **Coverage, not just outcome.** The first run of this probe reported
        // `yes` while `carriedRows` was 0: every native-first row lost its offset
        // or had it rebuilt, so the carrier arm had nothing to check and passed
        // by having nothing to fail. The fixture now carries the missing row;
        // this guard is what stops it going quiet again.
        let decided = carriedRows > 0 && progressionRows > 0

        // Rendered outside the literal: three levels of nested interpolation is
        // more than this package is willing to bet a CI run on without a local
        // compiler to check it.
        let unexplainedText = unexplained.isEmpty ? "none" : unexplained.joined(separator: ", ")

        return try ProbeOutcome(
            name: "progress-provenance",
            question: "Does the artifact say where each number came from, and refuse to call a rebuilt value carried?",
            execution: decided ? .measured : .inconclusive,
            finding: decided ? (honest ? .yes : .no) : nil,
            detail: """
            (a) \(progressionRows) row(s) wrote into locations.progression: \(unrecordedMetric) without recording the dropped metric, \
            \(perUnitMismatches) not the per-resource fraction, \(publicationLevelValues) that are the publication-level number instead. \
            The first such row wrote \(decimal(writtenExample)) against a per-resource \(decimal(perUnitExample)) \
            and a publication-level \(decimal(publicationExample)) — the two candidates differ, which is what makes this checkable. \
            (b) \(carriedRows) of \(carriedRows + uncarriedRows) native-first rows call the offset carried; \(unbacked) of those have nothing in the locator that could have carried it. \
            unitID is excluded on purpose: locator(from:) builds the href from the unit and native(from:) reads it back to that same unit, so a verdict on it cannot vary — the defect the href field was deleted for, under another name. \
            (c) \(discardedNames) discarded name(s) across the census; names the harness cannot explain: \(unexplainedText). \
            Falsified by writing the publication-level fraction into the field, and by a generous carried — which is what reported native-path-anchored as exact.
            """,
            numbers: [
                "roundTrips": Double(roundTrips.count),
                "progressionRows": Double(progressionRows),
                "unrecordedMetric": Double(unrecordedMetric),
                "perUnitMismatches": Double(perUnitMismatches),
                "publicationLevelValues": Double(publicationLevelValues),
                "writtenProgression": writtenExample ?? 0,
                "perUnitProgression": perUnitExample ?? 0,
                "publicationProgression": publicationExample ?? 0,
                "nativeFirstRows": Double(nativeCases.count),
                "carriedOffsetRows": Double(carriedRows),
                "unbackedCarriedRows": Double(unbacked),
                "discardedNames": Double(discardedNames),
                "unexplainedNames": Double(unexplained.count)
            ]
        )
    }
}
