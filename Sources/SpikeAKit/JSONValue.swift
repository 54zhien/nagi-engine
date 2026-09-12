import Foundation

/// The smallest JSON value that can stand in for Readium's.
///
/// It exists because `Locator.Locations.otherLocations` is `[String: JSONValue]`
/// in Readium, and that dictionary is not decoration: it is where `cssSelector`,
/// `partialCfi` and `domRange` actually live (they are computed accessors over
/// it, not stored properties — `Locator+HTML.swift:13-41`), and it is what lets
/// an unrecognised key survive a decode/encode cycle at all.
///
/// A `[String: String]` would have been smaller and would have quietly dropped
/// `domRange`, which is a nested object.
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "not a JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // The accessors below mirror the ones Readium's decoder reaches for. They
    // return nil rather than throwing, because that is how the original behaves:
    // a wrong type is discarded, not reported.
    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var object: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Readium routes `locations.position` through `.nonNegative()`
    /// (`Locator.swift:174`): a negative or fractional value is discarded
    /// outright, not clamped. `progression` and `totalProgression` get no such
    /// treatment — see `ReadiumLocator.Locations`.
    public var nonNegativeInt: Int? {
        guard let value = double,
              value >= 0,
              value.rounded() == value,
              value <= Double(Int.max)
        else { return nil }
        return Int(value)
    }

    /// A coding key that accepts whatever the document happens to contain.
    ///
    /// Needed because `otherLocations` must swallow keys nobody declared, and
    /// `Codable`'s synthesised keys cannot express "everything else".
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?

        init(_ string: String) {
            stringValue = string
            intValue = nil
        }

        init?(stringValue: String) {
            self.init(stringValue)
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }
}
