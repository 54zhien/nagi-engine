import Foundation
import XCTest
import SpikeKit

/// `FontTables` reads a binary format with hand-rolled offset arithmetic, which
/// makes it the highest-risk code in the package: a wrong offset reads plausible
/// garbage instead of failing, and the resulting feature census would silently
/// under-report what the font can do.
///
/// Every guard in the parser gets a sample here, because the failure it prevents
/// looks like a legitimate answer — "no features" is indistinguishable from
/// "the guards rejected something" unless something asserts the difference.
///
/// The synthetic faces below are assembled by hand rather than checked in as
/// font files: 40 bytes of array literal can be read in the diff, and it cannot
/// go stale.
final class FontTableTests: XCTestCase {

    // MARK: - Synthetic faces

    func testRejectsEmptyData() {
        XCTAssertNil(FontTables.parse(Data()))
    }

    func testRejectsTruncatedHeader() {
        XCTAssertNil(FontTables.parse(Data(repeating: 0, count: 11)))
        XCTAssertNil(FontTables.parse(Data(repeating: 0, count: 4)))
    }

    func testRejectsZeroTableCount() {
        XCTAssertNil(FontTables.parse(Data(repeating: 0, count: 12)))
    }

    /// A directory that claims more tables than the file can hold must not be
    /// walked: every record read past the end would otherwise be zero-filled,
    /// which reads as a table named "\0\0\0\0" at offset 0.
    func testRejectsDirectoryLargerThanFile() {
        var lying = makeFont(tables: [("head", [0, 0, 0, 0])])
        lying.replaceSubrange(4..<6, with: u16(5))  // numTables: 1 -> 5, file unchanged
        XCTAssertNil(FontTables.parse(lying))
    }

    /// A TTC has a different header layout. The parser reports and stops rather
    /// than misreading the collection header as a table directory. Note this is
    /// decided before the table-count guard, so a bare 12-byte blob is enough.
    func testReportsFontCollectionWithoutMisparsing() throws {
        let report = try XCTUnwrap(FontTables.parse(makeFont(sfntVersion: 0x7474_6366, tables: [])))
        XCTAssertEqual(report.sfntVersion, "ttcf (collection)")
        XCTAssertEqual(report.tables, [])
        XCTAssertEqual(report.gsubFeatures, [])
        XCTAssertFalse(report.hasVerticalMetrics)
    }

