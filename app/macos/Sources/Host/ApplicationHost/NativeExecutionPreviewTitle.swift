import Foundation
import Observation
import MokuseiCore
import MokuseiPluginAPI

/// Retains one exact-execution preview reference for a lightweight title read.
/// The Report reference cache owns invalidation and release; this model only
/// keeps the selected Dock title subscribed while it is mounted.
@MainActor @Observable
final class NativeExecutionPreviewTitle {
    private(set) var title: JSONText?
    private(set) var threadID: JSONText?
    private(set) var executionID: JSONText?
    @ObservationIgnored private var stop: (() -> Void)?
    @ObservationIgnored private var lifetime = PluginLifetime()

    func title(threadID: JSONText, executionID: JSONText) -> JSONText? {
        self.threadID == threadID && self.executionID == executionID ? title : nil
    }

    func attach(host: NativeApplicationHost, threadID: JSONText, executionID: JSONText) {
        detach()
        self.threadID = threadID
        self.executionID = executionID
        let reference = ApplicationExecutionRef(thread: ApplicationThreadRef(threadID: threadID, typeID: "agent"),
                                                executionID: executionID)
        let lifetime = PluginLifetime()
        self.lifetime = lifetime
        let read = { [weak self] in
            guard let self, !lifetime.isCancelled else { return }
            guard let item = try? host.executionReferences([reference]).first else { return }
            self.title = item.title
        }
        stop = host.subscribeReferences([reference], listener: read, lifetime: lifetime)
        read()
    }

    func detach() {
        stop?(); stop = nil
        lifetime.cancel()
        lifetime = PluginLifetime()
        title = nil; threadID = nil; executionID = nil
    }
}
