import Foundation
import SpikeKit

// Spike B — is CoreText a controllable typography backend for Nagi?
//
// Prints a human-readable table to stdout (which lands in the CI log, where it
// can actually be read) and writes the machine-readable report plus review
// images to the output directory.
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

/// Whether the probe managed to measure. There is deliberately no "FAIL" in
/// this vocabulary: a probe that could not run throws and never reaches the log.
func marker(for execution: ProbeOutcome.Execution) -> String {
    switch execution {
    case .measured: return "MEASURED"
    case .inconclusive: return "INCONCLUSIVE"
    case .unsupported: return "UNSUPPORTED"
    }
}

/// What the measurement said, in lowercase on purpose. `no` here is a result
/// about the subject under test — the font genuinely lacking `halt` is the whole
/// point of the census — and spelling it `FAIL` is how a CI log stops being
/// readable.
func findingLabel(_ finding: ProbeOutcome.Finding?) -> String {
    switch finding {
    case .yes: return "yes"
    case .no: return "no"
    case nil: return "—"
    }
}

func line(_ character: Character = "-", count: Int = 78) -> String {
    String(repeating: character, count: count)
}

// `terminalColumn` and `columnWidth` live in `SpikeKit/TerminalColumns.swift`,
// shared with Spike A. This file used to carry its own copy, whose doc comment
// said "left-pads" while the code right-pads — and whose declared widths let
// three probe names run into the column after them.

func fixed(_ value: Double, _ decimals: Int = 3) -> String {
    String(format: "%.\(decimals)f", value)
}

let outputDirectory = parseOutputDirectory()

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

    // Module-qualified: this file's own target is named SpikeB, so the bare
    // name is ambiguous between the module and SpikeKit's SpikeB type.
    let report = try SpikeKit.SpikeB.run(
        outputDirectory: outputDirectory,
        expectedFingerprint: parseExpectedFingerprint()
    )
    try ReportIO.write(report, to: outputDirectory)
    try ReportIO.writeFingerprint(
        report.determinism.fingerprint,
        for: report.spike,
        to: outputDirectory
    )

    print(line("="))
    print("SPIKE B — CoreText as a typography backend")
    print(line("="))
    print("fixture      \(report.fixtureName)  (\(report.canonicalTextUTF16Length) UTF-16 units, sha256 \(report.canonicalTextSHA256.prefix(12))…)")
    print("font         \(report.fontPostScriptName)  sha256 \(report.fontSHA256.prefix(12))…")
    for summary in report.fontFeatureSummary {
        print("             \(summary)")
    }
    print("coverage     \(report.glyphCoverage.missingCharacters) missing of \(report.glyphCoverage.testedCharacters) tested")
    if report.glyphCoverage.missingCharacters > 0 {
        print("             \(report.glyphCoverage.missingScalars.joined(separator: " "))")
    }
    print("")

    print(line())
    // Measured, not declared. Three of this table's seven probe names are at or
    // over the 24 written here before, and a name exactly as long as its column
    // gets no separating space from `pad` — the CI log read
    // `kinsoku-baseline-behaviorMEASURED`.
    let probeNameWidth = columnWidth(24, report.probes.map(\.name) + ["PROBE"])
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
                .map { "\($0.key)=\(fixed($0.value))" }
                .joined(separator: "  ")
            print("    N  \(rendered)")
        }
        print("")
    }

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
    print(terminalColumn("page-0.png", 26) + "\(report.artifacts.pagePNG.byteCount) bytes")
    print(terminalColumn("vertical-column-0.png", 26) + "\(report.artifacts.verticalColumnPNG.byteCount) bytes")
    print(terminalColumn("ruby.png", 26) + "\(report.artifacts.rubyPNG.byteCount) bytes")
    print("")

    print(line())
    print("LAYOUTS")
    print(line())
    // Measured for the same reason the probe table is: these cells come from the
    // report, so a longer label or a three-digit count would collide. The
    // artifacts table above keeps its constants on purpose — its cells are
    // literals written in the same `print`, so measuring them would only
    // reproduce the constant printed beside them.
    let layoutLabelWidth = columnWidth(18, report.layouts.map(\.label))
    let lineCountWidth = columnWidth(12, report.layouts.map { "\($0.lineCount) lines" })
    let pageCountWidth = columnWidth(12, report.layouts.map { "\($0.pageCount) pages" })
    for layout in report.layouts {
        print(
            terminalColumn(layout.label, layoutLabelWidth)
                + terminalColumn("\(layout.lineCount) lines", lineCountWidth)
                + terminalColumn("\(layout.pageCount) pages", pageCountWidth)
                + "measure=\(fixed(layout.measureWidth, 0))pt  page=\(fixed(layout.pageHeight, 0))pt"
        )
    }
    print("")

    print("artifacts written to \(outputDirectory.path)")
    print("  \(report.spike).json        machine gate — quantized, no run metadata")
    print("  \(report.spike).fingerprint canonical payload hash — compare across runs")
    print("  page-0.png          human review — horizontal page")
    print("  vertical-column-0.png  human review — vertical column")
    print("  ruby.png            human review — ruby line box")

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
    FileHandle.standardError.write(Data("spike-b failed: \(error)\n".utf8))
    exit(1)
}
