import Foundation

/// The cases the report turns into `RoundTrip` rows.
///
/// Each one is here because it is a different answer to "what does this
/// conversion actually preserve" — the shapes Readium really mints (a positions
/// service locator with `progression` + `position` + `totalProgression`), the
/// shape its JavaScript really mints (a selector plus an unbounded highlight,
/// nothing else), and the shapes a stored annotation really has.
enum SpikeACases {
    static func all(_ document: Document) -> [RoundTrip] {
        locatorFirst(document) + nativeFirst(document)
    }

    static func locatorFirst(_ document: Document) -> [RoundTrip] {
        locatorCases.map { testCase in
            RoundTripHarness.locatorToNativeToLocator(
                testCase.locator,
                in: document,
                label: testCase.label
            )
        }
    }

    static func nativeFirst(_ document: Document) -> [RoundTrip] {
        nativeCases(document).map { testCase in
            RoundTripHarness.nativeToLocatorToNative(
                testCase.position,
                in: document,
                label: testCase.label
            )
        }
    }

    // MARK: - Publication-position-first

    struct LocatorCase {
        var label: String
        var locator: ReadiumLocator
    }

    static let locatorCases: [LocatorCase] = [
        // The good case: a structural anchor with nothing to approximate.
        LocatorCase(label: "id-anchored", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(fragments: ["p1"])
        )),

