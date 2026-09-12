import Foundation

/// Direct sfnt table-directory parsing.
///
/// This exists because the obvious CoreText route — `CTFontCopyFeatures` — is
/// AAT-oriented and returns nil for many OpenType-only fonts, so it cannot
/// answer the question we actually have:
///
///   Does this font carry the features we intend to rely on?
///   (`halt` / `palt` for punctuation compression, `vert` / `vrt2` for vertical)
///
/// Reading the table directory and the GSUB/GPOS feature lists is unambiguous,
/// deterministic, and independent of OS text-stack behaviour — which also makes
/// it safe to put in a golden report.
public struct FontTableReport: Sendable {
    public var sfntVersion: String
    /// Sorted table tags, e.g. ["cmap", "GSUB", "glyf", "head", "vhea", "vmtx", ...]
    public var tables: [String]
    /// Sorted OpenType feature tags from GSUB's FeatureList.
    public var gsubFeatures: [String]
    /// Sorted OpenType feature tags from GPOS's FeatureList.
    public var gposFeatures: [String]

    public var hasVerticalMetrics: Bool {
        tables.contains("vhea") && tables.contains("vmtx")
    }

    /// Feature tags the engine currently intends to rely on, and their presence.
    public var featureAvailability: [String: Bool] {
        let all = Set(gsubFeatures).union(gposFeatures)
        var result: [String: Bool] = [:]
        for tag in ["vert", "vrt2", "halt", "palt", "vhal", "vpal", "kern", "locl", "pwid", "hwid", "twid"] {
            result[tag] = all.contains(tag)
        }
        return result
    }
}

enum FontParseError: Error {
    case outOfBounds(relativeOffset: Int, length: Int, available: Int)
}

/// A bounded window onto the font file.
///
/// Every offset in sfnt is relative to the structure that declares it, so the
/// only correct way to read one is inside its owning slice. Keeping the bounds
/// check here rather than at each call site is what makes this safe: a corrupt
/// file can easily produce an offset that has escaped its table while still
/// landing inside the file, and a file-bounded check would happily read a
/// neighbouring table's bytes and call that a successful parse.
///
/// This is an internal seam, not part of the module's interface — callers still
/// cross `FontTables.parse(_:)`, which returns nil rather than throwing.
struct ByteSlice {
    let data: Data
    let range: Range<Int>

    var count: Int { range.count }

    func readUInt16(at relativeOffset: Int) throws -> UInt16 {
        let window = try absolute(relativeOffset, length: 2)
        return UInt16(data[window.lowerBound]) << 8 | UInt16(data[window.lowerBound + 1])
    }

    func readUInt32(at relativeOffset: Int) throws -> UInt32 {
        let window = try absolute(relativeOffset, length: 4)
        let base = window.lowerBound
        return UInt32(data[base]) << 24
            | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8
            | UInt32(data[base + 3])
    }

    func subSlice(at relativeOffset: Int, length: Int) throws -> ByteSlice {
        ByteSlice(data: data, range: try absolute(relativeOffset, length: length))
    }

    /// Bytes that are not ASCII have no tag spelling; "????" is the placeholder
    /// rather than a failure, so a single odd record cannot hide the rest of the
    /// directory. Out-of-bounds is still a failure.
    func asciiTag(at relativeOffset: Int) throws -> String {
        let window = try absolute(relativeOffset, length: 4)
        return String(data: data[window], encoding: .ascii) ?? "????"
    }

    private func absolute(_ relativeOffset: Int, length: Int) throws -> Range<Int> {
        // `length <= count - relativeOffset` rather than `relativeOffset + length
        // <= count`, so a hostile length cannot overflow the addition.
        guard relativeOffset >= 0, length >= 0,
              relativeOffset <= count, length <= count - relativeOffset
        else {
            throw FontParseError.outOfBounds(
                relativeOffset: relativeOffset,
                length: length,
                available: count
            )
        }
        let lower = range.lowerBound + relativeOffset
        return lower..<(lower + length)
    }
}

public enum FontTables {
    public static func parse(_ data: Data) -> FontTableReport? {
        let file = ByteSlice(data: data, range: 0..<data.count)
        guard file.count >= 12, let version = try? file.readUInt32(at: 0) else { return nil }

        let versionString: String
        switch version {
        case 0x0001_0000: versionString = "1.0"
        case 0x4F54_544F: versionString = "OTTO (CFF)"
        case 0x7472_7565: versionString = "true"
        case 0x7474_6366: versionString = "ttcf (collection)"
        default: versionString = String(format: "0x%08X", version)
        }

        // Font collections need a different header layout; report and stop
        // rather than misparse. A TTC would also change how we register it.
        guard version != 0x7474_6366 else {
            return FontTableReport(
                sfntVersion: versionString,
                tables: [], gsubFeatures: [], gposFeatures: []
            )
        }

        guard let numTables = try? file.readUInt16(at: 4), numTables > 0,
              let directory = try? file.subSlice(at: 12, length: Int(numTables) * 16)
        else { return nil }

        var tables: [(tag: String, offset: Int, length: Int)] = []
        for index in 0..<Int(numTables) {
            let base = index * 16
            guard let tag = try? directory.asciiTag(at: base),
                  let offset = try? directory.readUInt32(at: base + 8),
                  let length = try? directory.readUInt32(at: base + 12)
            else { return nil }
            tables.append((tag: tag, offset: Int(offset), length: Int(length)))
        }

        func features(in tableTag: String) -> [String] {
            // A record whose offset or length has escaped the file yields no
            // features, but the directory itself stays reportable.
            guard let table = tables.first(where: { $0.tag == tableTag }),
                  let slice = try? file.subSlice(at: table.offset, length: table.length)
            else { return [] }
            return featureTags(in: slice)
        }

        return FontTableReport(
            sfntVersion: versionString,
            tables: tables.map(\.tag).sorted(),
            gsubFeatures: features(in: "GSUB"),
            gposFeatures: features(in: "GPOS")
        )
    }

    /// GSUB/GPOS header layout (OpenType 1.9):
    ///   majorVersion(2) minorVersion(2) scriptListOffset(2)
    ///   featureListOffset(2) lookupListOffset(2)
    /// FeatureList: featureCount(2) then featureCount × { featureTag(4) featureOffset(2) }
    ///
    /// Both offsets are resolved against the table slice, never against the file.
    private static func featureTags(in table: ByteSlice) -> [String] {
        guard table.count >= 10,
              let featureListOffset = try? table.readUInt16(at: 6),
              featureListOffset > 0,
              let list = try? table.subSlice(
                  at: Int(featureListOffset),
                  length: table.count - Int(featureListOffset)
              ),
              let count = try? list.readUInt16(at: 0),
              count > 0, count < 4096
        else { return [] }

        var tags: [String] = []
        for index in 0..<Int(count) {
            let record = 2 + index * 6
            guard let tag = try? list.asciiTag(at: record) else { break }
            tags.append(tag)
        }
        return Array(Set(tags)).sorted()
    }
}
