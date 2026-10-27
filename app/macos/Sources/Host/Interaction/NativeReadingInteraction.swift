import Foundation
import MokuseiCore
import MokuseiPluginUI

@MainActor
public extension NativeWorkspacePresentation {
    var readingInteractionActions: [String] {
        interactionPage == "thread" && selected != nil && mountedReadingThread == selected ? ["reading.control"] : []
    }

    func readingInteractionSnapshot() -> JSONValue {
        .object(["controls": .array(readingInteractionActions.isEmpty
            ? [] : readingInteractions.snapshot(visit: navigationRouteID))])
    }

    func performReadingControl(id: String, handle: String, operation: String, value: JSONValue) throws {
        guard !readingInteractionActions.isEmpty else { throw NativeInteractionError("unavailable", "Reading page is not mounted") }
        do {
            try readingInteractions.perform(id: id, handle: handle, operation: operation, value: value, visit: navigationRouteID)
        } catch let error as NativeReadingControlError { throw NativeInteractionError(error.code, error.message) }
    }
}
