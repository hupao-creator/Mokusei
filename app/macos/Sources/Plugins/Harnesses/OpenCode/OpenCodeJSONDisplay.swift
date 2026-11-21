import Foundation
import ChiefCore

/// Tool payload projections carry one producer-rendered display string. Native
/// decoding trusts that field without rebuilding or validating a second copy.
extension OpenCodeMessage {
    func toolDisplay(_ field: String) -> JSONText? {
        raw.ocText(field + "Display")
    }
}
