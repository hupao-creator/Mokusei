import MokuseiCore

/// Shared settings shape; the Harness slices remain opaque to application plugins.
public struct ApplicationBackgroundExecutionSettings: Hashable, Sendable {
    public struct Overrides: Hashable, Sendable {
        public let harnessPreference: JSONText
        public let harnesses: [JSONText: JSONValue]
        public init(harnessPreference: JSONText, harnesses: [JSONText: JSONValue]) throws {
            guard !harnessPreference.codeUnits.isEmpty, harnesses.values.allSatisfy({
                if case .object = $0 { return true }; return false
            }) else { throw PluginContractError("Invalid independent background execution settings") }
            try PluginJSONValidation.validate(.object(harnesses))
            self.harnessPreference = harnessPreference; self.harnesses = harnesses
        }
        public var json: JSONValue { .object(["harnessPreference": .string(harnessPreference), "harnesses": .object(harnesses)]) }
    }
    public enum Mode: Hashable, Sendable {
        case inherit(independent: Overrides?)
        case override(Overrides)
    }
    public let mode: Mode
    public init(mode: Mode) { self.mode = mode }
    public init(json: JSONValue) throws {
        try PluginJSONValidation.validate(json)
        let r = try ApplicationRecordReader(json, path: "background execution settings")
        let kind = try r.text("mode")
        if kind == "inherit" {
            guard Set(r.fields.keys).isSubset(of: ["mode", "independent"]) else {
                throw PluginContractError("Unknown inherited background execution field")
            }
            if let value = r.fields["independent"] {
                let independent = try ApplicationRecordReader(value, path: "background independent settings")
                guard Set(independent.fields.keys).isSubset(of: ["harnessPreference", "harnesses"]) else {
                    throw PluginContractError("Unknown independent background execution field")
                }
                mode = .inherit(independent: try Self.overrides(independent))
            } else { mode = .inherit(independent: nil) }
        } else if kind == "override" {
            guard Set(r.fields.keys).isSubset(of: ["mode", "harnessPreference", "harnesses"]) else {
                throw PluginContractError("Unknown overridden background execution field")
            }
            mode = .override(try Self.overrides(r))
        } else { throw PluginContractError("Unknown background execution mode") }
    }
    public var json: JSONValue {
        var fields: [JSONText: JSONValue]
        switch mode {
        case .inherit(let independent):
            fields = ["mode": .text("inherit")]
            fields["independent"] = independent?.json
        case .override(let overrides):
            fields = ["mode": .text("override"), "harnessPreference": .string(overrides.harnessPreference), "harnesses": .object(overrides.harnesses)]
        }
        return .object(fields)
    }
    private static func overrides(_ record: ApplicationRecordReader) throws -> Overrides {
        guard case .object(let harnesses) = try record.require("harnesses") else { throw PluginContractError("Background harness settings must be an object") }
        return try Overrides(harnessPreference: record.text("harnessPreference"), harnesses: harnesses)
    }
}
