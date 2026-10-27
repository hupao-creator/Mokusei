import CoreData
import Foundation
import MokuseiCore

/// Linked with production DesktopPreferences.swift and the built Core module.
/// This process deliberately never starts or acquires a runtime owner.
/// CoreData supplies the Cocoa validation-error extensions also visible in Host.
@main
struct OfflineClientReplay {
    @MainActor
    static func main() throws {
        if ProcessInfo.processInfo.environment["MOKUSEI_OFFLINE_HOME_PROBE"] == "1" {
            try emit(FileManager.default.homeDirectoryForCurrentUser.path)
            return
        }
        let arguments = CommandLine.arguments
        guard let identity = ProcessInfo.processInfo.environment["MOKUSEI_OFFLINE_CLIENT_ID"],
              !identity.isEmpty, identity.utf8.count <= 64, !identity.contains(where: \.isWhitespace) else {
            throw RuntimeError("FIXTURE_ARGUMENTS", "Expected a fixture identity")
        }
        let selectedDirectory: URL
        if arguments.count == 3, arguments[1] == "--data-dir", arguments[2].hasPrefix("/") {
            selectedDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        } else if arguments.count == 1 {
            let name = Bundle.main.object(forInfoDictionaryKey: "MokuseiDataDirectoryName") as? String ?? "Mokusei"
            selectedDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/\(name)", isDirectory: true)
        } else {
            throw RuntimeError("FIXTURE_ARGUMENTS", "Expected no arguments or --data-dir /absolute/path")
        }
        var scopedLease: RuntimeProfileClientLease?
        let profile: RuntimeProfile
        do {
            if ProcessInfo.processInfo.environment["MOKUSEI_OFFLINE_PROCESS_LEASE"] == "1" {
                profile = try processRetainedProfile(selectedDirectory)
            } else {
                let lease = try RuntimeProfileClientLease(dataDirectory: selectedDirectory)
                scopedLease = lease
                profile = lease.profile
            }
        } catch let error as RuntimeError {
            try emit("blocked \(error.code)")
            return
        }
        defer { withExtendedLifetime(scopedLease) {} }
        let directory = profile.dataDirectory
        let preferences = DesktopPreferences(directory: directory)
        let drafts = RuntimeDraftStore(storageDirectory: directory, scope: "offline-client-replay")
        if ProcessInfo.processInfo.environment["MOKUSEI_OFFLINE_REPORT_READ"] == "1" {
            let loaded: JSONValue = .object([
                "selectedThread": preferences.selectedThreadID.map { .text($0) } ?? .null,
                "draft": try drafts.load() ?? .null
            ])
            try emit("loaded " + String(decoding: loaded.encodedData(), as: UTF8.self))
        }
        var sequence = 1
        try persist(sequence, identity: identity, directory: directory, preferences: preferences, drafts: drafts)
        try emit("ready \(identity) \(sequence)")
        for _ in 0..<16 {
            guard let command = readLine() else { return }
            guard command.utf8.count <= 64 else { throw RuntimeError("FIXTURE_COMMAND", "Fixture command exceeds its bound") }
            if command == "quit" { try emit("bye"); return }
            let fields = command.split(separator: " ")
            guard fields.count == 2, fields[0] == "write", let next = Int(fields[1]), next == sequence + 1, next <= 8 else {
                throw RuntimeError("FIXTURE_COMMAND", "Expected the next bounded write sequence or quit")
            }
            sequence = next
            try persist(sequence, identity: identity, directory: directory, preferences: preferences, drafts: drafts)
            try emit("written \(sequence)")
        }
        throw RuntimeError("FIXTURE_COMMAND", "Fixture command count exceeded its bound")
    }

    private static func processRetainedProfile(_ directory: URL) throws -> RuntimeProfile {
        let lease = try RuntimeProfileClientLease(dataDirectory: directory)
        lease.retainForProcess()
        return lease.profile
    }

    @MainActor
    private static func persist(_ sequence: Int, identity: String, directory: URL,
                                preferences: DesktopPreferences, drafts: RuntimeDraftStore) throws {
        let appearance: DesktopAppearance = sequence.isMultiple(of: 2) ? .light : .dark
        let locale: DesktopLocale = sequence.isMultiple(of: 2) ? .english : .chinese
        let glassWorld = sequence.isMultiple(of: 2)
        let thread = "\(identity)-thread-\(sequence)"
        let draft: JSONValue = .object(["text": .text("\(identity)-draft-\(sequence)"), "revision": .integer(sequence)])
        try preferences.setAppearance(appearance)
        try preferences.setLocale(locale)
        try preferences.setGlassWorld(glassWorld)
        try preferences.selectThread(thread)
        try drafts.save(draft)
        let loaded = DesktopPreferences(directory: directory)
        guard loaded.readError == nil, loaded.appearance == appearance, loaded.locale == locale,
              loaded.glassWorld == glassWorld, loaded.selectedThreadID == thread, try drafts.load() == draft else {
            throw RuntimeError("FIXTURE_PERSISTENCE", "Production preferences or draft failed their disk round trip")
        }
    }

    private static func emit(_ line: String) throws {
        try FileHandle.standardOutput.write(contentsOf: Data((line + "\n").utf8))
    }
}
