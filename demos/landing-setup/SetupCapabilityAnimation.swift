import SwiftUI
@testable import MokuseiUI

/// Capability illustrations use local fixtures and never act on real sessions.
struct SetupCapabilityAnimation: View {
    enum Kind { case tag, report }
    let kind: Kind

    var body: some View {
        let harnesses = [SetupAgent.codex, .claude, .opencode].map { $0.plugin }
        if kind == .tag { NativeOnboardingTagAnimation(harnesses: harnesses, locale: .chinese) }
        else { NativeOnboardingReportAnimation(harnesses: harnesses, locale: .chinese) }
    }
}
