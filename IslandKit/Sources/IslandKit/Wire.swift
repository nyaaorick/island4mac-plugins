import Foundation

/// The island's plugin protocol: the JSON lines a plugin writes (Message) and reads (Event). IslandKit speaks it
/// so a plugin doesn't have to; the README documents it for plugins written without IslandKit
public enum Wire {
    /// The island drops rows and buttons past this
    static let maxItems = 50
    /// The island cuts text past this
    static let maxTextLength = 200
    /// The most a text field takes
    static let maxInputLength = 1000

    struct Compact: Encodable, Equatable {
        var type = "compact"
        var symbol: String?
        var text: String?
        var progress: Double?
        var until: Double?
        var total: Double?
        var image: Image?
    }

    struct Row: Encodable, Equatable {
        var id: String?
        var title: String
        var subtitle: String?
        var symbol: String?
        var image: Image?
        var actions: [RowAction]?
    }

    /// Protocol 4: where a picture comes from; the island sizes and crops it. Islands before 4 ignore it
    struct Image: Encodable, Equatable {
        var file: String?
        var app: String?
        var url: String?
    }

    /// Protocol 4: a row's secondary action. Islands before 4 ignore it
    struct RowAction: Encodable, Equatable {
        let id: String
        let title: String
        var symbol: String?
    }

    /// A row's subtitle may run over up to 3 lines
    static let maxSubtitleLength = 600
    /// Secondary actions past this are dropped
    static let maxRowActions = 4

    struct Button: Encodable, Equatable {
        var id: String
        var title: String
        var symbol: String?
        var confirm: String?
    }

    struct Input: Encodable, Equatable {
        var type = "input"
        var id: String
        var placeholder: String?
        var text: String?
    }

    struct Popup: Encodable, Equatable {
        var type = "popup"
        var symbol: String?
        var text: String
        var seconds: Double?
    }

    /// Protocol 3: content to switch to at given times, and when to wake the plugin
    struct Timeline: Encodable {
        struct Entry: Encodable {
            let at: Double
            let show: [RawMessage]
        }

        var type = "timeline"
        let entries: [Entry]
        let wake: Double?
    }

    /// A message already encoded, nested in a timeline entry
    struct RawMessage: Encodable {
        let line: Data

        func encode(to encoder: Encoder) throws {
            let object = try JSONSerialization.jsonObject(with: line)
            var container = encoder.singleValueContainer()
            try container.encode(AnyJSON(object))
        }
    }

    /// Re-encodes what JSONSerialization read
    struct AnyJSON: Encodable {
        let value: Any
        init(_ value: Any) { self.value = value }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch value {
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): try container.encode(number.boolValue)
            case let number as NSNumber: try container.encode(number.doubleValue)
            case let string as String: try container.encode(string)
            case let array as [Any]: try container.encode(array.map(AnyJSON.init))
            case let object as [String: Any]: try container.encode(object.mapValues(AnyJSON.init))
            default: try container.encodeNil()
            }
        }
    }

    /// Protocol 3: one standard row for "loading" or "couldn't load"; "idle" removes it
    struct Status: Encodable, Equatable {
        var type = "status"
        let state: String
        var text: String?
    }

    enum ClearTarget: String, Encodable {
        case compact, list, buttons, input, all
    }

    enum Message {
        case compact(Compact)
        case list([Row])
        case buttons([Button])
        case input(Input)
        case popup(Popup)
        case open(hold: Bool)
        case close
        case clear(ClearTarget)
        case status(Status)
        case timeline(Timeline)
        case done

        /// One line, ending in a newline. Keys are sorted, so equal messages are equal bytes
        var line: Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var data: Data
            switch self {
            case .compact(let compact): data = (try? encoder.encode(compact)) ?? Data()
            case .list(let rows): data = (try? encoder.encode(ListBody(rows: rows))) ?? Data()
            case .buttons(let buttons): data = (try? encoder.encode(ButtonsBody(buttons: buttons))) ?? Data()
            case .input(let input): data = (try? encoder.encode(input)) ?? Data()
            case .popup(let popup): data = (try? encoder.encode(popup)) ?? Data()
            case .open(let hold): data = (try? encoder.encode(OpenBody(hold: hold ? true : nil))) ?? Data()
            case .close: data = (try? encoder.encode(TypeOnly(type: "close"))) ?? Data()
            case .clear(let target): data = (try? encoder.encode(ClearBody(target: target))) ?? Data()
            case .status(let status): data = (try? encoder.encode(status)) ?? Data()
            case .timeline(let timeline): data = (try? encoder.encode(timeline)) ?? Data()
            case .done: data = (try? encoder.encode(TypeOnly(type: "done"))) ?? Data()
            }
            data.append(UInt8(ascii: "\n"))
            return data
        }

        private struct ListBody: Encodable { var type = "list"; let rows: [Row] }
        private struct ButtonsBody: Encodable { var type = "buttons"; let buttons: [Button] }
        private struct ClearBody: Encodable { var type = "clear"; let target: ClearTarget }
        private struct TypeOnly: Encodable { let type: String }
        private struct OpenBody: Encodable { var type = "open"; let hold: Bool? }
    }

    /// One line from the island. Fields a type doesn't use are nil
    struct Event: Decodable {
        let type: String
        var id: String?
        var text: String?
        var tab: Bool?
        /// "preferences": the value of each preference, by key
        var values: [String: Scalar]?
    }

    /// A preference's value as JSON has it
    public enum Scalar: Codable, Equatable, Sendable {
        case string(String)
        case number(Double)
        case bool(Bool)

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bool = try? container.decode(Bool.self) {
                self = .bool(bool)
            } else if let number = try? container.decode(Double.self) {
                self = .number(number)
            } else {
                self = .string(try container.decode(String.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let string): try container.encode(string)
            case .number(let number): try container.encode(number)
            case .bool(let bool): try container.encode(bool)
            }
        }
    }

    /// One preference in plugin.json (protocol 2)
    struct Preference: Codable, Equatable {
        struct Option: Codable, Equatable {
            let title: String
            let value: Scalar
        }

        let key: String
        let title: String
        let kind: String
        var `default`: Scalar?
        var options: [Option]?
        var minimum: Double?
        var maximum: Double?
        var required: Bool?
        var placeholder: String?
    }

    static func cut(_ text: String) -> String { String(text.prefix(maxTextLength)) }
    static func cut(_ text: String?) -> String? { text.map(cut) }
}
