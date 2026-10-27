import Foundation

actor BrowserAnnotationFiles {
    static let shared = BrowserAnnotationFiles()
    struct Batch: Sendable { let directory: URL; let files: [URL] }
    func write(_ images: [Data]) throws -> Batch {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mokusei-annotations-\(UUID().uuidString)", isDirectory: true)
        do {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let files = try images.enumerated().map { index, bytes in
                try Task.checkCancellation()
                let url = directory.appendingPathComponent("annotation-\(index + 1).png")
                try bytes.write(to: url, options: .atomic)
                return url
            }
            try Task.checkCancellation()
            return Batch(directory: directory, files: files)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
    func remove(_ directory: URL) { try? FileManager.default.removeItem(at: directory) }
}
