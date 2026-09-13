import Foundation
import SpikeKit

/// The reanchor contract measured rather than argued.
///
/// `internal`, and no new public API: the corpus and the probe belong to the
/// spike. `ReanchorService` stays public and is called through that surface
/// here, exactly as a caller would call it — this probe does not reach inside
/// it, and does not restate its algorithm.
///
/// **Every case is actually run.** The expected `ReanchorResult` is written out
/// in full, including both positions of the ambiguous case in order, so that
/// "ambiguous" cannot pass by returning the right shape with the wrong places
/// in it.
enum ReanchorPolicyProbe {

    /// One named case: a document, an anchor, and what re-anchoring must answer.
    struct PolicyCase {
        var name: String
        var document: Document
        var anchor: Anchor
        var expected: ReanchorResult
    }

    /// Raised when the probe cannot describe its own corpus.
    ///
    /// Both cases are defects in the probe, not findings about re-anchoring,
    /// and neither may be written into an artifact as though it were a
    /// measurement. Same rule as `RoundTripCensusError`.
    enum ReanchorPolicyError: Error, CustomStringConvertible {
        /// The buckets counted cannot add up to the corpus they counted.
        case bucketsDoNotSum(String)
        /// A corpus document is not the shape its own expectation assumes — an
        /// element or unit that the expected offset is derived from is absent.
        case corpusIsNotWhatItClaims(String)

        var description: String {
            switch self {
            case .bucketsDoNotSum(let explanation):
                return "the reanchor-policy probe cannot describe its own corpus: \(explanation)"
            case .corpusIsNotWhatItClaims(let explanation):
                return "the reanchor-policy corpus is not the document it claims to be: \(explanation)"
            }
        }
    }

    // MARK: - Building documents

    /// The fixture is Spike A's measurement subject and is not touched. These
    /// probe documents are built here, so every string an offset is derived
    /// from lives beside the expectation that uses it.
    private static func document(_ bodies: [(id: String, body: String)]) throws -> Document {
        var units: [DocumentUnit] = []
        for entry in bodies {
            let xhtml = """
            <?xml version="1.0" encoding="utf-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml">
            <head><title>t</title></head>
            <body>
            \(entry.body)
            </body>
            </html>
            """
            let canonical = try XHTMLToCanonical.build(from: xhtml)
            units.append(DocumentUnit(
                id: entry.id,
                href: entry.id,
                mediaType: "application/xhtml+xml",
                canonical: canonical
            ))
        }
        return Document(readingOrder: units)
    }

    /// The unit a case's expectation is derived from, read back out of the
    /// document that was just built.
    private static func unit(_ id: String, in document: Document) throws -> DocumentUnit {
        guard let found = document.unit(withID: id) else {
            throw ReanchorPolicyError.corpusIsNotWhatItClaims("the corpus has no unit \(id)")
        }
        return found
    }

    /// The element a case's expected offset is derived from. Reading it back
    /// rather than restating its position in the source is the point: an
    /// expectation built from the element's own range cannot go stale when the
    /// body string changes.
    private static func element(_ id: String, in unit: DocumentUnit) throws -> CanonicalText.Element {
        guard let found = unit.canonical.element(withID: id) else {
            throw ReanchorPolicyError.corpusIsNotWhatItClaims("unit \(unit.id) has no element \(id)")
        }
        return found
    }

    // MARK: - The corpus

    /// Six cases, each a different reason for the answer to be what it is.
    ///
    /// Offsets are derived — `inserted.utf16.count`, a prefix's own
    /// `utf16.count` — never recalled. `0` appears only for "the start of the
    /// text", which is not a measurement of anything.
    static func corpus() throws -> [PolicyCase] {
        var cases: [PolicyCase] = []

        // (a) The stored position still holds, and the quote repeats elsewhere.
        // Which of the two it lands on is the whole question.
        let repeatedQuote = try document([(id: "u1", body: "<p id=\"a\">target</p><p id=\"b\">target</p>")])
        cases.append(PolicyCase(
            name: "original-position-still-holds-over-a-repeat",
            document: repeatedQuote,
            anchor: Anchor(
                position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
                quote: AnchorQuote(exact: "target")
            ),
            expected: .relocated(
                NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
                method: .originalPosition
            )
        ))

        // (b) An insertion in front invalidates the offset, and there is exactly
        // one occurrence in the whole reading order to find instead.
        let inserted = "XXX"
        let shiftedQuote = try document([(id: "u1", body: "<p id=\"a\">\(inserted)target</p>")])
        cases.append(PolicyCase(
            name: "insertion-before-the-quote-moves-the-offset",
            document: shiftedQuote,
            anchor: Anchor(
                position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
                quote: AnchorQuote(exact: "target")
            ),
            expected: .relocated(
                NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: inserted.utf16.count),
                method: .uniqueExactQuote
            )
        ))

