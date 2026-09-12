import Foundation
import XCTest
@testable import SpikeAKit

/// Pins the mirror to Readium's own expected values.
///
/// The JSON below is taken from Readium's test suite, where the expectations are
/// written as Swift dictionaries — that is, as real JSON. Fidelity matters here
/// more than anywhere else in the kit: a mirror that drifts is a mirror that
/// makes Spike A's round-trip conclusions meaningless, and it would drift
/// silently.
///
/// Sources, at commit `540131be9` of `54zhien/swift-toolkit`:
///   `Tests/SharedTests/Publication/LocatorTests.swift`
final class LocatorMirrorTests: XCTestCase {

    private func decode(_ json: String) throws -> ReadiumLocator {
        try JSONDecoder().decode(ReadiumLocator.self, from: Data(json.utf8))
    }

    private func encode(_ locator: ReadiumLocator) throws -> [String: Any] {
        let data = try JSONEncoder().encode(locator)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Minimal and full

    /// `LocatorTests.testParseMinimalJSON` (:11-22) and `testGetMinimalJSON`
    /// (:55-66): an empty `locations` and `text` are omitted from the encoding
    /// entirely, not written as `{}`.
    func testMinimalLocatorOmitsEmptyNestedObjects() throws {
        let locator = try decode(#"{"href":"http://locator","type":"text/html"}"#)
        XCTAssertEqual(locator.href, "http://locator")
        XCTAssertEqual(locator.mediaType, "text/html")
        XCTAssertTrue(locator.locations.isEmpty)
        XCTAssertTrue(locator.text.isEmpty)

        let encoded = try encode(locator)
        XCTAssertEqual(Set(encoded.keys), ["href", "type"], "empty locations/text must be omitted entirely")
        XCTAssertEqual(encoded["type"] as? String, "text/html", "the encoded key is `type`, never `mediaType`")
    }

    /// `LocatorTests.testParseFullJSON` (:24-44).
    func testFullLocator() throws {
        let locator = try decode("""
        {"href":"http://locator","type":"text/html","title":"My Locator",
         "locations":{"position":42},"text":{"highlight":"Excerpt"}}
        """)
        XCTAssertEqual(locator.title, "My Locator")
        XCTAssertEqual(locator.locations.position, 42)
        XCTAssertEqual(locator.text.highlight, "Excerpt")
    }

    // MARK: - The locations quirks

    /// `LocatorTests.testParseFullJSON` for `Locations` (:138-154) plus
    /// `testGetFullJSON` (:190-205). Two things are load-bearing: an unknown key
    /// survives in `otherLocations` and is merged back at the top level of
    /// `locations`, and `totalProgression: 25.32` comes back unclamped despite
    /// the doc comment claiming 0…1.
    func testFullLocationsPassUnknownKeysAndDoNotClampProgression() throws {
        let json = """
        {"fragments":["p=4","frag34"],"progression":0.74,"totalProgression":25.32,
         "position":42,"other":"other-location"}
        """
        let locations = try JSONDecoder().decode(ReadiumLocator.Locations.self, from: Data(json.utf8))

        XCTAssertEqual(locations.fragments, ["p=4", "frag34"])
        XCTAssertEqual(locations.progression, 0.74)
        XCTAssertEqual(locations.totalProgression, 25.32, "out of range and deliberately not clamped")
        XCTAssertEqual(locations.position, 42)
        XCTAssertEqual(locations.otherLocations["other"]?.string, "other-location")

        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(locations)) as? [String: Any]
        )
        XCTAssertEqual(encoded["other"] as? String, "other-location", "unknown keys merge back at the top level")
        XCTAssertEqual(encoded["totalProgression"] as? Double, 25.32)
    }

