import MokuseiPluginAPI
import SwiftUI

/// Fits the existing dispatch capsule without borrowing its eyes or Stop seat.
struct NativeMokuDispatchContent: View {
    let dispatch: NativeMokuDispatch
    let harness: AnyHarnessPlugin?
    @Environment(\.locale) private var locale
    private var chinese: Bool { locale.language.languageCode?.identifier == "zh" }

    var body: some View {
        HStack(spacing: 8) {
            if let harness { harness.logo(size: 15).help(harness.descriptor.displayName.string) }
            else { Image(systemName: "arrow.up.forward.app").frame(width: 15).help(dispatch.harnessID.string) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    status
                    if !dispatch.configuration.isEmpty {
                        configuration
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 2) {
                    status
                    if !dispatch.configuration.isEmpty { configuration }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, minHeight: 32)
        .accessibilityElement(children: .contain)
        .animation(.easeInOut(duration: 0.22), value: dispatch)
    }

    private var status: some View {
        Text(dispatch.sentence(chinese: chinese))
            .font(.system(size: 13, weight: .medium))
            .contentTransition(.opacity)
            .accessibilityIdentifier("moku-dispatch-status")
    }

    private var configuration: some View {
        // Try the complete identifiers first. Narrow seats lend configuration a
        // second line before truncating the model; never invent a model alias.
        HStack(spacing: 5) {
            if let model = dispatch.model { Text(model).truncationMode(.middle) }
            if let thinking = dispatch.thinking {
                if dispatch.model != nil { Text("·").accessibilityHidden(true) }
                Text(thinking).layoutPriority(1)
            }
        }
        .font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
        .help(dispatch.configuration)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dispatch.configuration)
        .accessibilityIdentifier("moku-dispatch-configuration")
    }
}
