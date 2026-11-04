import Foundation

/// A user-selected local document, rather than an arbitrary OS open target.
/// WebKit receives the resolved file and its containing directory for assets;
/// page navigation cannot grant itself access to another directory.
public struct ClientLocalHTMLDocument: Sendable {
    public let url: URL
    public let directory: URL

    public init?(_ raw: String) {
        guard let local = ClientWebNavigation.localFileURL(raw),
              ["html", "htm"].contains(local.pathExtension.lowercased()) else { return nil }
        let file = URL(fileURLWithPath: local.path).resolvingSymlinksInPath().standardizedFileURL
        guard ["html", "htm"].contains(file.pathExtension.lowercased()),
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .volumeIsLocalKey]),
              values.isRegularFile == true, values.isReadable == true, values.volumeIsLocal == true,
              var parts = URLComponents(url: file, resolvingAgainstBaseURL: false),
              let source = URLComponents(url: local, resolvingAgainstBaseURL: false) else { return nil }
        parts.percentEncodedQuery = source.percentEncodedQuery
        parts.percentEncodedFragment = source.percentEncodedFragment
        guard let target = parts.url else { return nil }
        url = target
        directory = file.deletingLastPathComponent()
    }
}
