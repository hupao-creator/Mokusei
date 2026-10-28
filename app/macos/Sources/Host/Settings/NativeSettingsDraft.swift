import Foundation
import Observation
import MokuseiCore

public enum NativeSettingsSaveResult: Sendable {
    case saved(settings: JSONValue, revision: Int)
    case conflict(settings: JSONValue, revision: Int)
}

/// Retained by the workspace, including while the settings page is closed.
/// A failed write owns its draft until that same write succeeds or is discarded.
@MainActor @Observable
public final class NativeSettingsDraft {
    public enum Status: Sendable { case idle, pending, saving, saved, error }
    public private(set) var value: JSONValue
    public private(set) var saved: JSONValue
    public private(set) var revision: Int
    public private(set) var status: Status = .idle
    public private(set) var error: String?
    public private(set) var conflicted = false
    @ObservationIgnored public var diagnostics = SettingsDiagnostics()
    public var runtimeAvailable = false {
        didSet {
            guard !retired else { timer?.cancel(); timer = nil; return }
            if oldValue != runtimeAvailable { diagnostics.record(.availability, runtimeAvailable ? .available : .unavailable, revision: revision) }
            if !runtimeAvailable { timer?.cancel(); timer = nil }
            else if !failed && Self.comparableValue(value) != saved { submit() }
        }
    }
    public var composing = false {
        didSet {
            guard !retired else { return }
            if oldValue != composing { diagnostics.record(.composition, composing ? .started : .completed, revision: revision) }
            if composing { timer?.cancel(); timer = nil } else if oldValue { schedule() }
        }
    }
    public var onClosedSaveError: ((String) -> (() -> Void))?
    @ObservationIgnored private let save: (JSONValue, Int) async throws -> NativeSettingsSaveResult
    @ObservationIgnored private var ready: JSONValue
    @ObservationIgnored private var latest: (JSONValue, Int)
    @ObservationIgnored private var conflict: (JSONValue, Int)?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var running: Task<Bool, Never>?
    @ObservationIgnored private var failed = false
    @ObservationIgnored private var dismissReportedError: (() -> Void)?
    @ObservationIgnored private var retired = false
    @ObservationIgnored private var editingFields = Set<SettingsDiagnostic.Field>()

    public init(settings: JSONValue, revision: Int,
                save: @escaping (JSONValue, Int) async throws -> NativeSettingsSaveResult) {
        value = settings; saved = settings; ready = settings; self.revision = revision
        latest = (settings, revision); self.save = save
    }

    public func receive(settings: JSONValue, revision: Int) {
        guard !retired else { return }
        guard revision >= latest.1 else { return }
        if revision > latest.1 { diagnostics.record(.receive, .completed, revision: revision) }
        latest = (settings, revision)
        if running == nil && !failed && Self.comparableValue(value) == saved && revision >= self.revision {
            adopt(settings: settings, revision: revision)
        }
    }

    public func change(_ next: JSONValue, textEdit: Bool = false) {
        guard !retired, runtimeAvailable else { return }
        let fields = SettingsDiagnostic.changedFields(value, next)
        let newFields = fields.filter { !editingFields.contains($0) }
        editingFields.formUnion(fields)
        if !newFields.isEmpty { diagnostics.record(.edit, textEdit || composing ? .pending : .started, revision: revision, fields: newFields) }
        value = next
        if textEdit || composing { schedule() } else { submit() }
    }

    public func validationError(_ field: String, locale: DesktopLocale) -> String? {
        let length = settingsTrimCodeUnits(value["moku"]?[field]).count
        guard length > 12_000 else { return nil }
        return locale.text("模型路由指导最多 12000 个字符（UTF-16 计数），当前 \(length) 个。",
                           "Model routing guidance must be at most 12000 UTF-16 code units; current length: \(length).")
    }

    public var firstInvalidField: String? {
        validationError("routingGuidance", locale: .chinese) == nil ? nil : "routingGuidance"
    }