    /// `LocatorTests.testParseSingleFragment` (:157-166). The singular key is
    /// folded in on decode, and encode only ever writes the plural — so the
    /// spelling is not preserved.
    func testSingularFragmentFoldsInAndIsNotWrittenBack() throws {
        let locations = try JSONDecoder().decode(
            ReadiumLocator.Locations.self,
            from: Data(#"{"fragment":"frag34"}"#.utf8)
        )
        XCTAssertEqual(locations.fragments, ["frag34"])

        let encoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(locations)) as? [String: Any]
        )
        XCTAssertEqual(encoded["fragments"] as? [String], ["frag34"])
        XCTAssertNil(encoded["fragment"], "the singular key is never written back")
    }

    /// `Locator.swift:174` routes `position` through `.nonNegative()`: a negative
    /// value is discarded rather than clamped. `progression` gets no such filter.
    func testNegativePositionIsDiscardedNotClamped() throws {
        let locations = try JSONDecoder().decode(
            ReadiumLocator.Locations.self,
            from: Data(#"{"position":-1,"progression":-1}"#.utf8)
        )
        XCTAssertNil(locations.position)
        XCTAssertEqual(locations.progression, -1, "progression is not filtered")
    }

    /// `LocatorTests.testParseEmptyJSON` (:168).
    func testEmptyLocationsDecode() throws {
        let locations = try JSONDecoder().decode(ReadiumLocator.Locations.self, from: Data("{}".utf8))
        XCTAssertTrue(locations.isEmpty)
    }

    // MARK: - Required keys

    /// `LocatorTests.testParseInvalidJSON` (:51-53): `href` and `type` are
    /// required, and a missing one throws rather than defaulting.
    func testMissingHrefOrTypeThrows() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(ReadiumLocator.self, from: Data(#"{"type":"text/html"}"#.utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(ReadiumLocator.self, from: Data(#"{"href":"x"}"#.utf8))
        )
    }

    /// A malformed nested object is *not* an error — `Locator.swift:74-76`
    /// decodes each with `??`, so it becomes the empty value.
    func testMalformedLocationsBecomeEmpty() throws {
        let locator = try decode(#"{"href":"x","type":"text/html","locations":"nonsense"}"#)
        XCTAssertTrue(locator.locations.isEmpty)
    }

    // MARK: - The HTML extensions

    /// `Locator+HTMLTests` (:15-25, :31-43). Note the spelling asymmetry: the
    /// property is `partialCFI` while the key is `partialCfi`, and `domRange`
    /// stays raw JSON because Readium decodes it with `try?`.
    func testExtensionAccessorsUseTheRealKeys() throws {
        var locations = ReadiumLocator.Locations()
        locations.cssSelector = "p"
        XCTAssertEqual(locations.cssSelector, "p")

        locations.otherLocations["partialCfi"] = .string("epubcfi(/4)")
        XCTAssertEqual(locations.partialCFI, "epubcfi(/4)")

        // Readium reads the key `partialCfi` — lowercase `fi` — while the
        // property is spelled `partialCFI`. A mirror that used the property's
        // spelling as the key would find nothing and say so with a nil that
        // looks exactly like "there was no CFI".
        var camelCased = ReadiumLocator.Locations()
        camelCased.otherLocations["partialCFI"] = .string("epubcfi(/4)")
        XCTAssertNil(camelCased.partialCFI, "the key is `partialCfi`, not the property's spelling")

        locations.otherLocations["domRange"] = .object([
            "start": .object(["cssSelector": .string("p"), "textNodeIndex": .number(4)])
        ])
        XCTAssertNotNil(locations.domRange)
    }

    // MARK: - The real-world pair

    /// `LocatorCollectionTests.testParseFullJSON` (:446-475) — the only fixtures
    /// that combine fragments, progression and all three text components against
    /// a real EPUB href.
    func testRealWorldLocatorsFromTheCollectionFixture() throws {
        let json = """
        {"href":"/978-1503222687/chap7.html","type":"application/xhtml+xml",
         "locations":{"fragments":[":~:text=riddle,-yet%3F'"],"progression":0.43},
         "text":{"before":"'Have you guessed the ","highlight":"riddle",
                 "after":" yet?' the Hatter said, turning to Alice again."}}
        """
        let locator = try decode(json)
        XCTAssertEqual(locator.href, "/978-1503222687/chap7.html")
        XCTAssertEqual(locator.locations.fragments, [":~:text=riddle,-yet%3F'"])
        XCTAssertEqual(locator.locations.progression, 0.43)
        XCTAssertEqual(locator.text.highlight, "riddle")
        XCTAssertEqual(locator.text.before, "'Have you guessed the ")

        // Re-encoding must reproduce the same object, key for key.
        let encoded = try encode(locator)
        XCTAssertEqual(encoded["href"] as? String, "/978-1503222687/chap7.html")
        XCTAssertEqual(encoded["type"] as? String, "application/xhtml+xml")
        let locations = try XCTUnwrap(encoded["locations"] as? [String: Any])
        XCTAssertEqual(locations["progression"] as? Double, 0.43)
    }
}
