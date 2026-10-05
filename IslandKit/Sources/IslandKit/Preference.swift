import Foundation

/// A setting the user fills in under Settings > Plugins in the app. The island draws it in its own style and
/// hands the plugin its value; changing it there shows the new `body`.
///
///     @Preference("API key", secure: true, required: true) var apiKey = ""
///     @Preference("Refresh every", options: [1, 5, 15]) var minutes = 5
///     @Preference("Days", range: 1...7) var days = 3
///     @Preference("Celsius") var celsius = true
///
/// The property's name is its key, and its value here is the default. With `required`, the island doesn't start
/// the plugin until it is filled in. Strings, Bools, Ints and Doubles work
@MainActor
@propertyWrapper
public struct Preference<Value: PreferenceValue> {
    let box: PreferenceBox<Value>

    /// - Parameters:
    ///   - secure: Hidden as it's typed and kept in the Keychain (a String)
    ///   - options: Picked from these, shown with their description
    ///   - range: A number within these bounds, set with a slider
    ///   - required: The plugin doesn't run until it is filled in (a String)
    public init(wrappedValue: Value, _ title: String, secure: Bool = false, options: [Value]? = nil,
                range: ClosedRange<Double>? = nil, required: Bool = false, placeholder: String? = nil) {
        box = PreferenceBox(value: wrappedValue, title: title, secure: secure, options: options, range: range,
                            required: required, placeholder: placeholder)
    }

    public var wrappedValue: Value { box.value }
}

/// A value a Preference can hold
public protocol PreferenceValue: Codable, Equatable, CustomStringConvertible {
    /// text, toggle or number
    static var preferenceKind: String { get }
    var scalar: Wire.Scalar { get }
    init?(scalar: Wire.Scalar)
}

extension String: PreferenceValue {
    public static var preferenceKind: String { "text" }
    public var scalar: Wire.Scalar { .string(self) }
    public init?(scalar: Wire.Scalar) {
        guard case .string(let string) = scalar else { return nil }
        self = string
    }
}

extension Bool: PreferenceValue {
    public static var preferenceKind: String { "toggle" }
    public var scalar: Wire.Scalar { .bool(self) }
    public init?(scalar: Wire.Scalar) {
        guard case .bool(let bool) = scalar else { return nil }
        self = bool
    }
}

extension Int: PreferenceValue {
    public static var preferenceKind: String { "number" }
    public var scalar: Wire.Scalar { .number(Double(self)) }
    public init?(scalar: Wire.Scalar) {
        guard case .number(let number) = scalar, number.isFinite, abs(number) < 1e15 else { return nil }
        self = Int(number.rounded())
    }
}

extension Double: PreferenceValue {
    public static var preferenceKind: String { "number" }
    public var scalar: Wire.Scalar { .number(self) }
    public init?(scalar: Wire.Scalar) {
        guard case .number(let number) = scalar else { return nil }
        self = number
    }
}

@MainActor
final class PreferenceBox<Value: PreferenceValue> {
    var value: Value
    let defaultValue: Value
    let title: String
    let secure: Bool
    let options: [Value]?
    let range: ClosedRange<Double>?
    let required: Bool
    let placeholder: String?

    init(value: Value, title: String, secure: Bool, options: [Value]?, range: ClosedRange<Double>?, required: Bool, placeholder: String?) {
        self.value = value
        self.defaultValue = value
        self.title = title
        self.secure = secure
        self.options = options
        self.range = range
        self.required = required
        self.placeholder = placeholder
    }
}

/// What the runtime finds of a plugin's @Preference by reflection
@MainActor
protocol PreferenceStorage {
    func describe(key: String) -> Wire.Preference
    /// The island's value for it; one that doesn't fit leaves the default
    func apply(_ scalar: Wire.Scalar?)
    /// Its value as text, for `{key}` in a @Fetched address
    var text: String { get }
}

extension Preference: PreferenceStorage {
    var text: String { box.value.description }

    func describe(key: String) -> Wire.Preference {
        let kind: String
        if box.options != nil {
            kind = "choice"
        } else if box.secure && Value.self == String.self {
            kind = "secure"
        } else {
            kind = Value.preferenceKind
        }
        return Wire.Preference(
            key: key, title: box.title, kind: kind, default: box.defaultValue.scalar,
            options: box.options?.map { Wire.Preference.Option(title: $0.description, value: $0.scalar) },
            minimum: box.range?.lowerBound, maximum: box.range?.upperBound,
            required: box.required ? true : nil, placeholder: box.placeholder
        )
    }

    func apply(_ scalar: Wire.Scalar?) {
        if let scalar, let value = Value(scalar: scalar) {
            box.value = value
        } else {
            box.value = box.defaultValue
        }
    }
}

extension IslandPlugin {
    /// Its @Preference properties, by key (the property's name)
    var preferenceStorages: [(key: String, storage: any PreferenceStorage)] {
        reflectedChildren.compactMap { child in (child.value as? any PreferenceStorage).map { (child.key, $0) } }
    }
}
