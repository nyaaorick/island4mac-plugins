import Foundation

/// JSON from the network, kept fresh and cached. Opening shows the last result at once and refreshes it when it
/// is older than `every`; while it loads with nothing to show, or if it fails, the island shows its standard
/// "loading" or "couldn't load" row.
///
///     @Preference("City") var city = "Paris"
///     @Fetched(Forecast.self, from: "https://wttr.in/{city}?format=j1", every: .minutes(30)) var forecast
///
/// `{key}` in the address or a header is replaced by that @Preference's value. An `.onDemand` plugin is woken for
/// each refresh
@MainActor
@propertyWrapper
public struct Fetched<Value: Decodable> {
    let box: FetchBox

    public init(_ type: Value.Type, from address: String, headers: [String: String] = [:], every interval: RefreshInterval) {
        box = FetchBox(address: address, headers: headers, interval: interval.seconds) { data in
            try JSONDecoder().decode(Value.self, from: data)
        }
    }

    /// The last result, nil until the first one arrives
    public var wrappedValue: Value? { box.value as? Value }

    /// `$name`: whether it is loading, why it failed, and refreshing now
    public var projectedValue: FetchState { FetchState(box: box) }
}

/// How often a @Fetched value is refreshed
public struct RefreshInterval: Sendable {
    public let seconds: TimeInterval

    public static func seconds(_ seconds: Double) -> RefreshInterval { RefreshInterval(seconds: max(seconds, 10)) }
    public static func minutes(_ minutes: Double) -> RefreshInterval { .seconds(minutes * 60) }
    public static func hours(_ hours: Double) -> RefreshInterval { .seconds(hours * 3600) }
}

@MainActor
public struct FetchState {
    let box: FetchBox

    public var isLoading: Bool { box.isLoading }
    /// Why the last refresh failed; nil once one works
    public var error: String? { box.error }
    /// When the value shown was fetched
    public var updated: Date? { box.fetchedAt }

    /// Fetches again now, however fresh it is
    public func refresh() {
        box.fetch()
    }
}

/// One @Fetched's state: its value, its cache file and the request in flight
@MainActor
final class FetchBox {
    let address: String
    let headers: [String: String]
    let interval: TimeInterval
    let decode: (Data) throws -> Any

    var key = ""
    var value: Any?
    var fetchedAt: Date?
    var isLoading = false
    var error: String?
    /// The address the value came from; a preference change that changes it makes the value stale
    private var fetchedAddress: String?
    private var task: Task<Void, Never>?

    /// Requests go through this (tests replace it)
    static var load: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await URLSession.shared.data(for: request)
    }

    init(address: String, headers: [String: String], interval: TimeInterval, decode: @escaping (Data) throws -> Any) {
        self.address = address
        self.headers = headers
        self.interval = interval
        self.decode = decode
    }

    private var runtime: IslandRuntime? { IslandRuntime.current }

    private var cacheFile: URL? {
        runtime?.dataDirectory?.appendingPathComponent("cache/\(key).json")
    }

    private struct Cache: Codable {
        let address: String
        let fetched: Date
        let body: Data
    }

    /// Reads the cache, so the last result shows at once
    func attach(key: String) {
        self.key = key
        guard let file = cacheFile, let data = try? Data(contentsOf: file),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              let decoded = try? decode(cache.body) else { return }
        value = decoded
        fetchedAt = cache.fetched
        fetchedAddress = cache.address
    }

    /// `address` with each `{key}` replaced by that preference's value
    func resolved(_ text: String, encode: Bool) -> String {
        var result = text
        for (key, storage) in runtime?.preferences ?? [] {
            let value = storage.text
            result = result.replacingOccurrences(of: "{\(key)}", with: encode
                ? value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?&=#"))) ?? value
                : value)
        }
        return result
    }

    /// When it is next due, if it has a value
    var nextRefresh: Date? { fetchedAt.map { $0.addingTimeInterval(interval) } }

    /// Fetches if there's nothing yet, the value is too old, or its address changed
    func refreshIfNeeded(now: Date) {
        guard !isLoading else { return }
        let stale = nextRefresh.map { $0 <= now } ?? true
        if stale || fetchedAddress != resolved(address, encode: true) { fetch() }
    }

    func fetch() {
        task?.cancel()
        let address = resolved(self.address, encode: true)
        guard let url = URL(string: address), url.scheme == "https" || url.scheme == "http" else {
            error = "not a web address: \(address)"
            runtime?.setNeedsRender()
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        for (field, value) in headers { request.setValue(resolved(value, encode: false), forHTTPHeaderField: field) }
        isLoading = true
        runtime?.setNeedsRender()
        let load = Self.load
        task = Task { [weak self] in
            let result: Result<(Data, URLResponse), Error>
            do { result = .success(try await load(request)) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self?.finish(result, address: address)
        }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>, address: String) {
        isLoading = false
        defer {
            runtime?.setNeedsRender()
            runtime?.fetchFinished()
        }
        do {
            let (data, response) = try result.get()
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                throw FetchError(description: "the server answered \(status)")
            }
            value = try decode(data)
            fetchedAt = runtime?.now ?? Date()
            fetchedAddress = address
            error = nil
            if let file = cacheFile, let cache = try? JSONEncoder().encode(Cache(address: address, fetched: fetchedAt!, body: data)) {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? cache.write(to: file, options: .atomic)
            }
        } catch let error as DecodingError {
            self.error = "unexpected data: \(error.localizedDescription)"
        } catch {
            self.error = (error as? FetchError)?.description ?? error.localizedDescription
        }
    }

    struct FetchError: Error, CustomStringConvertible {
        let description: String
    }
}

/// What the runtime finds of a plugin's @Fetched by reflection
@MainActor
protocol FetchStorage {
    var fetchBox: FetchBox { get }
}

extension Fetched: FetchStorage {
    var fetchBox: FetchBox { box }
}
