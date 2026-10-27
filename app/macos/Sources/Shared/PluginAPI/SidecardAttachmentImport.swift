import Foundation
import MokuseiCore

/// Device-local clipboard/file bytes; never an authorized host path.
public enum SidecardAttachmentSource: Sendable {
    case file(URL)
    case bytes(Data, name: String, mimeType: String)
}

public struct SidecardImportedAttachment: Sendable {
    public enum Kind: String, Sendable { case image, document, file }
    public let id: JSONText
    public let path: JSONText
    public let name: JSONText
    public let mimeType: JSONText
    public let size: Int
    public let kind: Kind

    public init(id: JSONText, path: JSONText, name: JSONText, mimeType: JSONText, size: Int, kind: Kind) {
        precondition(size >= 0)
        self.id = id; self.path = path; self.name = name; self.mimeType = mimeType
        self.size = size; self.kind = kind
    }
}

@MainActor
public struct SidecardAttachmentImport {
    private let importFiles: ([SidecardAttachmentSource], PluginLifetime) async throws -> [SidecardImportedAttachment]
    public let policy: (PluginLifetime) async throws -> RuntimeAttachmentPolicy

    public init(stage: @escaping ([SidecardAttachmentSource], PluginLifetime) async throws -> [SidecardImportedAttachment],
                policy: @escaping (PluginLifetime) async throws -> RuntimeAttachmentPolicy) {
        self.importFiles = stage; self.policy = policy
    }

    public func stage(_ sources: [SidecardAttachmentSource], _ lifetime: PluginLifetime) async throws -> [SidecardImportedAttachment] {
        for case .file(let url) in sources where !url.isFileURL {
            throw PluginContractError("Sidecard attachments must be local file URLs")
        }
        try lifetime.checkCancellation()
        try Task.checkCancellation()
        return try await importFiles(sources, lifetime)
    }
}
