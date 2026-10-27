import Foundation

/// Shared workspace path predicates. Keep the temporary-workspace patterns in
/// one place so the Overview and Harness surfaces cannot drift.
public enum MokuseiWorkspacePath {
    public static func isTemporary(_ raw: String) -> Bool {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\", with: "/")
        while path.hasSuffix("/") { path.removeLast() }
        guard !path.isEmpty else { return false }
        return temporaryPatterns.contains { path.range(of: $0, options: .regularExpression) != nil }
    }

    private static let temporaryPatterns = [
        #"/runtime-workspace/tmp-workspaces(?:/|$)"#,
        #"/\.Mokusei(?:-headless)?/tmp-workspaces(?:/|$)"#,
        #"(?i)^/(?:private/)?(?:tmp|var/tmp)/mokusei-[^/]+(?:/|$)"#,
        #"(?i)^/(?:private/)?var/folders/[^/]+/[^/]+/T/mokusei-[^/]+(?:/|$)"#,
        #"(?i)^[A-Za-z]:/(?:Windows/Temp|Users/[^/]+/AppData/Local/Temp)/mokusei-[^/]+(?:/|$)"#
    ]
}
