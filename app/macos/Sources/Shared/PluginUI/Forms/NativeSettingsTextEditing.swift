import AppKit
import SwiftUI

/// A page owns its composing editors. Ending one editor cannot release another
/// editor's save/close protection, including in a different application window.
@MainActor public final class NativeSettingsTextEditing {
    private struct Composition {
        weak var owner: AnyObject?
    }
    private var compositions: [ObjectIdentifier: Composition] = [:]
    private var reportedComposition = false
    fileprivate var onComposition: (Bool) -> Void = { _ in }
    fileprivate var onBlur: () -> Void = {}

    public init() {}

    public func compositionChanged(_ composing: Bool, editor: NSTextView) {
        update(composing, owner: editor)
    }

    public func editingEnded(_ editor: NSTextView) {
        update(false, owner: editor)
        onBlur()
    }

    private func update(_ composing: Bool, owner: AnyObject) {
        let identity = ObjectIdentifier(owner)
        if composing { compositions[identity] = Composition(owner: owner) }
        else { compositions.removeValue(forKey: identity) }
        compositions = compositions.filter { $0.value.owner != nil }
        let next = !compositions.isEmpty
        guard next != reportedComposition else { return }
        reportedComposition = next
        onComposition(next)
    }

    fileprivate func fieldChanged(_ field: NSTextField) {
        guard let editor = field.currentEditor() as? NSTextView else { return }
        update(editor.hasMarkedText(), owner: field)
    }

    fileprivate func fieldEnded(_ field: NSTextField) {
        // NSTextFields share their window's field editor. The field is the owner,
        // so a delayed end notification cannot clear its next client's marks.
        update(false, owner: field)
        onBlur()
    }

    fileprivate func fieldDetached(_ field: NSTextField) { update(false, owner: field) }
}

private struct NativeSettingsTextEditingKey: EnvironmentKey {
    static let defaultValue: NativeSettingsTextEditing? = nil
}

public extension EnvironmentValues {
    var nativeSettingsTextEditing: NativeSettingsTextEditing? {
        get { self[NativeSettingsTextEditingKey.self] }
        set { self[NativeSettingsTextEditingKey.self] = newValue }
    }
}

public extension View {
    func nativeSettingsTextEditing(onComposition: @escaping (Bool) -> Void,
                                   onBlur: @escaping () -> Void) -> some View {
        modifier(NativeSettingsTextEditingScope(onComposition: onComposition, onBlur: onBlur))
    }
}

private struct NativeSettingsTextEditingScope: ViewModifier {
    @State private var editing = NativeSettingsTextEditing()
    let onComposition: (Bool) -> Void
    let onBlur: () -> Void

    func body(content: Content) -> some View {
        content.environment(\.nativeSettingsTextEditing, editing)
            .background(NativeSettingsTextFieldObserver(editing: editing, onComposition: onComposition, onBlur: onBlur))
    }
}

/// SwiftUI owns single-line NSTextFields, while both textarea adapters report
/// their NSTextInputClient lifecycle directly. Observe only this page's window.
private struct NativeSettingsTextFieldObserver: NSViewRepresentable {
    let editing: NativeSettingsTextEditing
    let onComposition: (Bool) -> Void
    let onBlur: () -> Void

    func makeNSView(context: Context) -> Observer { Observer() }
    func updateNSView(_ view: Observer, context: Context) {
        editing.onComposition = onComposition
        editing.onBlur = onBlur
        view.editing = editing
    }
    static func dismantleNSView(_ view: Observer, coordinator: ()) { view.stop() }

    @MainActor final class Observer: NSView {
        weak var editing: NativeSettingsTextEditing?
        private var observations: [NSObjectProtocol] = []
        private let fields = NSHashTable<NSTextField>.weakObjects()

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            for name in [NSControl.textDidChangeNotification, NSControl.textDidEndEditingNotification] {
                observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notice in
                    guard let field = notice.object as? NSTextField else { return }
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window, field.window === window else { return }
                        if name == NSControl.textDidEndEditingNotification {
                            self.fields.remove(field)
                            self.editing?.fieldEnded(field)
                        } else {
                            self.fields.add(field)
                            self.editing?.fieldChanged(field)
                        }
                    }
                })
            }
        }
        func stop() {
            observations.forEach(NotificationCenter.default.removeObserver)
            observations.removeAll()
            fields.allObjects.forEach { editing?.fieldDetached($0) }
            fields.removeAllObjects()
        }
    }
}
