import Foundation
import MokuseiCore
import MokuseiPluginAPI
import MokuseiPluginUI
import SwiftUI

/// Helpers are local to the shipped Application plugins, never part of Core's
/// view dispatcher. Every owner still supplies and validates its concrete DTOs.
struct NativeApplicationRecord {
    let fields: [JSONText: JSONValue]
    let path: String
    init(_ value: JSONValue, path: String, keys: Set<JSONText>? = nil) throws {
        guard case .object(let fields) = value else { throw PluginContractError("\(path) must be an object") }
        if let keys, !Set(fields.keys).isSubset(of: keys) { throw PluginContractError("Unknown \(path) field") }
        self.fields = fields; self.path = path
    }
    func require(_ key: String) throws -> JSONValue {
        guard let value = fields[JSONText(key)] else { throw PluginContractError("Missing \(path).\(key)") }; return value
    }
    func text(_ key: String) throws -> JSONText {
        guard case .string(let value) = try require(key) else { throw PluginContractError("\(path).\(key) must be text") }; return value
    }
    func identifier(_ key: String, maximum: Int = 128) throws -> JSONText {
        let result = try text(key)
        let forbidden: Set<UInt16> = [0, 9, 10, 11, 12, 13, 32, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002,
                                     0x2003, 0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A,
                                     0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
        guard !result.codeUnits.isEmpty, result.codeUnits.count <= maximum,
              !result.codeUnits.contains(where: forbidden.contains) else {
            throw PluginContractError("Invalid \(path).\(key) identity")
        }
        return result
    }
    func array(_ key: String) throws -> [JSONValue] {
        guard case .array(let value) = try require(key) else { throw PluginContractError("\(path).\(key) must be an array") }; return value
    }
    func bool(_ key: String) throws -> Bool {
        guard case .bool(let value) = try require(key) else { throw PluginContractError("\(path).\(key) must be boolean") }; return value
    }
    func integer(_ key: String) throws -> Int {
        guard let value = try require(key).intValue, (0...9_007_199_254_740_991).contains(value) else {
            throw PluginContractError("\(path).\(key) must be a nonnegative safe integer")
        }; return value
    }
}

func applicationText(_ locale: JSONText, _ chinese: String, _ english: String) -> String { locale == "en-US" ? english : chinese }

struct NativeApplicationFailure: View {
    let message: String
    var body: some View {
        Text(message).font(.system(size: 12)).foregroundStyle(NativeAppKitPalette.thread.danger.swiftUI)
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .accessibilityLabel(message)
    }
}

struct NativeBackgroundSettingsView: View {
    let props: ApplicationSettingsProps<ApplicationBackgroundExecutionSettings>
    let description: String
    @Environment(\.nativeSettingsOnboarding) private var onboarding
    var body: some View {
        if onboarding { editor }
        else { NativeSettingsGroup(description: description) { editor } }
    }
    @ViewBuilder private var editor: some View {
        switch Result(catching: { try props.capabilities.require(ApplicationCapabilities.backgroundConfigurationUI) }) {
        case .failure(let error): NativeApplicationFailure(message: error.localizedDescription)
                .nativeSettingsEditorReady(false)
        case .success(let capability): capability.editor(value: props.value, change: props.change)
        }
    }

}

@MainActor func nativeBackgroundSettingsKey(_ id: JSONText, owner: JSONText) -> ApplicationValueKey<ApplicationBackgroundExecutionSettings> {
    .init(id: id, ownerPluginID: owner, codec: .init(decode: ApplicationBackgroundExecutionSettings.init,
                                                   encode: { $0.json }))
}
