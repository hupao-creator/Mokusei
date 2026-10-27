import MokuseiPluginAPI

extension HarnessThread {
    /// Presentation only: keep the complete catalog and Moku's access intact.
    /// A successor execution makes the thread eligible for display again.
    var isHiddenFromUser: Bool {
        guard moku != true else { return false }
        switch observation.latestExecution?.status {
        case .interrupted, .failed: return true
        default: return false
        }
    }
}
