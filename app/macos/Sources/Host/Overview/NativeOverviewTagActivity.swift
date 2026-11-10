import SwiftUI
import MokuseiPluginUI

/// Keep the slot even when inactive so status changes cannot move a tag's text,
/// count or neighbors. The native spinner owns motion and window visibility.
struct OverviewTagActivityIndicator: View {
    let hasActiveTasks: Bool
    var body: some View {
        ZStack {
            Color.clear
            if hasActiveTasks { NativeStatusSpinner(size: 10, lineWidth: 1.5) }
        }
        .frame(width: 10, height: 10)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
