import Foundation
import OSLog

/// Closed vocabulary shared with SettingsDiagnosticSchema. Never accept settings
/// values, filesystem paths, native error messages, or arbitrary metadata.
public struct SettingsDiagnostic: Sendable {
    public enum Event: String, Sendable {
        case page, edit, composition, close, retry, conflict, validation, save, command, receive, availability, discard, preferences, presentation
    }
    public enum Outcome: String, Sendable {
        case started, completed, failed, pending, blocked, saved, conflict, keep, discard, available, unavailable, opened, closed
    }
    public enum Field: String, Sendable, CaseIterable {
        case host = "moku.hostHarnessPreference", execution = "moku.executionHarnesses", targets = "moku.targetHarnessIds"
        case routing = "moku.routingGuidance"
        case harnesses, pluginSettings, pluginEnabled, appearance, locale, glassWorld
    }
    private static let logger = Logger(subsystem: "com.mokusei.desktop", category: "settings")
    let json: JSONValue

    public init(_ event: Event, _ outcome: Outcome, flowID: String, operationID: String? = nil,
                revision: Int? = nil, durationMs: Double? = nil, fields: [Field] = []) {
        var value: [JSONText: JSONValue] = ["event": .text(event.rawValue), "outcome": .text(outcome.rawValue), "flowId": .text(flowID)]
        if let operationID { value["operationId"] = .text(operationID) }
        if let revision, revision >= 0 { value["revision"] = .integer(revision) }
        if let durationMs { value["durationMs"] = .number(max(0, durationMs)) }
        if !fields.isEmpty { value["fields"] = .array(fields.map { .text($0.rawValue) }) }
        json = .object(value)
        if let data = try? json.encodedData(), let line = String(data: data, encoding: .utf8) {
            Self.logger.info("\(line, privacy: .public)")
        }
    }

    public static func changedFields(_ before: JSONValue, _ after: JSONValue) -> [Field] {
        Field.allCases.filter { field in
            let path = field.rawValue.split(separator: ".").map(String.init)
            func read(_ value: JSONValue) -> JSONValue? { path.reduce(Optional(value)) { $0?[$1] } }
            return read(before) != read(after)
        }
    }
}

public enum SettingsDiagnosticContext {
    @TaskLocal public static var flowID: String?
}

/// One flow per retained settings draft/surface, also usable entirely offline.
@MainActor public final class SettingsDiagnostics {
    public let flowID = UUID().uuidString
    private let client: RuntimeClient?
    public init(client: RuntimeClient? = nil) { self.client = client }
    public func record(_ event: SettingsDiagnostic.Event, _ outcome: SettingsDiagnostic.Outcome,
                       revision: Int? = nil, durationMs: Double? = nil, fields: [SettingsDiagnostic.Field] = []) {
        let diagnostic = SettingsDiagnostic(event, outcome, flowID: flowID, revision: revision, durationMs: durationMs, fields: fields)
        if let client { Task { await client.reportSettingsDiagnostic(diagnostic) } }
    }
}

extension RuntimeClient {
    /// At most 64 pending events and one request; no receipt, retry, service
    /// launch, or user-facing error. The existing local JSONL sink owns rotation.
    public func reportSettingsDiagnostic(_ event: SettingsDiagnostic) {
        guard !closed, !explicitlyStopped, connection != nil else { return }
        if settingsDiagnosticsQueue.count < 64 { settingsDiagnosticsQueue.append(event.json) }
        guard settingsDiagnosticsTask == nil else { return }
        settingsDiagnosticsTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            await self?.drainSettingsDiagnostics()
        }
    }

    private func drainSettingsDiagnostics() async {
        defer { settingsDiagnosticsTask = nil }
        while !settingsDiagnosticsQueue.isEmpty {
            let batch = Array(settingsDiagnosticsQueue.prefix(32))
            settingsDiagnosticsQueue.removeFirst(batch.count)
            guard !closed, !explicitlyStopped, let owner = connection else { settingsDiagnosticsQueue.removeAll(); return }
            let id = UUID().uuidString
            guard let body = try? runtimeObject(["commandId": .text(id), "args": .array([.array(batch)])]).encodedData() else { continue }
            do {
                _ = try await transport.request(connection: owner, path: "/invoke/settings:diagnostics", method: "POST", body: body, timeout: 2)
            } catch { settingsDiagnosticsQueue.removeAll(); return }
        }
    }
}