    func testNamesCFFFlavouredFont() throws {
        let data = makeFont(sfntVersion: 0x4F54_544F, tables: [("head", [0, 0, 0, 0])])
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.sfntVersion, "OTTO (CFF)")
    }

    func testNamesTrueTypeFlavour() throws {
        let data = makeFont(sfntVersion: 0x0001_0000, tables: [("head", [0, 0, 0, 0])])
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.sfntVersion, "1.0")
    }

    /// A tag whose bytes are not ASCII has no decodable string. The record must
    /// still be listed, with a placeholder, rather than dropped or trapped.
    func testUndecodableTableTagBecomesPlaceholder() throws {
        var data = makeFont(tables: [("head", [0, 0, 0, 0])])
        data.replaceSubrange(12..<16, with: [0xFF, 0xFE, 0xFD, 0xFC] as [UInt8])  // table 0's tag
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.tables, ["????"])
    }

    // MARK: - Feature list offsets

    func testParsesFeatureTags() throws {
        let data = makeFont(tables: [("GSUB", gsubTable(features: ["vert", "halt"]))])
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.gsubFeatures, ["halt", "vert"])
    }

    /// Duplicates are collapsed: a face that registers the same tag in several
    /// scripts would otherwise report it several times, and the report is
    /// compared byte-for-byte.
    func testDeduplicatesAndSortsFeatureTags() throws {
        let data = makeFont(tables: [("GSUB", gsubTable(features: ["vert", "halt", "vert"]))])
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.gsubFeatures, ["halt", "vert"])
    }

    /// featureListOffset == 0 means "no feature list", which is legal in minimal
    /// faces. It must read as "no features", not as "parse from offset 0".
    func testAbsentFeatureListOffsetYieldsNoFeatures() throws {
        let table = gsubTable(features: ["vert"], featureListOffset: 0)
        let report = try XCTUnwrap(FontTables.parse(makeFont(tables: [("GSUB", table)])))
        XCTAssertEqual(report.gsubFeatures, [])
    }

    func testZeroFeatureCountYieldsNoFeatures() throws {
        let table = gsubTable(features: [], featureCount: 0)
        let report = try XCTUnwrap(FontTables.parse(makeFont(tables: [("GSUB", table)])))
        XCTAssertEqual(report.gsubFeatures, [])
    }

    /// The count drives a loop, so a corrupt file must not be able to make the
    /// parser walk further than the table it declared. The `< 4096` guard is
    /// what bounds it.
    func testImplausibleFeatureCountIsRejectedWithoutWalking() throws {
        let table = gsubTable(features: ["vert"], featureCount: 5_000)
        let report = try XCTUnwrap(FontTables.parse(makeFont(tables: [("GSUB", table)])))
        XCTAssertEqual(report.gsubFeatures, [])
    }

    /// A feature list offset past the end of the file: the case that would read
    /// out of bounds if the bounds checks were wrong.
    func testFeatureListOffsetPastEndOfFile() throws {
        let table = gsubTable(features: ["vert"], featureListOffset: 60_000)
        let report = try XCTUnwrap(FontTables.parse(makeFont(tables: [("GSUB", table)])))
        XCTAssertEqual(report.gsubFeatures, [])
    }

    /// The same class of bug one level up: a table record pointing outside the
    /// file. The directory itself stays readable, so this must not return nil.
    func testTableOffsetPastEndOfFile() throws {
        var data = makeFont(tables: [("GSUB", gsubTable(features: ["vert"]))])
        data.replaceSubrange(20..<24, with: u32(0xFFFF_0000))  // GSUB's offset field
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.gsubFeatures, [])
    }

    /// The failure the owning-slice bound exists for: an offset that has escaped
    /// its own table but still lands inside the file.
    ///
    /// A parser that bounds reads by the file alone reads a neighbouring table's
    /// bytes and reports a confident, wrong answer. The padding table below is
    /// built to hold a valid-looking feature list exactly where the escaped
    /// offset points, so this fixture discriminates: file-bounded it yields
    /// `["vert"]` — a feature this font does not have, forged by the padding —
    /// and owning-slice it yields nothing.
    func testFeatureListOffsetEscapingItsOwningTableIsRejected() throws {
        let gsub = gsubTable(features: [], featureListOffset: 40)
        XCTAssertEqual(gsub.count, 10, "fixture must stay header-only")

        // GSUB lands at 12 + 2*16 = 44 and is 10 bytes; +40 resolves to byte 84,
        // which is byte 30 of the padding table that starts at 54.
        var pad = [UInt8](repeating: 0, count: 30)
        pad += u16(1)                 // featureCount
        pad += Array("vert".utf8)     // featureTag
        pad += u16(0)                 // featureOffset

        let report = try XCTUnwrap(FontTables.parse(makeFont(tables: [("GSUB", gsub), ("pad0", pad)])))
        XCTAssertEqual(report.gsubFeatures, [], "the offset escaped GSUB and must not be honoured")
    }

    func testMissingTableYieldsNoFeatures() throws {
        let data = makeFont(tables: [("head", [0, 0, 0, 0])])
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.gsubFeatures, [])
        XCTAssertEqual(report.gposFeatures, [])
    }

    func testParsesGPOSFeatureTags() throws {
        let data = makeFont(tables: [("GPOS", gposTable(features: ["kern"]))])
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.gposFeatures, ["kern"])
        XCTAssertEqual(report.gsubFeatures, [])
    }

    /// `hasVerticalMetrics` must require BOTH tables — `vmtx` without `vhea`
    /// has no metrics to interpret.
    func testVerticalMetricsRequireBothTables() throws {
        let onlyVhea = try XCTUnwrap(FontTables.parse(makeFont(tables: [("vhea", [0, 0, 0, 0])])))
        XCTAssertFalse(onlyVhea.hasVerticalMetrics)

        let both = try XCTUnwrap(FontTables.parse(
            makeFont(tables: [("vhea", [0, 0, 0, 0]), ("vmtx", [0, 0, 0, 0])])
        ))
        XCTAssertTrue(both.hasVerticalMetrics)
    }

    func testFeatureAvailabilityAlwaysReportsEveryTag() throws {
        let data = makeFont(tables: [("GSUB", gsubTable(features: ["vert"]))])
        let report = try XCTUnwrap(FontTables.parse(data))
        XCTAssertEqual(report.featureAvailability.count, 11)
        XCTAssertTrue(report.featureAvailability["vert"] == true)
        for absent in ["vrt2", "halt", "palt", "vhal", "vpal", "kern", "locl", "pwid", "hwid", "twid"] {
            XCTAssertTrue(report.featureAvailability[absent] == false, "\(absent) should be absent")
        }
    }

    // MARK: - The font we actually ship

    /// Pinned the same way the corpus is: glyph metrics are only comparable
    /// across runs if it is the same font, which is precisely why ADR-0011
    /// bundles it instead of taking it from the system.
    func testBundledFontIsPresentAndUnchanged() throws {
        let data = try XCTUnwrap(
            BundledFont.data(),
            "bundled font did not resolve — the SwiftPM resource/Bundle.module path is broken"
        )
        XCTAssertEqual(SHA256.hex(data), "9ebe10c27e2efc217e3311f61fcd6d2b670792c0c639398a6d8a461603d87abd")
    }

    func testBundledFontFeatureCensus() throws {
        let data = try XCTUnwrap(BundledFont.data())
        let report = try XCTUnwrap(FontTables.parse(data))

        XCTAssertEqual(report.sfntVersion, "1.0")
        XCTAssertEqual(report.tables.count, 13)
        for table in ["head", "cmap", "glyf", "GSUB", "vhea", "vmtx"] {
            XCTAssertTrue(report.tables.contains(table), "expected table \(table)")
        }

        XCTAssertTrue(report.hasVerticalMetrics, "vhea + vmtx are present, so vertical layout has metrics to read")

        XCTAssertEqual(report.gsubFeatures, ["aalt", "vert"])
        XCTAssertEqual(report.gposFeatures, [], "this face ships no GPOS table at all")

        // The census the engine depends on. This face carries `vert` for
        // vertical forms but NOT the punctuation-compression features, so
        // 標點擠壓 has to be Nagi's job rather than something we ask the font
        // for. If the bundled font is ever replaced, this is the assertion that
        // notices before a golden does.
        let availability = report.featureAvailability
        XCTAssertTrue(availability["vert"] == true)
        XCTAssertFalse(availability["halt"] == true, "halt appeared — punctuation compression could move into the font")
        XCTAssertFalse(availability["palt"] == true, "palt appeared — see halt above")
        XCTAssertFalse(availability["vrt2"] == true)
        XCTAssertFalse(availability["kern"] == true, "no GPOS table, so no GPOS kern feature")
    }

    // MARK: - Synthetic font assembly

    /// Minimal sfnt: 12-byte header, one 16-byte record per table, then bodies.
    /// Checksums are left at zero — the parser does not verify them, and a
    /// fixture that recomputed them would be testing the fixture.
    private func makeFont(
        sfntVersion: UInt32 = 0x0001_0000,
        tables: [(tag: String, body: [UInt8])]
    ) -> Data {
        for table in tables {
            // A tag that is not exactly four bytes shifts every offset that
            // follows it, silently turning a fixture into a different test. The
            // precondition is the only thing standing between a typo and a test
            // that passes for the wrong reason.
            precondition(
                table.tag.utf8.count == 4,
                "sfnt table tags are exactly 4 bytes, got \"\(table.tag)\""
            )
        }
        let headerSize = 12 + tables.count * 16
        var data = Data()
        data.append(contentsOf: u32(sfntVersion))
        data.append(contentsOf: u16(UInt16(tables.count)))
        data.append(contentsOf: u16(0))  // searchRange
        data.append(contentsOf: u16(0))  // entrySelector
        data.append(contentsOf: u16(0))  // rangeShift

        var offset = headerSize
        for table in tables {
            data.append(contentsOf: Array(table.tag.utf8))
            data.append(contentsOf: u32(0))  // checkSum
            data.append(contentsOf: u32(UInt32(offset)))
            data.append(contentsOf: u32(UInt32(table.body.count)))
            offset += table.body.count
        }
        for table in tables {
            data.append(contentsOf: table.body)
        }
        return data
    }

    /// GSUB/GPOS header: major, minor, scriptListOffset, featureListOffset,
    /// lookupListOffset — featureListOffset sits at +6, which is the field the
    /// census reads and therefore the one worth varying.
    private func featureTable(
        features: [String],
        featureListOffset: UInt16,
        featureCount: UInt16?
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += u16(1)  // majorVersion
        bytes += u16(0)  // minorVersion
        bytes += u16(0)  // scriptListOffset
        bytes += u16(featureListOffset)
        bytes += u16(0)  // lookupListOffset

        // Anything other than the real offset is a guard case; emitting the list
        // anyway would make the fixture contradict itself.
        guard featureListOffset == 10 else { return bytes }

        bytes += u16(featureCount ?? UInt16(features.count))
        for tag in features {
            bytes += Array(tag.utf8)
            bytes += u16(0)  // featureOffset — unused by the census
        }
        return bytes
    }

    private func gsubTable(
        features: [String],
        featureListOffset: UInt16 = 10,
        featureCount: UInt16? = nil
    ) -> [UInt8] {
        featureTable(features: features, featureListOffset: featureListOffset, featureCount: featureCount)
    }

    private func gposTable(features: [String]) -> [UInt8] {
        featureTable(features: features, featureListOffset: 10, featureCount: nil)
    }

    private func u16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    private func u32(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}