    public func flushText() { if !retired, !composing { submit() } }

    /// Quit must join the accepted settings write before Runtime teardown makes
    /// the draft unavailable. The application's existing quit deadline bounds it.
    public func flushForQuit() async throws {
        guard !retired else { return }
        guard !composing, firstInvalidField == nil else {
            throw RuntimeError("SETTINGS_UNSAVED", "Finish the active settings edit before quitting, or quit without saving.")
        }
        if value == saved, running == nil, !failed { return }
        submit()
        if let pending = running, !(await pending.value) {
            throw RuntimeError("SETTINGS_UNSAVED", error ?? "Settings could not be saved.")
        }
        let intended = settingsReplacing(value, path: ["moku", "routingGuidance"], value: Self.normalizedText(value["moku"]?["routingGuidance"]))
        guard !failed, ready == saved, intended == saved else {
            throw RuntimeError("SETTINGS_UNSAVED", error ?? "Settings have unsaved changes.")
        }
    }

    /// Full workspace reload discards this page's local draft. A request that
    /// already reached the runtime may finish, but cannot drain another write.
    public func discardForReload() {
        guard !retired else { return }
        diagnostics.record(.discard, .completed, revision: revision)
        retired = true
        timer?.cancel(); timer = nil
        runtimeAvailable = false
        onClosedSaveError = nil
        dismissReport()
    }

    /// Starts persistence synchronously, then lets the page animate closed.
    /// The workspace must retain this object so the result can report globally.
    public func prepareClose() -> Bool {
        guard !retired else { return true }
        guard runtimeAvailable else { return true }
        guard !composing, firstInvalidField == nil else { diagnostics.record(.close, .blocked, revision: revision); return false }
        diagnostics.record(.close, .started, revision: revision)
        submit()
        let pending = running
        Task { [weak self] in
            _ = await pending?.value
            guard let self, !self.retired, let error = self.error else { return }
            self.dismissReportedError = self.onClosedSaveError?(error)
        }
        return true
    }

    public func retry() {
        guard !retired else { return }
        diagnostics.record(.retry, .started, revision: revision)
        if conflict != nil { resolveConflict(keepDraft: true) }
        else { failed = false; submit() }
    }

    public func discardConflict() { resolveConflict(keepDraft: false) }

    private func resolveConflict(keepDraft: Bool) {
        guard !retired, let remote = conflict, running == nil else { return }
        diagnostics.record(.conflict, keepDraft ? .keep : .discard, revision: remote.1)
        timer?.cancel(); timer = nil
        let authoritative = latest.1 > remote.1 ? latest : remote
        value = keepDraft ? Self.rebase(base: saved, draft: value, latest: authoritative.0) : authoritative.0
        ready = keepDraft ? Self.rebase(base: saved, draft: ready, latest: authoritative.0) : authoritative.0
        saved = authoritative.0; revision = authoritative.1
        conflict = nil; conflicted = false; failed = false; error = nil
        if keepDraft { submit() } else { status = .saved; dismissReport() }
    }