        // **The same resource, spelled the way a real producer may well spell
        // it.** A fragment on the href is a legal way to name the same
        // document, and `Href.isEquivalent` strips it on its second pass — so
        // this must resolve to `chap1` and its href must come back `.carried`.
        //
        // Without this row the semantic comparison the harness depends on is
        // never exercised: every other href in the corpus is the canonical
        // spelling, so reverting `compare` to raw `==` would change no row and
        // CI could not tell. A fix that changes nothing observable is the same
        // defect as a row with no test at all.
        LocatorCase(label: "id-anchored-with-fragment-in-href", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml#p1",
            mediaType: "application/xhtml+xml",
            locations: .init(fragments: ["p1"])
        )),

        // The same anchor, in the unit with identical content.
        LocatorCase(label: "id-anchored-in-identical-twin", locator: ReadiumLocator(
            href: "OEBPS/chap2.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(fragments: ["p1"])
        )),

        // A stored annotation: anchor plus the quotation that justifies it.
        LocatorCase(label: "id-anchored-with-quotation", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            title: "第一章",
            locations: .init(fragments: ["p1"]),
            text: .init(after: "山谷，沉默了片刻。", before: "", highlight: "韩立望着眼前")
        )),

        // What Readium's `EPUBPositionsService` actually mints: a per-resource
        // progression, a global position, and a global totalProgression.
        LocatorCase(label: "positions-service-shaped", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(progression: 0.5, totalProgression: 0.2, position: 7)
        )),

        // A locator whose only location is the global position.
        LocatorCase(label: "global-position-only", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(position: 42)
        )),

        // What Readium's JavaScript mints: a selector and a highlight, nothing
        // else (`dom.js:55-67` emits no progression, position or fragments).
        LocatorCase(label: "js-shaped-selector", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(otherLocations: ["cssSelector": .string("#p4")])
        )),

        // A selector richer than a plain id, which this bridge refuses to guess at.
        LocatorCase(label: "js-shaped-complex-selector", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(otherLocations: ["cssSelector": .string("body > p:nth-child(3)")])
        )),

        // A fragment naming an id that is not there — a broken anchor, which is
        // a result and not something to fall through from.
        LocatorCase(label: "fragment-names-nothing", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(fragments: ["p99"])
        )),

        // An href the manifest does not have, with a totalProgression to fall
        // back on — the only fallback Readium itself has.
        LocatorCase(label: "unknown-href-with-fallback", locator: ReadiumLocator(
            href: "OEBPS/renamed.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(totalProgression: 0.9)
        )),

        // The same, with nothing to fall back on.
        LocatorCase(label: "unknown-href-no-fallback", locator: ReadiumLocator(
            href: "OEBPS/renamed.xhtml",
            mediaType: "application/xhtml+xml"
        )),

        // A progression outside 0...1. Readium stores these without clamping
        // (`Locator.swift:172`), so the bridge has to be defined anyway.
        LocatorCase(label: "progression-out-of-range", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(progression: 1.8)
        )),

        // A quotation that occurs once.
        LocatorCase(label: "quotation-unique", locator: ReadiumLocator(
            href: "OEBPS/chap3.xhtml",
            mediaType: "application/xhtml+xml",
            text: .init(highlight: "空白 折叠 测试")
        )),

        // A quotation that occurs twice — the ambiguity the fixture exists for.
        LocatorCase(label: "quotation-repeated", locator: ReadiumLocator(
            href: "OEBPS/chap1.xhtml",
            mediaType: "application/xhtml+xml",
            text: .init(highlight: SpikeAFixture.repeatedText)
        )),

        // The unit where the annotation must not have shifted anything.
        LocatorCase(label: "after-ruby-annotation", locator: ReadiumLocator(
            href: "OEBPS/chap3.xhtml",
            mediaType: "application/xhtml+xml",
            locations: .init(fragments: ["ruby"])
        ))
    ]

    // MARK: - Native-position-first

    struct NativeCase {
        var label: String
        var position: NativePosition
    }

    static func nativeCases(_ document: Document) -> [NativeCase] {
        guard let chapter1 = document.unit(withID: "OEBPS/chap1.xhtml"),
              let chapter3 = document.unit(withID: "OEBPS/chap3.xhtml")
        else { return [] }

        var cases: [NativeCase] = []

        if let p1 = chapter1.canonical.element(withID: "p1") {
            cases.append(NativeCase(
                label: "native-id-anchored",
                position: NativePosition(
                    unitID: chapter1.id,
                    nodeID: .explicitID("p1"),
                    utf16Offset: p1.utf16Range.lowerBound + 3
                )
            ))
        }

        // A paragraph with no id at all, so the only identity it has is its path.
        //
        // This row is now the report's only evidence that **a path-rung identity
        // cannot be written into a locator at all**: with no id there is no
        // fragment to emit, so the position travels as a progression — a
        // channel ADR-0009 rules out for exact recovery. The offset comes back
        // equal, and that equality is arithmetic rather than information, so the
        // row reports `recomputedEquivalent` with both fields `.recomputed`. It
        // looking like a success is the thing to distrust.
        if let anonymous = chapter1.canonical.elements.first(where: { $0.name == "p" && $0.explicitID == nil }) {
            cases.append(NativeCase(
                label: "native-path-anchored",
                position: NativePosition(
                    unitID: chapter1.id,
                    nodeID: .path(anonymous.path),
                    utf16Offset: anonymous.utf16Range.lowerBound + 1
                )
            ))
        }

        // An offset in the MIDDLE of a non-BMP character: the low surrogate of
        // 𠀋. The bridge neither produces nor repairs such an offset, which is
        // the whole reason ADR-0004 gives `PositionResolver` its own layer.
        if let astral = chapter3.canonical.element(withID: "astral") {
            cases.append(NativeCase(
                label: "native-inside-surrogate-pair",
                position: NativePosition(
                    unitID: chapter3.id,
                    nodeID: .explicitID("astral"),
                    utf16Offset: astral.utf16Range.lowerBound + 4
                )
            ))
        }

        // The end of the text, where "inside an element" stops being defined.
        cases.append(NativeCase(
            label: "native-at-unit-end",
            position: NativePosition(
                unitID: chapter1.id,
                nodeID: .explicitID("p1"),
                utf16Offset: chapter1.canonical.utf16Count
            )
        ))

        return cases
    }
}
