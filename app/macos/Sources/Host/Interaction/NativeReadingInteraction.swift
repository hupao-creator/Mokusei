import Foundation
import ChiefCore
import ChiefPluginUI

@MainActor
public extension NativeWorkspacePresentation {
    var readingInteractionActions: [String] {
        interactionPage == "thread" && !openingCollectionMember && selected != nil && mountedReadingThread == selected ? ["reading.control"] : []
    }

    func readingInteractionSnapshot() -> JSONValue {
        .object(["foreground": .bool(selected != nil && readingForeground),
                 "windowActive": .bool(readingWindowActive), "sceneFocused": .bool(overview.facts.focused),
                 "entranceAdmitted": .bool(readingEntranceAdmitted),
                 "collectionEligibility": selected.flatMap { overview.collectionEligibility($0) } ?? .null,
                 "controls": .array(readingInteractionActions.isEmpty
            ? [] : readingInteractions.snapshot(visit: navigationRouteID))])
    }

    func performReadingControl(id: String, handle: String, operation: String, value: JSONValue) throws {
        guard !readingInteractionActions.isEmpty else { throw NativeInteractionError("unavailable", "Reading page is not mounted") }
        do {
            try readingInteractions.perform(id: id, handle: handle, operation: operation, value: value, visit: navigationRouteID)
        } catch let error as NativeReadingControlError { throw NativeInteractionError(error.code, error.message) }
    }
}