        // (c) Two occurrences, and a complete non-empty prefix **and** suffix
        // that only one of them sits inside.
        //
        // **The expected offsets come from the elements, not from a restated
        // span of the document.** Each occurrence's place is its element's own
        // `utf16Range.lowerBound` plus the prefix text local to that element.
        // Writing the second occurrence's offset as the length of the whole
        // string in front of it would work today and would quietly keep working
        // after the body changed — which is the failure mode, not the fix.
        let firstPrefix = "alpha "
        let secondLocalPrefix = "beta "
        let disambiguated = try document([
            (id: "u1", body: "<p id=\"a\">\(firstPrefix)target omega</p><p id=\"b\">\(secondLocalPrefix)target psi</p>")
        ])
        let disambiguatedUnit = try unit("u1", in: disambiguated)
        let firstElement = try element("a", in: disambiguatedUnit)
        let secondElement = try element("b", in: disambiguatedUnit)
        let firstOffset = firstElement.utf16Range.lowerBound + firstPrefix.utf16.count
        let secondOffset = secondElement.utf16Range.lowerBound + secondLocalPrefix.utf16.count

        cases.append(PolicyCase(
            name: "complete-context-separates-two-identical-quotes",
            document: disambiguated,
            anchor: Anchor(
                position: nil,
                quote: AnchorQuote(exact: "target", prefix: firstPrefix, suffix: " omega")
            ),
            expected: .relocated(
                NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: firstOffset),
                method: .quoteContext
            )
        ))

        // (d) The same two occurrences with nothing to separate them. Both
        // positions are in the expectation, in reading order — an answer that
        // returned two plausible positions in the wrong order, or the right two
        // with the wrong nodes, would be a different answer.
        cases.append(PolicyCase(
            name: "two-identical-quotes-with-no-context-are-ambiguous",
            document: disambiguated,
            anchor: Anchor(position: nil, quote: AnchorQuote(exact: "target")),
            expected: .ambiguous([
                NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: firstOffset),
                NativePosition(unitID: "u1", nodeID: .explicitID("b"), utf16Offset: secondOffset)
            ])
        ))

        // (e) An empty quote with a position that is genuinely still valid. This
        // is the precedence case: no quote is not a confirmation, and the
        // position does not get to answer in its place.
        let emptyQuote = try document([(id: "u1", body: "<p id=\"a\">target</p>")])
        cases.append(PolicyCase(
            name: "empty-quote-outranks-a-still-valid-position",
            document: emptyQuote,
            anchor: Anchor(
                position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
                quote: AnchorQuote(exact: "")
            ),
            expected: .notFound(.emptyQuote)
        ))

        // (f) The quote is not in the text at all.
        let goneQuote = try document([(id: "u1", body: "<p id=\"a\">the text moved on</p>")])
        cases.append(PolicyCase(
            name: "a-quote-that-is-not-there-is-missing",
            document: goneQuote,
            anchor: Anchor(
                position: NativePosition(unitID: "u1", nodeID: .explicitID("a"), utf16Offset: 0),
                quote: AnchorQuote(exact: "target")
            ),
            expected: .notFound(.exactTextMissing)
        ))

        return cases
    }

    // MARK: - The probe

    static func run() async throws -> ProbeOutcome {
        let cases = try corpus()

        var mismatches: [String] = []
        var relocated = 0
        var ambiguous = 0
        var notFound = 0
        var methodOriginalPosition = 0
        var methodUniqueExactQuote = 0
        var methodQuoteContext = 0
        var reasonEmptyQuote = 0
        var reasonExactTextMissing = 0

        for policyCase in cases {
            let actual = try await ReanchorService.reanchor(policyCase.anchor, in: policyCase.document)

            // **One exhaustive `switch`, not a chain of independent `if case`s.**
            // Predicates cannot see a case that matches none of them: the row
            // would vanish from every bucket at once and the totals below would
            // still be compared against a corpus that no longer reaches them.
            // A new `ReanchorResult` case is a compile error here instead.
            switch actual {
            case .relocated(_, let method):
                relocated += 1
                switch method {
                case .originalPosition: methodOriginalPosition += 1
                case .uniqueExactQuote: methodUniqueExactQuote += 1
                case .quoteContext: methodQuoteContext += 1
                }
            case .ambiguous:
                ambiguous += 1
            case .notFound(let reason):
                notFound += 1
                switch reason {
                case .emptyQuote: reasonEmptyQuote += 1
                case .exactTextMissing: reasonExactTextMissing += 1
                }
            }

            if actual != policyCase.expected {
                mismatches.append(policyCase.name)
            }
        }

        // The bucket sums are checked, not assumed. A probe whose own numbers
        // contradict each other is a defect in the probe and throws here rather
        // than writing the contradiction into an artifact.
        let counted = relocated + ambiguous + notFound
        guard counted == cases.count else {
            throw ReanchorPolicyError.bucketsDoNotSum(
                "outcome buckets counted \(counted) rows but the corpus has \(cases.count)"
            )
        }
        let methodTotal = methodOriginalPosition + methodUniqueExactQuote + methodQuoteContext
        guard methodTotal == relocated else {
            throw ReanchorPolicyError.bucketsDoNotSum(
                "the three method buckets sum to \(methodTotal) but \(relocated) cases relocated"
            )
        }
        let reasonTotal = reasonEmptyQuote + reasonExactTextMissing
        guard reasonTotal == notFound else {
            throw ReanchorPolicyError.bucketsDoNotSum(
                "the two reason buckets sum to \(reasonTotal) but \(notFound) cases were not found"
            )
        }

        // **The evidence is the scarcest discriminating leaf**, not the number
        // of cases run. Reporting six cases as evidence while one of the six
        // branches was never reached is exactly the vacuous pass this repo has
        // been bitten by: a `yes` that had nothing it could have failed.
        let evidenceCount = min(
            methodOriginalPosition,
            methodUniqueExactQuote,
            methodQuoteContext,
            ambiguous,
            reasonEmptyQuote,
            reasonExactTextMissing
        )
        let (execution, finding) = ProbeEvidence.conclude(
            observed: evidenceCount,
            violations: mismatches.count
        )

        // Deterministic prose only. No dictionary description, no host, no run
        // metadata — the artifact is compared across processes and machines.
        //
        // **Coverage is decided before agreement, and the order is the fix.**
        // "Nothing disagreed" and "every leaf was reached" are different claims
        // that coincide only on a healthy reading: when a leaf is never reached
        // there is nothing left to disagree with, so a detail branching on
        // mismatches alone announces full coverage over an incomplete corpus.
        // The execution state already knows the difference — `evidenceCount ==
        // 0` makes it `inconclusive` — and this branch has to agree with it
        // rather than narrate past it.
        let headline = "\(cases.count) cases: \(relocated) relocated, \(ambiguous) ambiguous, \(notFound) not found"
        let mismatchClause = mismatches.isEmpty
            ? ""
            : ". \(mismatches.count) did not answer as ADR-0012 requires, in corpus order: "
                + mismatches.joined(separator: ", ") + "."

        let detail: String
        if evidenceCount == 0 {
            detail = headline
                + ". Inconclusive: at least one of the six discriminating leaves was never reached,"
                + " so an empty bucket here is absence of evidence rather than evidence of absence."
                + mismatchClause
        } else if mismatches.isEmpty {
            detail = headline
                + ". Every answer matched ADR-0012, and all six discriminating leaves were reached,"
                + " so no bucket here is passing by being empty."
        } else {
            detail = headline + mismatchClause
        }

        return try ProbeOutcome(
            name: "reanchor-policy",
            // Scoped to what this corpus actually reaches. It is not "every
            // boundary shape ADR-0012 names" — it is all three outcomes, all
            // three methods and both reasons, which is what six cases can
            // distinguish. A question wider than its corpus is the same defect
            // as a `yes` that had nothing it could have failed.
            question: "Does re-anchoring produce the outcome, method and reason ADR-0012 specifies for each case in this corpus?",
            execution: execution,
            finding: finding,
            detail: detail,
            numbers: [
                "cases": Double(cases.count),
                "relocated": Double(relocated),
                "ambiguous": Double(ambiguous),
                "notFound": Double(notFound),
                "methodOriginalPosition": Double(methodOriginalPosition),
                "methodUniqueExactQuote": Double(methodUniqueExactQuote),
                "methodQuoteContext": Double(methodQuoteContext),
                "reasonEmptyQuote": Double(reasonEmptyQuote),
                "reasonExactTextMissing": Double(reasonExactTextMissing),
                "evidenceCount": Double(evidenceCount),
                "mismatches": Double(mismatches.count)
            ]
        )
    }
}
