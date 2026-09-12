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
    case .requiresValidator: return "needs validator"
    case .requiresReanchor: return "needs reanchor"
    }
}

func line(_ character: Character = "-", count: Int = 78) -> String {
    String(repeating: character, count: count)
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

let outputDirectory = parseOutputDirectory()

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    let report = try SpikeA.run(
        outputDirectory: outputDirectory,
        expectedFingerprint: parseExpectedFingerprint()
    )
    try report.write(to: outputDirectory)

    print(line("="))
    print("SPIKE A — Locator <-> Native Position identity")
    print(line("="))
    print("fixture      \(report.fixtureName)  (\(report.canonicalTextUTF16Length) UTF-16 units, sha256 \(report.canonicalTextSHA256.prefix(12))…)")
    for document in report.documents {
        print(
            pad("  \(document.href)", 34)
                + pad("\(document.utf16Length) units", 14)
                + "\(document.elementCount) elements, \(document.explicitIDCount) with ids"
        )
    }
    print("")

    print(line())
    print(pad("PROBE", 26) + pad("EXECUTION", 14) + pad("FINDING", 10) + "DETAIL")
    print(line())
    for probe in report.probes {
        print(
            pad(probe.name, 26)
                + pad(marker(for: probe.execution), 14)
                + pad(findingLabel(probe.finding), 10)
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
    for trip in report.roundTrips {
        print(pad(trip.name, 52) + outcomeLabel(trip.outcome))
        if case .recomputedEquivalent(let notes) = trip.outcome {
            for note in notes { print("      · \(note)") }
        }
        if case .semanticEquivalent(let notes) = trip.outcome {
            for note in notes { print("      · \(note)") }
        }
        if case .loses(let fields) = trip.outcome {
            print("      · dropped: \(fields.joined(separator: ", "))")
        }
        if case .requiresValidator(let reason) = trip.outcome {
            print("      · \(reason)")
        }
        if case .requiresReanchor(let reason) = trip.outcome {
            print("      · \(reason)")
        }
    }
    print("")
    print(line())
    print("IDENTITY")
    print(line())
    print("needs a validator   \(report.roundTrips.filter(\.needsValidator).count) of \(report.roundTrips.count) cases")
    print("  A Native Position is a coordinate. It has nowhere to keep the quotation that")
    print("  justified it, so no conversion through one can confirm it still names the same")
    print("  content. That is AnchorValidator's job, and this is the count that proves it.")
    print("")
    print("needs a reanchor    \(report.roundTrips.filter(\.needsReanchor).count) of \(report.roundTrips.count) cases")
    print("  These are the conversions that cannot be made from structure at all — the only")
    print("  way back is fuzzy text matching, which is ReanchorService's job.")
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
    print(pad("canonical-text.txt", 26) + "\(report.artifacts.canonicalText.byteCount) bytes")
    print(pad("\(report.spike).fingerprint", 26) + "\(report.artifacts.fingerprint.byteCount) bytes")
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
