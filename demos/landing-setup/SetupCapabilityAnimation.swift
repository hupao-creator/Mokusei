import SwiftUI

/// Capability illustrations use local fixtures and never act on real sessions.
struct SetupCapabilityAnimation: View {
    enum Kind { case tag, report }
    let kind: Kind

    var body: some View {
        if kind == .tag { SetupTagPhysicsAnimation() }
        else { SetupReportDiagramAnimation() }
    }
}