    private func schedule() {
        guard !retired else { return }
        timer?.cancel(); timer = nil
        if !failed && running == nil { status = .pending }
        guard !composing else { return }
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.timer = nil; self.submit()
        }
    }

    private func submit() {
        timer?.cancel(); timer = nil
        guard !retired, !composing, runtimeAvailable else { return }
        var next = value
        if firstInvalidField != nil { diagnostics.record(.validation, .blocked, revision: revision,
            fields: [.routing]) }
        next = settingsReplacing(next, path: ["moku", "routingGuidance"], value: firstInvalidField == nil
            ? Self.normalizedText(value["moku"]?["routingGuidance"]) : ready["moku"]?["routingGuidance"])
        ready = next
        guard running == nil, conflict == nil else { return }
        if ready == saved {
            failed = false; error = nil; status = .saved
            if Self.comparableValue(value) == saved, latest.1 > revision {
                adopt(settings: latest.0, revision: latest.1)
            }
            dismissReport(); return
        }
        status = .saving; failed = false; error = nil
        running = Task { [weak self] in
            guard let self else { return false }
            defer {
                self.running = nil
                if !self.retired, !self.failed, Self.comparableValue(self.value) == self.saved, self.latest.1 > self.revision {
                    self.adopt(settings: self.latest.0, revision: self.latest.1)
                }
            }
            while self.ready != self.saved {
                guard !self.retired else { return false }
                guard self.runtimeAvailable else { self.status = .pending; return false }
                let snapshot = self.ready
                let submittedRouting = self.value["moku"]?["routingGuidance"]
                let started = Date()
                self.editingFields.removeAll()
                self.diagnostics.record(.save, .started, revision: self.revision, fields: SettingsDiagnostic.changedFields(self.saved, snapshot))
                do {
                    let result = try await SettingsDiagnosticContext.$flowID.withValue(self.diagnostics.flowID) {
                        try await self.save(snapshot, self.revision)
                    }
                    guard !self.retired else { return false }
                    switch result {
                    case let .conflict(settings, revision):
                        self.diagnostics.record(.save, .conflict, revision: revision, durationMs: Date().timeIntervalSince(started) * 1000)
                        self.conflict = (settings, revision); self.conflicted = true; self.failed = true
                        self.error = "设置已被其他客户端修改，草稿已保留。保留我的修改并重试会合并独立修改，并以我的修改处理相同字段。"
                        self.status = .error; return false
                    case let .saved(settings, revision):
                        self.diagnostics.record(.save, .saved, revision: revision, durationMs: Date().timeIntervalSince(started) * 1000)
                        // Keep the exact editable text after a normalized save:
                        // changing its UTF-16 ranges invalidates native Undo.
                        // Explicitly clearing saved guidance still closes it.
                        var current = self.value
                        if self.firstInvalidField == nil,
                           snapshot["moku"]?["routingGuidance"] != self.saved["moku"]?["routingGuidance"],
                           current["moku"]?["routingGuidance"] == submittedRouting,
                           Self.normalizedText(submittedRouting) == .null,
                           snapshot["moku"]?["routingGuidance"] == .null {
                            current = settingsReplacing(current, path: ["moku", "routingGuidance"], value: .null)
                        }
                        self.value = Self.rebase(base: snapshot, draft: current, latest: settings)
                        self.ready = Self.rebase(base: snapshot, draft: self.ready, latest: settings)
                        self.saved = settings; self.revision = revision
                    }
                } catch {
                    self.diagnostics.record(.save, .failed, revision: self.revision, durationMs: Date().timeIntervalSince(started) * 1000)
                    guard !self.retired else { return false }
                    // A newer edit may have fixed the rejected combination while
                    // native validation was still running. Drain that edit before
                    // reporting an error for a value no longer shown in the UI.
                    if self.ready != snapshot { self.diagnostics.record(.retry, .pending, revision: self.revision); continue }
                    self.failed = true; self.error = error.localizedDescription; self.status = .error
                    return false
                }
            }
            self.status = self.timer != nil || self.composing || self.firstInvalidField != nil ? .pending : .saved
            self.dismissReport(); return true
        }
    }

    private func dismissReport() { dismissReportedError?(); dismissReportedError = nil }
    private func adopt(settings: JSONValue, revision: Int) {
        let routing = value["moku"]?["routingGuidance"]
        let keepEditableText = Self.normalizedText(routing) == saved["moku"]?["routingGuidance"]
            && settings["moku"]?["routingGuidance"] == saved["moku"]?["routingGuidance"]
        value = settings
        if keepEditableText { value = settingsReplacing(value, path: ["moku", "routingGuidance"], value: routing) }
        saved = settings; ready = settings; self.revision = revision
    }
    private static func comparableValue(_ value: JSONValue) -> JSONValue {
        let routing = normalizedText(value["moku"]?["routingGuidance"])
        guard routing != .null else { return value }
        return settingsReplacing(value, path: ["moku", "routingGuidance"], value: routing)
    }
    private static func normalizedText(_ value: JSONValue?) -> JSONValue {
        let units = settingsTrimCodeUnits(value)
        return units.isEmpty ? .null : .string(JSONText(codeUnits: units))
    }

    /// Core objects merge by field. Every plugin-owned record stays indivisible.
    public static func rebase(base: JSONValue, draft: JSONValue, latest: JSONValue) -> JSONValue {
        var result = recursiveRebase(base, draft, latest)
        for path in [["harnesses"], ["moku", "executionHarnesses"]] {
            let before = settingsAt(base, path: path)?.objectValue ?? [:]
            let local = settingsAt(draft, path: path)?.objectValue ?? [:]
            var merged = settingsAt(latest, path: path)?.objectValue ?? [:]
            for key in Set(before.keys).union(local.keys) where before[key] != local[key] { merged[key] = local[key] }
            result = settingsReplacing(result, path: path, value: .object(merged))
        }
        let before = keyedEntries(base["pluginSettings"]), local = keyedEntries(draft["pluginSettings"])
        var merged = keyedEntries(latest["pluginSettings"])
        for key in Set(before.keys).union(local.keys) where before[key] != local[key] { merged[key] = local[key] }
        var ordered = (latest["pluginSettings"]?.arrayValue ?? []).compactMap { $0["id"] }
        for entry in draft["pluginSettings"]?.arrayValue ?? [] {
            if let id = entry["id"], !ordered.contains(id) { ordered.append(id) }
        }
        return settingsReplacing(result, path: ["pluginSettings"], value: .array(ordered.compactMap { merged[$0] }))
    }

    private static func keyedEntries(_ value: JSONValue?) -> [JSONValue: JSONValue] {
        (value?.arrayValue ?? []).reduce(into: [:]) { result, entry in if let id = entry["id"] { result[id] = entry } }
    }
    private static func recursiveRebase(_ base: JSONValue?, _ draft: JSONValue?, _ latest: JSONValue?) -> JSONValue {
        if base == draft { return latest ?? .null }
        guard let before = base?.objectValue, let local = draft?.objectValue, var result = latest?.objectValue else { return draft ?? .null }
        for key in Set(before.keys).union(local.keys) where before[key] != local[key] {
            if local[key] == nil { result.removeValue(forKey: key) }
            else { result[key] = recursiveRebase(before[key], local[key], result[key]) }
        }
        return .object(result)
    }
}

/// ECMAScript String.trim whitespace, including BOM and excluding U+0085.
private func settingsTrimCodeUnits(_ value: JSONValue?) -> [UInt16] {
    guard case .string(let text) = value else { return [] }
    let whitespace: Set<UInt16> = [0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x00A0, 0x1680,
                                  0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005, 0x2006, 0x2007,
                                  0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF]
    let units = text.codeUnits
    let start = units.firstIndex { !whitespace.contains($0) } ?? units.endIndex
    let end = units.lastIndex { !whitespace.contains($0) }.map { $0 + 1 } ?? start
    return Array(units[start..<end])
}

func settingsAt(_ value: JSONValue, path: [String]) -> JSONValue? {
    path.reduce(Optional(value)) { current, key in current?[key] }
}

func settingsReplacing(_ original: JSONValue, path: [String], value: JSONValue?) -> JSONValue {
    guard let key = path.first else { return value ?? .null }
    var fields = original.objectValue ?? [:]
    if path.count == 1 { fields[JSONText(key)] = value }
    else { fields[JSONText(key)] = settingsReplacing(fields[JSONText(key)] ?? .object([:]), path: Array(path.dropFirst()), value: value) }
    return .object(fields)
}
