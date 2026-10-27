import SwiftUI

/// The dock's semantic controls and the isolated material host share this layout.
enum NativeMokuDockAction: String, CaseIterable, Identifiable {
    case history, message
    static let glassSpacing: CGFloat = 10
    var id: Self { self }
    var icon: String { self == .history ? "History" : "PenLine" }

    func frame(in size: CGSize) -> CGRect {
        CGRect(x: size.width / 2 + 60,
               y: self == .history ? 56 : 104, width: 36, height: 36)
    }
}

struct MokuGlassActions: Equatable {
    var visible: Bool
    var frames: [CGRect]

    init(visible: Bool, size: CGSize) {
        self.visible = visible
        frames = NativeMokuDockAction.allCases.map { $0.frame(in: size) }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Self {
        var result = self
        result.frames = frames.map { $0.offsetBy(dx: dx, dy: dy) }
        return result
    }
}

private struct MokuGlassActionsKey: EnvironmentKey {
    static let defaultValue: MokuGlassActions? = nil
}

extension EnvironmentValues {
    var mokuGlassActions: MokuGlassActions? {
        get { self[MokuGlassActionsKey.self] }
        set { self[MokuGlassActionsKey.self] = newValue }
    }
}
