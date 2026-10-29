import Foundation
import Observation
import MokuseiCore

public enum DesktopAppearance: String, Codable, CaseIterable, Sendable {
    case system, light, dark


}

public enum DesktopLocale: String, Codable, CaseIterable, Sendable {
    case chinese = "zh-CN"
    case english = "en-US"

    public func text(_ chinese: String, _ english: String) -> String {
        self == .chinese ? chinese : english
    }
}

/// Client preferences remain available when the execution service is unavailable.
/// A successful setter means the new value was saved; failed writes leave it unchanged.
@MainActor @Observable
public final class DesktopPreferences {
    public private(set) var appearance: DesktopAppearance
    public private(set) var locale: DesktopLocale
    public private(set) var glassWorld: Bool
    public private(set) var selectedThreadID: String?
    public private(set) var onboardingCompleted: Bool
    public private(set) var onboardingPending: Bool
    public private(set) var readError: String?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored public var diagnostics = SettingsDiagnostics()

    private struct Preferences: Codable {
        var locale: DesktopLocale
        var appearance: DesktopAppearance
        var glassWorld: Bool

        private enum CodingKeys: String, CodingKey { case locale, appearance, glassWorld }

        init(locale: DesktopLocale, appearance: DesktopAppearance, glassWorld: Bool) {
            self.locale = locale; self.appearance = appearance; self.glassWorld = glassWorld
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            locale = try container.decode(DesktopLocale.self, forKey: .locale)
            appearance = try container.decode(DesktopAppearance.self, forKey: .appearance)
            glassWorld = try container.decodeIfPresent(Bool.self, forKey: .glassWorld) ?? true
        }
    }

    private struct SavedState: Codable {
        var preferences: Preferences
        var selectedThreadId: String?
        var onboardingCompleted: Bool?
    }

    public init(directory: URL) {
        let started = Date()
        fileURL = directory.appendingPathComponent("desktop-preferences.json")
        appearance = .system
        locale = .chinese
        glassWorld = true
        selectedThreadID = nil
        onboardingCompleted = false
        onboardingPending = false
        do {
            let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: fileURL))
            appearance = state.preferences.appearance
            locale = state.preferences.locale
            glassWorld = state.preferences.glassWorld
            selectedThreadID = state.selectedThreadId
            // A valid preexisting desktop file establishes prior use. Explicit
            // pending state must survive preference writes and interrupted setup.
            onboardingCompleted = state.onboardingCompleted ?? true
            onboardingPending = state.onboardingCompleted == false
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First launch has no saved client preferences.
        } catch {
            readError = error.localizedDescription
        }
        diagnostics.record(.preferences, readError == nil ? .completed : .failed,
                           durationMs: Date().timeIntervalSince(started) * 1000, fields: [.appearance, .locale, .glassWorld])
    }

    public func setAppearance(_ value: DesktopAppearance) throws {
        try savePreference(.appearance) { try persist(appearance: value, locale: locale, glassWorld: glassWorld, selectedThreadID: selectedThreadID) }
        appearance = value
    }

    public func setLocale(_ value: DesktopLocale) throws {
        try savePreference(.locale) { try persist(appearance: appearance, locale: value, glassWorld: glassWorld, selectedThreadID: selectedThreadID) }
        locale = value
    }

    public func setGlassWorld(_ value: Bool) throws {
        try savePreference(.glassWorld) { try persist(appearance: appearance, locale: locale, glassWorld: value, selectedThreadID: selectedThreadID) }
        glassWorld = value
    }

    public func selectThread(_ value: String?) throws {
        if let value, value.isEmpty || value.utf16.count > 128 {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try persist(appearance: appearance, locale: locale, glassWorld: glassWorld, selectedThreadID: value)
        selectedThreadID = value
    }

    public func setOnboardingCompleted(_ completed: Bool) throws {
        try persist(appearance: appearance, locale: locale, glassWorld: glassWorld,
                    selectedThreadID: selectedThreadID, onboardingCompleted: completed)
        onboardingCompleted = completed
        onboardingPending = !completed
    }

    private func persist(appearance: DesktopAppearance, locale: DesktopLocale, glassWorld: Bool,
                         selectedThreadID: String?, onboardingCompleted: Bool? = nil) throws {
        let data = try JSONEncoder().encode(SavedState(
            preferences: Preferences(locale: locale, appearance: appearance, glassWorld: glassWorld), selectedThreadId: selectedThreadID,
            onboardingCompleted: onboardingCompleted ?? self.onboardingCompleted
        ))
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".desktop-preferences.\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        // POSIX rename replaces the old file atomically without briefly removing it.
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func savePreference(_ field: SettingsDiagnostic.Field, _ write: () throws -> Void) throws {
        let started = Date()
        diagnostics.record(.preferences, .started, fields: [field])
        do {
            try write()
            diagnostics.record(.preferences, .saved, durationMs: Date().timeIntervalSince(started) * 1000, fields: [field])
        } catch {
            diagnostics.record(.preferences, .failed, durationMs: Date().timeIntervalSince(started) * 1000, fields: [field])
            throw error
        }
    }
}
