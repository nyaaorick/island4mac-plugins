import Foundation

/// A value your plugin changes as it runs. Changing it shows the new `body`.
///
///     @State var end: Date? = nil
///
/// Values are Codable so a plugin that sleeps between uses keeps them (`lifecycle = .onDemand`)
@MainActor
@propertyWrapper
public struct State<Value: Codable> {
    let box: StateBox<Value>

    public init(wrappedValue: Value) {
        box = StateBox(wrappedValue)
    }

    public var wrappedValue: Value {
        get { box.value }
        nonmutating set {
            box.value = newValue
            IslandRuntime.current?.setNeedsRender()
        }
    }

    /// `$name`: hands the value to a component of your own, which can change it
    public var projectedValue: Binding<Value> {
        Binding(get: { box.value }, set: { wrappedValue = $0 })
    }
}

/// A value a component reads and changes, kept by whoever made it (`$name` of a @State)
@MainActor
public struct Binding<Value> {
    private let get: @MainActor () -> Value
    private let set: @MainActor (Value) -> Void

    public init(get: @escaping @MainActor () -> Value, set: @escaping @MainActor (Value) -> Void) {
        self.get = get
        self.set = set
    }

    public var wrappedValue: Value {
        get { get() }
        nonmutating set { set(newValue) }
    }
}

@MainActor
final class StateBox<Value: Codable> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// What the runtime finds of a plugin's @State by reflection, to save and restore it
@MainActor
protocol StateStorage {
    func encoded() -> Data?
    func restore(from data: Data)
}

extension State: StateStorage {
    func encoded() -> Data? { try? JSONEncoder().encode(box.value) }

    func restore(from data: Data) {
        if let value = try? JSONDecoder().decode(Value.self, from: data) { box.value = value }
    }
}

/// A value kept on disk, in the plugin's data folder, across runs and updates.
///
///     @Stored("last-minutes") var lastMinutes: Int? = nil
@MainActor
@propertyWrapper
public struct Stored<Value: Codable> {
    let key: String
    let defaultValue: Value
    let cache = StateBox<Value?>(nil)

    public init(wrappedValue: Value, _ key: String) {
        self.key = key
        self.defaultValue = wrappedValue
    }

    public var wrappedValue: Value {
        get {
            if let value = cache.value { return value }
            let value = StoredValues.current.read(key, as: Value.self) ?? defaultValue
            cache.value = value
            return value
        }
        nonmutating set {
            cache.value = newValue
            StoredValues.current.write(key, newValue)
            IslandRuntime.current?.setNeedsRender()
        }
    }
}

/// `stored.json` in the plugin's data folder: one JSON value per key. In memory only without a data folder
@MainActor
final class StoredValues {
    static var current = StoredValues(folder: nil)

    let file: URL?
    private var values: [String: Any]

    init(folder: URL?) {
        file = folder?.appendingPathComponent("stored.json")
        values = file.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func read<Value: Decodable>(_ key: String, as type: Value.Type) -> Value? {
        guard let value = values[key],
              let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    func write<Value: Encodable>(_ key: String, _ value: Value) {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return }
        values[key] = object
        guard let file, let out = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? out.write(to: file, options: .atomic)
    }
}
