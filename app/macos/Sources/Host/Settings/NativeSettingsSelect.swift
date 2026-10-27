import MokuseiCore
import MokuseiPluginUI
import SwiftUI

struct SettingsSelectOption<Value: Hashable> {
    let value: Value
    let title: String
}

/// Adapt typed settings preferences to the shared source-styled select.
struct SettingsSelect<Value: Hashable>: View {
    var label: String
    @Binding var selection: Value
    var options: [SettingsSelectOption<Value>]
    var body: some View {
        NativeSettingsSelectPopover(selection: Binding(
            get: { JSONText(options.firstIndex { $0.value == selection }.map(String.init) ?? "") },
            set: { token in
                guard let index = Int(token.string), options.indices.contains(index) else { return }
                selection = options[index].value
            }), options: options.enumerated().map { index, option in
                NativeSettingsOption(id: JSONText(String(index)), label: option.title)
            }, accessibilityLabel: label)
    }
}
