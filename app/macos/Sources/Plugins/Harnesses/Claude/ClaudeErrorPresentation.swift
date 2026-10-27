import Foundation
import MokuseiCore
import MokuseiPluginAPI
import os

/// What the thread surface renders when its native state cannot be projected.
/// The primary message is always the most actionable failure: a Harness, CLI
/// or upstream execution error outranks a private-state decode failure.
struct ClaudeFailurePresentation: Hashable, Sendable {
    let message: String
    let detail: String?
}

func claudeFailurePresentation(_ input: HarnessThreadInput, decodeError: Error) -> ClaudeFailurePresentation {
    let decode = claudeTrimmed(claudeRedacted(decodeError.localizedDescription))
    if let harness = claudeHarnessFailure(input.thread.observation) {
        return ClaudeFailurePresentation(message: harness, detail: decode.isEmpty ? nil : decode)
    }
    return ClaudeFailurePresentation(message: decode.isEmpty ? "Claude sessionState 无效" : decode, detail: nil)
}

/// The public observation already carries the terminal execution error. Prefer
/// it over any decode error so an upstream message such as a 402 is never
/// hidden behind `Claude sessionState 无效`.
func claudeHarnessFailure(_ observation: ThreadPublicObservation) -> String? {
    guard let execution = observation.latestExecution, execution.status == .failed else { return nil }
    let error = claudeTrimmed(claudeRedacted(execution.error?.string ?? ""))
    let summary = claudeTrimmed(claudeRedacted(execution.summary?.string ?? ""))
    let message = error.isEmpty ? summary : error
    return message.isEmpty ? nil : message
}

/// Remove credential-shaped material before text reaches a view or a log.
/// Upstream messages remain otherwise verbatim, including status codes and
/// request IDs.
func claudeRedacted(_ source: String) -> String {
    var text = source
    let replacements: [(String, String)] = [
        (#"(?i)\b(authorization|x-api-key|anthropic[-_]?api[-_]?key|openai[-_]?api[-_]?key|claude[-_]?code[-_]?oauth[-_]?token|api[-_]?key|oauth[-_]?token|auth[-_]?token)\b\s*[:=]\s*(?:bearer\s+)?[^\s,;]+"#, "$1: [REDACTED]"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/\-]+=*"#, "Bearer [REDACTED]"),
        (#"\bsk-[A-Za-z0-9_-]{8,}"#, "[REDACTED]"),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, "[REDACTED]")
    ]
    for (pattern, template) in replacements {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
        text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
    return text
}

private func claudeTrimmed(_ source: String) -> String {
    source.trimmingCharacters(in: .whitespacesAndNewlines)
}

enum ClaudeStateLog {
    static let decode = Logger(subsystem: "com.mokusei.desktop", category: "claude-state")
}
