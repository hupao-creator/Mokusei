import Foundation
import MokuseiCore
import MokuseiPluginAPI

public struct NativeInteractionError: Error, LocalizedError {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
    public var json: JSONValue { .object(["code": .text(code), "message": .text(message)]) }
}

/// Stable semantic intents, independent of transport and pointer coordinates.
public enum NativeWorkspaceAction: Sendable {
    case openSettings, closeSettings, selectSettingsSection(String)
    case settingsControl(id: String, handle: String, operation: String, value: JSONValue)
    case readingControl(id: String, handle: String, operation: String, value: JSONValue)
    case showOverview, back, openThread(ApplicationThreadRef)
    case beginSearch, updateSearch(String), endSearch, selectFilter(String?)
    case overviewPan(x: Double, y: Double), overviewZoom(delta: Double, x: Double, y: Double), overviewAuto, overviewRetry
    case overviewDirectoryOpen(String), overviewDirectoryClose(String), overviewDirectorySelect(directory: String, filter: String)
    case overviewScrollFilter(String)
    case toggleMokuInput, toggleMokuHistory, toggleMokuNote

    public var name: String {
        switch self {
        case .openSettings: "settings.open"
        case .closeSettings: "settings.close"
        case .selectSettingsSection: "settings.select"
        case .settingsControl: "settings.control"
        case .readingControl: "reading.control"
        case .showOverview: "overview.show"
        case .back: "navigation.back"
        case .openThread: "thread.open"
        case .beginSearch: "search.begin"
        case .updateSearch: "search.update"
        case .endSearch: "search.end"
        case .selectFilter: "filter.select"
        case .overviewPan: "overview.pan"
        case .overviewZoom: "overview.zoom"
        case .overviewAuto: "overview.auto"
        case .overviewRetry: "overview.retry"
        case .overviewDirectoryOpen: "overview.directory.open"
        case .overviewDirectoryClose: "overview.directory.close"
        case .overviewDirectorySelect: "overview.directory.select"
        case .overviewScrollFilter: "overview.filters.scroll"
        case .toggleMokuInput: "moku.input.toggle"
        case .toggleMokuHistory: "moku.history.toggle"
        case .toggleMokuNote: "moku.note.toggle"
        }
    }

    /// Wire validation happens once here; the dispatcher receives a typed intent.
    public init(json: JSONValue) throws {
        guard let object = json.objectValue, let name = json["name"]?.stringValue else {
            throw NativeInteractionError("invalid_request", "Action requires a name")
        }
        func fields(_ names: Set<JSONText>) throws {
            guard Set(object.keys) == names.union(["name"]) else {
                throw NativeInteractionError("invalid_request", "Unexpected or missing action fields")
            }
        }
        func text(_ key: String, maximum: Int = 4096, empty: Bool = false) throws -> JSONText {
            guard case .string(let value) = json[key], value.codeUnits.count <= maximum,
                  empty || !value.codeUnits.isEmpty else {
                throw NativeInteractionError("invalid_request", "Invalid action field: \(key)")
            }
            return value
        }
        func string(_ key: String, empty: Bool = false) throws -> String {
            let value = try text(key, empty: empty)
            guard JSONText(value.string) == value else {
                throw NativeInteractionError("invalid_request", "Invalid Unicode in \(key)")
            }
            return value.string
        }
        func number(_ key: String, limit: Double = 10000) throws -> Double {
            guard let value = json[key]?.numberValue, value.isFinite, abs(value) <= limit else {
                throw NativeInteractionError("invalid_request", "Invalid bounded number: \(key)")
            }
            return value
        }
        switch name {
        case "settings.open": try fields([]); self = .openSettings
        case "settings.close": try fields([]); self = .closeSettings
        case "settings.select": try fields(["section"]); self = .selectSettingsSection(try string("section"))
        case "settings.control":
            try fields(["controlId", "handle", "operation", "value"])
            self = .settingsControl(id: try string("controlId"), handle: try string("handle"),
                                    operation: try string("operation"), value: json["value"]!)
        case "reading.control":
            try fields(["controlId", "handle", "operation", "value"])
            self = .readingControl(id: try string("controlId"), handle: try string("handle"),
                                   operation: try string("operation"), value: json["value"]!)
        case "overview.show": try fields([]); self = .showOverview
        case "navigation.back": try fields([]); self = .back
        case "thread.open":
            try fields(["threadId", "typeId"])
            self = .openThread(try ApplicationThreadRef(threadID: text("threadId"), typeID: text("typeId")))
        case "search.begin": try fields([]); self = .beginSearch
        case "search.update": try fields(["query"]); self = .updateSearch(try string("query", empty: true))
        case "search.end": try fields([]); self = .endSearch
        case "filter.select":
            try fields(["filterId"])
            self = .selectFilter(json["filterId"] == .null ? nil : try string("filterId"))
        case "overview.pan":
            try fields(["deltaX", "deltaY"])
            self = .overviewPan(x: try number("deltaX"), y: try number("deltaY"))
        case "overview.zoom":
            try fields(["delta", "x", "y"])
            self = .overviewZoom(delta: try number("delta", limit: 1000), x: try number("x", limit: 1), y: try number("y", limit: 1))
        case "overview.auto": try fields([]); self = .overviewAuto
        case "overview.retry": try fields([]); self = .overviewRetry
        case "overview.directory.open": try fields(["directoryId"]); self = .overviewDirectoryOpen(try string("directoryId"))
        case "overview.directory.close": try fields(["directoryId"]); self = .overviewDirectoryClose(try string("directoryId"))
        case "overview.directory.select":
            try fields(["directoryId", "filterId"])
            self = .overviewDirectorySelect(directory: try string("directoryId"), filter: try string("filterId"))
        case "overview.filters.scroll": try fields(["filterId"]); self = .overviewScrollFilter(try string("filterId"))
        case "moku.input.toggle": try fields([]); self = .toggleMokuInput
        case "moku.history.toggle": try fields([]); self = .toggleMokuHistory
        case "moku.note.toggle": try fields([]); self = .toggleMokuNote
        default: throw NativeInteractionError("invalid_request", "Unknown action: \(name)")
        }
    }
}
