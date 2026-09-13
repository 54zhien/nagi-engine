import Foundation
import SpikeKit
import SpikeAKit

// Spike A — can Nagi keep a reading position's identity across a round trip?
//
// Prints a human-readable table to stdout (which lands in the CI log, where it
// can actually be read) and writes the machine-readable report plus a canonical
// text transcript to the output directory.
//
//   --out <dir>       where the artifacts go (default ./.artifacts)
//   --expect <file>   a .fingerprint file from an earlier run; supplying one is
//                     what turns the determinism check into a cross-process one

func parseOutputDirectory() -> URL {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--out"), index + 1 < arguments.count {
        return URL(fileURLWithPath: arguments[index + 1])
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".artifacts")
}

func parseExpectedFingerprint() -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: "--expect"), index + 1 < arguments.count else {
        return nil
    }
    guard let contents = try? String(contentsOfFile: arguments[index + 1], encoding: .utf8) else {
        FileHandle.standardError.write(
            Data("warning: could not read --expect \(arguments[index + 1]); comparing nothing\n".utf8)
        )
        return nil
    }
    return contents.trimmingCharacters(in: .whitespacesAndNewlines)
}

func marker(for execution: ProbeOutcome.Execution) -> String {
    switch execution {
    case .measured: return "MEASURED"
    case .inconclusive: return "INCONCLUSIVE"
    case .unsupported: return "UNSUPPORTED"
    }
}

func findingLabel(_ finding: ProbeOutcome.Finding?) -> String {
    switch finding {
    case .yes: return "yes"
    case .no: return "no"
    case nil: return "—"
    }
}

func outcomeLabel(_ outcome: RoundTripOutcome) -> String {
    switch outcome {
    case .exact: return "exact"
    case .recomputedEquivalent: return "recomputed"
    case .semanticEquivalent: return "semantic"
    case .loses: return "loses fields"
    case .requiresReanchor: return "needs reanchor"
    }
}

func line(_ character: Character = "-", count: Int = 78) -> String {
    String(repeating: character, count: count)
}

// `terminalColumn` and `columnWidth` now live in `SpikeKit/TerminalColumns.swift`,
// shared with Spike B, which had the same defect in its own copy.

