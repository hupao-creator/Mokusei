import SwiftUI
import MokuseiPluginUI

/// Callers omit this view and its HStack spacing for inactive tags. Once mounted
/// for an active tag, retain its measured width while menu/search transitions
/// hide the ring. The native spinner owns motion and window visibility.
struct OverviewTagActivityIndicator: View {
    let hasActiveTasks: Bool
    var body: some View {
        ZStack {
            Color.clear
            if hasActiveTasks {
                NativeStatusSpinner(size: 10 * OverviewTagMetrics.enlargement,
                                    lineWidth: 1.5 * OverviewTagMetrics.enlargement)
            }
        }
        .frame(width: 10 * OverviewTagMetrics.enlargement, height: 10 * OverviewTagMetrics.enlargement)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
