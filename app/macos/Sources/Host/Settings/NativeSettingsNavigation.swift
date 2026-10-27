import CoreGraphics
import Foundation
import Observation
import MokuseiPluginAPI
import MokuseiPluginUI

/// The page and programmatic navigation share the same section and close gate.
@MainActor @Observable
public final class NativeSettingsNavigation {
    public var section: String
    public private(set) var focusRequest = 0
    public var mounted = false
    public var visit = UUID()
    public let interactions = NativeSettingsInteractions()
    public func interactionContext(section: String) -> NativeSettingsInteractionContext { .init(visit: visit, section: section) }
    public var returnRect = CGRect.zero

    public init(section: String = "moku") { self.section = section }

    public static func sections(model: NativeSettingsModel, applications: [NativeApplicationSettingsSection]) -> [String] {
        ["general", "moku"] + applications.filter { definition in
            model.plugins.first { $0.key == "extension:\(definition.owner)" }?.enabled != false
        }.map(\.id)
    }

    public func closeBlockReason(model: NativeSettingsModel) -> String? {
        if model.clearing { return "Settings are clearing history" }
        if model.runtimeAvailable, model.draft.firstInvalidField != nil { return "Settings contain an invalid field" }
        if model.runtimeAvailable, model.draft.composing { return "Settings contain an active text composition" }
        return nil
    }

    @discardableResult
    public func requestClose(model: NativeSettingsModel, onClose: (CGRect) -> Void) -> Bool {
        guard !model.clearing else { return false }
        if model.runtimeAvailable, model.draft.firstInvalidField != nil {
            section = "moku"; focusRequest += 1
            return false
        }
        guard model.draft.prepareClose() else { return false }
        onClose(returnRect)
        return true
    }
}
