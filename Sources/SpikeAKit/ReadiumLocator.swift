import Foundation

/// A mirror of Readium's `Locator`, faithful to its *shape* and to the encoding
/// behaviours a round-trip claim depends on.
///
/// **Why a mirror and not the real type.** Readium's toolkit is an iOS-only
/// package (`swift-toolkit-nagi/Package.swift:13` → `platforms: [.iOS("15.0")]`)
/// with nine external dependencies, and this spike is a macOS SwiftPM package on
/// a `macos-15` runner. The real `Locator` cannot be linked here.
///
/// **What that costs.** Spike A measures Nagi's Location Bridge against the
/// Locator *shape*, not against Readium's implementation. Everything in
/// Readium's positions services, navigator and JavaScript — the incompatible
/// `progression`/`position` indexings, the two definitions of `totalProgression`,
/// the anchor resolution in `utils.js` — is therefore quoted from source and
/// cited, never measured here. The report says so in as many words.
///
/// **What keeps the mirror honest.** Every behaviour below carries the
/// `file:line` it was taken from, at commit `540131be9` of
/// `54zhien/swift-toolkit`. And the fixtures used to test it are the expected
/// values from Readium's own test suite, which are dictionaries — that is,
/// real JSON.
public struct ReadiumLocator: Codable, Sendable, Hashable {
    /// Readium stores this as `AnyURL`. The mirror keeps the string: the spike
    /// cares about normalisation *when comparing*, which is a separate step
    /// (see `Href`), not about URL parsing.
    public var href: String
    /// The JSON key for this is `"type"`, not `"mediaType"` — `Locator.swift:80-88`.
    public var mediaType: String
    public var title: String?
    public var locations: Locations
    public var text: Text

    public init(
        href: String,
        mediaType: String,
        title: String? = nil,
        locations: Locations = Locations(),
        text: Text = Text()
    ) {
        self.href = href
        self.mediaType = mediaType
        self.title = title
        self.locations = locations
        self.text = text
    }

    private enum CodingKeys: String, CodingKey {
        case href, title, locations, text
        case type
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `href` and `type` are required; missing either throws rather than
        // defaulting — `Locator.swift:53-59`.
        self.href = try container.decode(String.self, forKey: .href)
        self.mediaType = try container.decode(String.self, forKey: .type)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        // A missing *or malformed* `locations` / `text` becomes the empty value
        // rather than an error — `Locator.swift:74-76` decodes each with `??`.
        self.locations = (try? container.decode(Locations.self, forKey: .locations)) ?? Locations()
        self.text = (try? container.decode(Text.self, forKey: .text)) ?? Text()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(href, forKey: .href)
        try container.encode(mediaType, forKey: .type)
        try container.encodeIfPresent(title, forKey: .title)
        // An empty `locations` / `text` is omitted entirely rather than written
        // as `{}` — `Locator.swift:80-88` applies `.orNullIfEmpty` to both.
        // Readium's own `testGetMinimalJSON` pins this.
        if !locations.isEmpty {
            try container.encode(locations, forKey: .locations)
        }
        if !text.isEmpty {
            try container.encode(text, forKey: .text)
        }
    }

    // MARK: - Locations

    public struct Locations: Codable, Sendable, Hashable {
        public var fragments: [String]
        /// Readium's doc comment says "between 0 and 1" for this and
        /// `totalProgression`, but nothing enforces it: neither is clamped on
        /// decode (`Locator.swift:172-173`), and Readium's own
        /// `testParseFullJSON` round-trips `totalProgression: 25.32`.
        public var progression: Double?
        public var totalProgression: Double?
        public var position: Int?
        /// Where every unrecognised key lands, and how `cssSelector`,
        /// `partialCfi` and `domRange` survive a round trip at all
        /// — `Locator.swift:175`.
        public var otherLocations: [String: JSONValue]

        public init(
            fragments: [String] = [],
            progression: Double? = nil,
            totalProgression: Double? = nil,
            position: Int? = nil,
            otherLocations: [String: JSONValue] = [:]
        ) {
            self.fragments = fragments
            self.progression = progression
            self.totalProgression = totalProgression
            self.position = position
            self.otherLocations = otherLocations
        }

        public var isEmpty: Bool {
            fragments.isEmpty
                && progression == nil
                && totalProgression == nil
                && position == nil
                && otherLocations.isEmpty
        }

        /// `Locator+HTML.swift:13-41`. Note the spelling: the Swift property
        /// spells CFI in capitals while the JSON key does not, and the property
        /// is read-only — nothing in Readium ever reads it back either.
        public var partialCFI: String? {
            otherLocations["partialCfi"]?.string
        }

        public var cssSelector: String? {
            get { otherLocations["cssSelector"]?.string }
            set {
                if let newValue {
                    otherLocations["cssSelector"] = .string(newValue)
                } else {
                    otherLocations.removeValue(forKey: "cssSelector")
                }
            }
        }

        /// Kept as raw JSON on purpose. Readium decodes it with `try?`
        /// (`Locator+HTML.swift:39`), so a malformed `domRange` yields nil and
        /// no error while the raw value stays in `otherLocations`.
        public var domRange: JSONValue? {
            otherLocations["domRange"]
        }

        private static let declaredKeys: Set<String> = [
            "fragments", "fragment", "progression", "totalProgression", "position"
        ]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: JSONValue.AnyKey.self)

            var fragments = (try? container.decode([String].self, forKey: JSONValue.AnyKey("fragments"))) ?? []
            // The singular key is folded in on decode — `Locator.swift:166-169` —
            // and never written back, because encode only ever emits
            // `"fragments"` (`:185`). So the spelling is not preserved.
            if let fragment = try? container.decode(String.self, forKey: JSONValue.AnyKey("fragment")) {
                fragments.append(fragment)
            }

            var other: [String: JSONValue] = [:]
            for key in container.allKeys where !Locations.declaredKeys.contains(key.stringValue) {
                guard let value = try? container.decode(JSONValue.self, forKey: key) else { continue }
                other[key.stringValue] = value
            }

            self.init(
                fragments: fragments,
                progression: try? container.decode(Double.self, forKey: JSONValue.AnyKey("progression")),
                totalProgression: try? container.decode(Double.self, forKey: JSONValue.AnyKey("totalProgression")),
                position: (try? container.decode(Double.self, forKey: JSONValue.AnyKey("position")))?.nonNegativeInt,
                otherLocations: other
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: JSONValue.AnyKey.self)
            if !fragments.isEmpty {
                try container.encode(fragments, forKey: JSONValue.AnyKey("fragments"))
            }
            try container.encodeIfPresent(progression, forKey: JSONValue.AnyKey("progression"))
            try container.encodeIfPresent(totalProgression, forKey: JSONValue.AnyKey("totalProgression"))
            try container.encodeIfPresent(position, forKey: JSONValue.AnyKey("position"))
            // Unknown keys are merged back at the top level of `locations`
            // — `Locator.swift:183-190`.
            for (key, value) in otherLocations {
                try container.encode(value, forKey: JSONValue.AnyKey(key))
            }
        }
    }

    // MARK: - Text

    public struct Text: Codable, Sendable, Hashable {
        public var after: String?
        public var before: String?
        public var highlight: String?

        public init(after: String? = nil, before: String? = nil, highlight: String? = nil) {
            self.after = after
            self.before = before
            self.highlight = highlight
        }

        public var isEmpty: Bool {
            after == nil && before == nil && highlight == nil
        }
    }
}