let outputDirectory = parseOutputDirectory()

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    // `await` because `SpikeA.run` is `async` since R2: the reanchor-policy
    // probe calls into `ReanchorService`, whose production boundary has to be
    // async. Top-level `await` in `main.swift` is Swift 5.5+; whether this
    // exact spot compiles is for CI to say, since there is no toolchain here.
    let report = try await SpikeA.run(
        outputDirectory: outputDirectory,
        expectedFingerprint: parseExpectedFingerprint()
    )
    try report.write(to: outputDirectory)

    print(line("="))
    print("SPIKE A — Locator <-> Native Position identity")
    print(line("="))
    print("fixture      \(report.fixtureName)  (sha256 \(report.canonicalTextSHA256.prefix(12))…)")
    // Two lengths, deliberately both stated. The first is the transcript
    // artifact, which joins the units with a separator; the second is what the
    // canonicalTextIndex metric divides by. Printing only the first used to
    // state a length that no measurement used.
    print("transcript   \(report.canonicalTextUTF16Length) UTF-16 units (units joined by a separator)")
    print("readingOrder \(report.readingOrderUTF16Length) UTF-16 units (the canonicalTextIndex denominator)")
    // Both cells here come from the report, so both columns are measured.
    // `document.href` carries a two-space indent and a filename that a real
    // manifest will make longer than this fixture's.
    let documentHrefWidth = columnWidth(34, report.documents.map { "  \($0.href)" })
    let documentLengthWidth = columnWidth(14, report.documents.map { "\($0.utf16Length) units" })
    for document in report.documents {
        print(
            terminalColumn("  \(document.href)", documentHrefWidth)
                + terminalColumn("\(document.utf16Length) units", documentLengthWidth)
                + "\(document.elementCount) elements, \(document.explicitIDCount) with ids"
        )
    }
    print("")

    print(line())
    // The name column is measured because a probe name is data. EXECUTION and
    // FINDING are closed — `marker` returns one of three literals, `findingLabel`
    // one of three — so their widths stay constants, and they still go through
    // `terminalColumn` so that a closed set which grows later cannot silently
    // collide.
    let probeNameWidth = columnWidth(26, report.probes.map(\.name) + ["PROBE"])
    print(
        terminalColumn("PROBE", probeNameWidth)
            + terminalColumn("EXECUTION", 14)
            + terminalColumn("FINDING", 10)
            + "DETAIL"
    )
    print(line())
    for probe in report.probes {
        print(
            terminalColumn(probe.name, probeNameWidth)
                + terminalColumn(marker(for: probe.execution), 14)
                + terminalColumn(findingLabel(probe.finding), 10)
        )
        print("    Q  \(probe.question)")
        print("    A  \(probe.detail)")
        if !probe.numbers.isEmpty {
            let rendered = probe.numbers
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value == $0.value.rounded() ? String(Int($0.value)) : String($0.value))" }
                .joined(separator: "  ")
            print("    N  \(rendered)")
        }
        print("")
    }

    print(line())
    print("ROUND TRIPS")
    print(line())
    // Measured, not declared. Three of these columns were over their declared
    // width: `tasks/todo.md` recorded two of them, and the longest value in the
    // table — a row name — is one nobody had written down.
    //
    // **No lengths are quoted here on purpose.** A row name is its label plus a
    // fixed suffix, and an href is an href; both change the moment a case or a
    // fixture is added, so any literal in this comment would be a constant
    // written from memory rather than an invariant — the rule in
    // `tasks/lessons.md`. The measurement needs nobody to notice anything.
    let everyField = report.roundTrips.flatMap(\.transportResolutions)
    let tripNameWidth = columnWidth(52, report.roundTrips.map(\.name))
    let fieldWidth = columnWidth(22, everyField.map(\.field.described))
    let originalWidth = columnWidth(14, everyField.map { $0.original ?? "—" })
    let resolvedWidth = columnWidth(14, everyField.map { $0.resolved ?? "—" })
    for trip in report.roundTrips {
        print(terminalColumn(trip.name, tripNameWidth) + outcomeLabel(trip.outcome))
        // The field table: one row per field the **input** stated, saying what
        // it said, what came back, and what happened in between. **The two
        // values are for a reader** — nothing derives a verdict from them; the
        // verdict comes from the provenance in the last column, which is all the
        // reducer ever sees.
        for entry in trip.transportResolutions {
            print(
                "      "
                    + terminalColumn(entry.field.described, fieldWidth)
                    + terminalColumn(entry.original ?? "—", originalWidth)
                    + terminalColumn(entry.resolved ?? "—", resolvedWidth)
                    + entry.provenance.described
            )
        }
        // Facts about the **bridge**, not verdicts on the input's fields. Marked
        // `~` and kept below the table: they were once rows in it, and a row
        // reading `refused` for a field the input never stated is what made
        // `exact` look like a contradiction of a row's own table.
        for observation in trip.observations {
            print("      ~ \(observation.described)")
        }
        if case .recomputedEquivalent(let notes) = trip.outcome {
            for note in notes { print("      · \(note)") }
        }
        if case .semanticEquivalent(let notes) = trip.outcome {
            for note in notes { print("      · \(note)") }
        }
        if case .loses(let fields) = trip.outcome {
            print("      · dropped: \(fields.joined(separator: ", "))")
        }
        if case .requiresReanchor(let reason) = trip.outcome {
            print("      · \(reason)")
        }
    }
    print("")
    print(line())
    print("IDENTITY")
    print(line())
    // **Two lines, because there are two questions and the flags do not nest.**
    // This used to print one number — "needs a validator: 20 of 20" — which was
    // true by construction rather than by measurement: `refused` set the flag
    // unconditionally, so rows that resolved to nothing claimed a validator's
    // work to do when they had nothing to hand one.
    print("\(report.roundTrips.count) cases")
    print("produced a candidate   \(report.roundTrips.filter(\.needsValidator).count)")
    print("  Either one position came back and something has to confirm it still names the")
    print("  same content, or several did and something has to choose between them. A Native")
    print("  Position is a coordinate, and a coordinate has nowhere to keep the quotation")
    print("  that justified it — that is AnchorValidator's job, and this is what proves it.")
    print("")
    print("produced no position   \(report.roundTrips.filter(\.needsReanchor).count)")
    print("  These cannot be made from structure at all, so a validator has nothing to")
    print("  validate and the only way back is fuzzy text matching — ReanchorService's job.")
    print("")
    print("  One row is in both lists on purpose: the ambiguous locator produced candidates")
    print("  to choose between and no single position to confirm.")
    print("")

    print(line())
    print("DETERMINISM")
    print(line())
    print("fingerprint  \(report.determinism.fingerprint)")
    print("expected     \(report.determinism.expectedFingerprint ?? "(none supplied)")")
    print("execution    \(marker(for: report.determinism.execution))")
    print("finding      \(findingLabel(report.determinism.finding))")
    print("             \(report.determinism.detail)")
    print("")

    print(line())
    print("ARTIFACTS")
    print(line())
    // Closed: both names are literals written here, so the width stays a
    // constant — but it still goes through `terminalColumn`.
    print(terminalColumn("canonical-text.txt", 26) + "\(report.artifacts.canonicalText.byteCount) bytes")
    print(terminalColumn("\(report.spike).fingerprint", 26) + "\(report.artifacts.fingerprint.byteCount) bytes")
    print("")
    print("artifacts written to \(outputDirectory.path)")
    print("  \(report.spike).json        machine gate — quantized, no run metadata")
    print("  \(report.spike).fingerprint canonical payload hash — compare across runs")
    print("  canonical-text.txt  human review — the texts the offsets index")

    let negatives = report.probes.filter { $0.finding == .no }
    let undecided = report.probes.filter { $0.execution != .measured }
    if !negatives.isEmpty || !undecided.isEmpty {
        print("")
        if !negatives.isEmpty {
            print("\(negatives.count) probe(s) came back \"no\" — a result about the subject, not a build break.")
        }
        if !undecided.isEmpty {
            print("\(undecided.count) probe(s) could not conclude — their measurements would have been vacuous.")
        }
        print("Read the detail lines above before changing anything.")
    }
    // Probes are diagnostic, not gates. Exiting non-zero here would train us to
    // ignore red CI, which is the failure mode ADR-0011 warns about.
    exit(0)
} catch {
    FileHandle.standardError.write(Data("spike-a failed: \(error)\n".utf8))
    exit(1)
}
