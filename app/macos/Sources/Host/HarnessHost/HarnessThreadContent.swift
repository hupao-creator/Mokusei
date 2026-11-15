import MokuseiCore
import MokuseiPluginAPI

/// Full thread content carries the complete Harness state plus the exact
/// runtime-owned execution titles for that same content revision. The catalog
/// itself never carries the title directory.
struct HarnessThreadContent: Hashable, Sendable {
    let state: JSONValue
    let executionTitles: [JSONText: JSONText]

    init(_ json: JSONValue) throws {
        guard case let .object(object) = json,
              object["version"] == .integer(1),
              let state = object["state"],
              object.keys.allSatisfy({ ["version", "state", "executionTitles"].contains($0) }) else {
            throw PluginContractError("thread content envelope is invalid")
        }
        self.state = state
        var titles: [JSONText: JSONText] = [:]
        if let value = object["executionTitles"], value != .null {
            guard case let .object(entries) = value else {
                throw PluginContractError("thread content executionTitles must be an object")
            }
            for (id, title) in entries {
                guard !id.codeUnits.contains(0), !id.codeUnits.isEmpty, case let .string(text) = title,
                      !text.codeUnits.isEmpty, !text.codeUnits.contains(0) else {
                    throw PluginContractError("thread content executionTitles contains an invalid entry")
                }
                titles[id] = text
            }
        }
        executionTitles = titles
    }
}
