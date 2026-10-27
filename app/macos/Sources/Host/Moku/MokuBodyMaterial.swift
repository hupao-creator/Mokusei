import AppKit
import Observation
import MokuseiPluginUI
import SwiftUI

/// Collects silhouettes from one character paint pass. The inverse canvas CTM
/// keeps Retina scaling and the flipped view out of material geometry. Bitmap
/// callers omit this sink and retain the original vector fill.
public final class MokuBodyMaterial {
    struct Surface: Equatable {
        var path: Path
        var frame: CGRect
        var opacity: Double
    }
    private let canvasInverse: CGAffineTransform
    private(set) var surfaces: [Surface] = []

    init(in context: CGContext) { canvasInverse = context.ctm.inverted() }

    static func fill(_ path: CGPath, in context: CGContext, opacity: Double = 1,
                     material: MokuBodyMaterial?) {
        guard opacity > 0.001 else { return }
        guard let material else {
            context.saveGState()
            context.setAlpha(opacity)
            context.setFillColor(MokuGeometry.bodyColor.cgColor)
            context.addPath(path); context.fillPath()
            context.restoreGState()
            return
        }
        // The body used to cover orbit strokes painted earlier in this pass.
        // Remove their covered pixels from the transparent foreground so they
        // remain behind the fully tinted material, including satellite fades.
        context.saveGState()
        context.setBlendMode(.destinationOut); context.setAlpha(opacity)
        context.setFillColor(NativePlatformColor.black.cgColor)
        context.addPath(path); context.fillPath()
        context.restoreGState()
        var transform = context.ctm.concatenating(material.canvasInverse)
        guard let transformed = path.copy(using: &transform) else { return }
        let frame = transformed.boundingBoxOfPath
        guard !frame.isEmpty, !frame.isInfinite, !frame.isNull else { return }
        var local = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        guard let localPath = transformed.copy(using: &local) else { return }
        material.surfaces.append(Surface(path: Path(localPath), frame: frame, opacity: opacity))
    }
}

/// Identical body frames, including settled-idle blinks, never invalidate this
/// isolated SwiftUI tree. Foreground rendering stays in the native canvas above.
@MainActor final class MokuGlassBodyView: NativePlatformView {
    private let state: MokuGlassBodyState
    private let hosting: NSHostingView<MokuGlassBodyContent>
    override var isFlipped: Bool { true }

    init() {
        let state = MokuGlassBodyState()
        self.state = state
        hosting = NSHostingView(rootView: MokuGlassBodyContent(state: state))
        super.init(frame: .zero)
        wantsLayer = true; clipsToBounds = false; layer?.masksToBounds = false
        hosting.sizingOptions = []; hosting.safeAreaRegions = []
        hosting.frame = bounds; hosting.autoresizingMask = [.width, .height]
        hosting.clipsToBounds = false
        addSubview(hosting)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ material: MokuBodyMaterial) {
        guard state.surfaces != material.surfaces else { return }
        // The character's timeline already supplies interpolation. Present the
        // new silhouette with the foreground drawn in this same pass. Suppress
        // animation only for paint updates; the body must still be an animated
        // destination when the action effects merge back into it.
        withTransaction(Transaction(animation: nil)) {
            state.surfaces = material.surfaces
            hosting.layoutSubtreeIfNeeded()
        }
    }

    func update(actions: MokuGlassActions?) {
        guard state.actions != actions else { return }
        let visibilityChanged = (state.actions?.visible == true) != (actions?.visible == true)
        let animation: Animation? = visibilityChanged ? .smooth(duration: 0.38) : nil
        withAnimation(animation) { state.actions = actions }
    }
}

/// Preserve the hosting root and namespace while effects are being removed.
@MainActor @Observable final class MokuGlassBodyState {
    var surfaces: [MokuBodyMaterial.Surface] = []
    var actions: MokuGlassActions?
}

struct MokuGlassBodyContent: View {
    var state: MokuGlassBodyState
    @Namespace private var namespace

    var body: some View {
        let surfaces = state.surfaces
        let actions = state.actions
        ZStack(alignment: .topLeading) {
            GlassEffectContainer(spacing: actions == nil ? 0 : NativeMokuDockAction.glassSpacing) {
                ZStack(alignment: .topLeading) {
                    if let surface = surfaces.first {
                        silhouette(surface, id: "body")
                    }
                    if let actions, actions.visible {
                        ForEach(Array(NativeMokuDockAction.allCases.enumerated()), id: \.element) { index, action in
                            let frame = actions.frames[index]
                            NativeIcon(name: action.icon, size: 17)
                                .foregroundStyle(MokuGeometry.eyeColor.swiftUI)
                                .frame(width: frame.width, height: frame.height)
                                .glassEffect(.regular.tint(MokuGeometry.bodyColor.swiftUI).interactive(), in: Circle())
                                .glassEffectID(action.rawValue, in: namespace)
                                .glassEffectTransition(.matchedGeometry)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            // Satellites retain their original separation from the character.
            if surfaces.count > 1 {
                GlassEffectContainer(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        ForEach(surfaces.indices.dropFirst(), id: \.self) { index in
                            silhouette(surfaces[index], id: "satellite-\(index)")
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func silhouette(_ surface: MokuBodyMaterial.Surface, id: String) -> some View {
        Color.clear
            .frame(width: surface.frame.width, height: surface.frame.height)
            .glassEffect(.regular.tint(MokuGeometry.bodyColor.swiftUI), in: MokuGlassOutline(path: surface.path))
            .glassEffectID(id, in: namespace)
            .opacity(surface.opacity)
            .position(x: surface.frame.midX, y: surface.frame.midY)
    }
}

private struct MokuGlassOutline: Shape {
    var path: Path
    func path(in rect: CGRect) -> Path { path }
}
