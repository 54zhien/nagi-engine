import Foundation
import SpikeKit

/// The artifact, under the same rules Spike B settled on (ADR-0011):
/// quantized floats, no timestamps, no run identifiers, no output paths, and a
/// fingerprint that covers only the deterministic payload.
public struct SpikeAReport: Codable, Sendable {
    public var spike: String
    public var fixtureName: String
    public var canonicalTextSHA256: String
    public var canonicalTextUTF16Length: Int
    public var documents: [DocumentSummary]
    public var probes: [ProbeOutcome]
    public var roundTrips: [RoundTrip]
    public var artifacts: SpikeAArtifacts
    public var determinism: DeterminismRecord

    public init(
        spike: String,
        fixtureName: String,
        canonicalTextSHA256: String,
        canonicalTextUTF16Length: Int,
        documents: [DocumentSummary],
        probes: [ProbeOutcome],
        roundTrips: [RoundTrip],
        artifacts: SpikeAArtifacts,
        determinism: DeterminismRecord
    ) {
        self.spike = spike
        self.fixtureName = fixtureName
        self.canonicalTextSHA256 = canonicalTextSHA256
        self.canonicalTextUTF16Length = canonicalTextUTF16Length
        self.documents = documents
        self.probes = probes
        self.roundTrips = roundTrips
        self.artifacts = artifacts
        self.determinism = determinism
    }

    /// Everything a gate may compare, and nothing ambient. Artifact byte counts
    /// and the determinism record stay out, for the same two reasons as Spike B:
    /// a file-size change must not be able to fail a metric gate, and a
    /// self-referential comparison must not sit inside the thing it compares.
    public func canonicalPayload() -> SpikeACanonicalPayload {
        SpikeACanonicalPayload(
            spike: spike,
            fixtureName: fixtureName,
            canonicalTextSHA256: canonicalTextSHA256,
            canonicalTextUTF16Length: canonicalTextUTF16Length,
            documents: documents,
            probes: probes,
            roundTrips: roundTrips
        )
    }

    public func canonicalFingerprint() throws -> String {
        try Fingerprint.of(canonicalPayload())
    }
}

extension SpikeAReport {
    /// The same encoder settings Spike B settled on (`.prettyPrinted` +
    /// `.sortedKeys`), so a golden diff stays readable without a JSON tool.
    ///
    /// Written here rather than added to `ReportIO` because that writer takes
    /// `SpikeReport` by type, and generalising it would mean editing Spike B's
    /// file — which this round deliberately does not do.
    public func write(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("\(spike).json"))
    }
}

public struct SpikeACanonicalPayload: Codable, Sendable {
    public var spike: String
    public var fixtureName: String
    public var canonicalTextSHA256: String
    public var canonicalTextUTF16Length: Int
    public var documents: [DocumentSummary]
    public var probes: [ProbeOutcome]
    public var roundTrips: [RoundTrip]
}

public struct DocumentSummary: Codable, Sendable, Hashable {
    public var id: String
    public var href: String
    public var utf16Length: Int
    public var elementCount: Int
    public var explicitIDCount: Int
}

/// Spike A writes no pixels, so it does not reuse `ArtifactManifest` — that type
/// is Spike B's shape, down to its three PNG field names. `ArtifactRecord`
/// itself is general (`written` + `byteCount`), and is reused as-is.
public struct SpikeAArtifacts: Codable, Sendable {
    public var canonicalText: ArtifactRecord
    public var fingerprint: ArtifactRecord

    public init(canonicalText: ArtifactRecord, fingerprint: ArtifactRecord) {
        self.canonicalText = canonicalText
        self.fingerprint = fingerprint
    }
}

/// The same recipe Spike B uses for `SpikeReport.canonicalFingerprint`, lifted
/// so both spikes share one definition of "deterministic payload".
///
/// It lives here rather than in `SpikeKit` on purpose: Spike B is sealed, and
/// reaching into it to lift four lines would disturb a verified artifact for a
/// tidiness gain. When a third spike appears, this is one of the things that
/// should move to a shared kit alongside it.
public enum Fingerprint {
    public static func of<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hex(try encoder.encode(payload))
    }
}
