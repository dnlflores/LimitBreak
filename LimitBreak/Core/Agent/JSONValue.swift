import Foundation

/// A loosely-typed JSON value, used to carry tool-call arguments between the
/// three coaching backends and `CoachToolRunner`.
///
/// Arguments arrive from three very different places — Anthropic's schema-
/// validated `tool_use.input`, a local model's free-text JSON, and Apple's
/// on-device `GeneratedContent` — so the accessors below are deliberately
/// lenient in exactly the ways those sources are sloppy: a number written as a
/// string, an integer sent as a float, a single value where a list was asked
/// for. Anything the schema already guarantees still decodes on the fast path;
/// the coercions only ever rescue a call that would otherwise be thrown away.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

/// Encodes to the natural JSON shape rather than a tagged wrapper, so a
/// persisted transcript round-trips as plain JSON and is legible on disk. Bool
/// is tried before Double because `JSONDecoder` refuses to read `true` as a
/// number or `1` as a bool, so the order can't cross-match.
extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unrecognized JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:               try container.encodeNil()
        case .bool(let value):    try container.encode(value)
        case .number(let value):  try container.encode(value)
        case .string(let value):  try container.encode(value)
        case .array(let values):  try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}

// MARK: - Bridging to Foundation

extension JSONValue {

    /// Wraps a `JSONSerialization` output value. Unknown types become `.null`
    /// rather than throwing — a single unreadable argument shouldn't discard
    /// the whole tool call.
    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        // NSNumber bridges both booleans and numbers; the type encoding is the
        // only reliable way to tell `true` from `1`.
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(any:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(any:)))
        default:
            self = .null
        }
    }

    /// The `JSONSerialization`-compatible representation, for building request
    /// bodies back up.
    var anyValue: Any {
        switch self {
        case .null:               return NSNull()
        case .bool(let value):    return value
        case .number(let value):  return value
        case .string(let value):  return value
        case .array(let values):  return values.map(\.anyValue)
        case .object(let values): return values.mapValues(\.anyValue)
        }
    }

    /// Parses a JSON object literal into an argument dictionary. Returns an
    /// empty dictionary for anything that isn't an object, so a caller can
    /// treat "no arguments" and "unparseable arguments" identically.
    static func objectFrom(jsonText: String) -> [String: JSONValue] {
        guard let data = jsonText.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return parsed.mapValues(JSONValue.init(any:))
    }

    /// Compact JSON text, for echoing a call back to a schema-less model.
    var jsonText: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: anyValue,
            options: [.sortedKeys, .fragmentsAllowed]
        ) else { return "null" }
        return String(data: data, encoding: .utf8) ?? "null"
    }
}

// MARK: - Lenient reads

extension JSONValue {

    var stringValue: String? {
        switch self {
        case .string(let value): return value
        // Render a whole number without its ".0" so a coerced argument reads
        // back the way the model wrote it.
        case .number(let value):
            return value.truncatingRemainder(dividingBy: 1) == 0 && value.magnitude < 1e15
                ? String(format: "%.0f", value)
                : String(value)
        case .bool(let value):   return value ? "true" : "false"
        default:                 return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .bool(let value):   return value ? 1 : 0
        case .string(let text):
            // "135 lb", "135.5", "~135" — keep the numeric core and drop units.
            let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
            return Double(cleaned)
        default:
            return nil
        }
    }

    var intValue: Int? {
        guard let value = doubleValue, value.isFinite else { return nil }
        return Int(value.rounded())
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):   return value
        case .number(let value): return value != 0
        case .string(let text):
            switch text.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes", "1":  return true
            case "false", "no", "0":  return false
            default:                  return nil
            }
        default:
            return nil
        }
    }

    /// Array contents, promoting a lone value to a one-element list — small
    /// models routinely send `"chest"` where `["chest"]` was asked for.
    var arrayValue: [JSONValue]? {
        switch self {
        case .array(let values): return values
        case .null:              return nil
        default:                 return [self]
        }
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let values) = self else { return nil }
        return values
    }
}

// MARK: - Keyed reads

extension Dictionary where Key == String, Value == JSONValue {

    /// Case- and separator-insensitive lookup: `targetSets`, `target_sets`, and
    /// `Target Sets` all resolve to the same argument. Models drift on casing
    /// far more often than they drift on meaning.
    private func value(_ key: String) -> JSONValue? {
        if let exact = self[key] { return exact }
        let normalized = key.normalizedArgumentKey
        return first { $0.key.normalizedArgumentKey == normalized }?.value
    }

    func string(_ key: String) -> String? {
        guard let text = value(key)?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func int(_ key: String) -> Int? { value(key)?.intValue }
    func double(_ key: String) -> Double? { value(key)?.doubleValue }
    func bool(_ key: String) -> Bool? { value(key)?.boolValue }
    func array(_ key: String) -> [JSONValue]? { value(key)?.arrayValue }

    /// A list of strings, dropping any element that can't be read as one. Used
    /// for a reply's `suggestions`, where a stray null or object shouldn't sink
    /// the whole list.
    func stringArray(_ key: String) -> [String] {
        (array(key) ?? []).compactMap(\.stringValue)
    }

    /// A list of objects — the shape every "exercises" argument uses. Bare
    /// strings in the list are promoted to `{"name": "..."}`, since a model
    /// asked for movement objects sometimes sends just the names.
    func objectArray(_ key: String) -> [[String: JSONValue]] {
        (array(key) ?? []).compactMap { element in
            if let object = element.objectValue { return object }
            if let name = element.stringValue { return ["name": .string(name)] }
            return nil
        }
    }
}

private extension String {
    /// Lowercased with separators stripped, so `target_sets` == `targetSets`.
    var normalizedArgumentKey: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
