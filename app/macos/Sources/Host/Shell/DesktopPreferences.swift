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
    public private(set) var selectedThreadID: String?
    public private(set) var applicationLastOpened: [String: Double] = [:]
    public private(set) var applicationCollectionReading: [String: ApplicationCollectionReading] = [:]
    public private(set) var onboardingCompleted: Bool
    public private(set) var onboardingPending: Bool
    public private(set) var readError: String?
    @ObservationIgnored private let fileURL: URL

    private struct Preferences: Codable {
        var locale: DesktopLocale
        var appearance: DesktopAppearance
    }

    private struct SavedState: Codable {
        var preferences: Preferences
        var selectedThreadId: String?
        var onboardingCompleted: Bool?
        var applicationLastOpened: [String: Double]?
        var applicationCollectionReading: [String: ApplicationCollectionReading]?
    }

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("desktop-preferences.json")
        appearance = .system
        locale = .chinese
        selectedThreadID = nil
        onboardingCompleted = false
        onboardingPending = false
        do {
            let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: fileURL))
            appearance = state.preferences.appearance
            locale = state.preferences.locale
            selectedThreadID = state.selectedThreadId
            if let opened = state.applicationLastOpened {
                guard opened.allSatisfy({ !$0.key.isEmpty && $0.key.utf16.count <= 512 && $0.value.isFinite && $0.value >= 0 }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                applicationLastOpened = opened
            }
            if let reading = state.applicationCollectionReading {
                guard reading.allSatisfy({ !$0.key.isEmpty && $0.key.utf16.count <= 512
                    && $0.value.valid }) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                applicationCollectionReading = reading
            }
            // A valid preexisting desktop file establishes prior use. Explicit
            // pending state must survive preference writes and interrupted setup.
            onboardingCompleted = state.onboardingCompleted ?? true
            onboardingPending = state.onboardingCompleted == false
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // First launch has no saved client preferences.
        } catch {
            readError = error.localizedDescription
        }
    }

    public func recordApplicationReading(key: String, value: ApplicationCollectionReading) throws {
        guard !key.isEmpty, key.utf16.count <= 512,
              value.valid else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        var reading = applicationCollectionReading
        reading[key] = value
        try persist(appearance: appearance, locale: locale, selectedThreadID: selectedThreadID,
                    applicationCollectionReading: reading)
        applicationCollectionReading = reading
    }

    public func setAppearance(_ value: DesktopAppearance) throws {
        try persist(appearance: value, locale: locale, selectedThreadID: selectedThreadID)
        appearance = value
    }

    public func setLocale(_ value: DesktopLocale) throws {
        try persist(appearance: appearance, locale: value, selectedThreadID: selectedThreadID)
        locale = value
    }

    public func selectThread(_ value: String?) throws {
        if let value, value.isEmpty || value.utf16.count > 128 {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        try persist(appearance: appearance, locale: locale, selectedThreadID: value)
        selectedThreadID = value
    }

    public func setOnboardingCompleted(_ completed: Bool) throws {
        try persist(appearance: appearance, locale: locale,
                    selectedThreadID: selectedThreadID, onboardingCompleted: completed)
        onboardingCompleted = completed
        onboardingPending = !completed
    }

    private func persist(appearance: DesktopAppearance, locale: DesktopLocale,
                         selectedThreadID: String?, onboardingCompleted: Bool? = nil,
                         applicationLastOpened: [String: Double]? = nil,
                         applicationCollectionReading: [String: ApplicationCollectionReading]? = nil) throws {
        let data = try JSONEncoder().encode(SavedState(
            preferences: Preferences(locale: locale, appearance: appearance), selectedThreadId: selectedThreadID,
            onboardingCompleted: onboardingCompleted ?? self.onboardingCompleted,
            applicationLastOpened: applicationLastOpened ?? self.applicationLastOpened,
            applicationCollectionReading: applicationCollectionReading ?? self.applicationCollectionReading
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

}
