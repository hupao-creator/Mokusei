import SwiftUI

/// A point-space light field shaded by Metal, shared by cards and tag glass.
public struct NativeCloudLoading: View, @MainActor Animatable {
    public let palette: NativeCloudPalette
    public var intensity: Double
    public var isAnimating: Bool
    public let motionSpeed: Double

    public init(palette: NativeCloudPalette, intensity: Double = 1, isAnimating: Bool = true,
                motionSpeed: Double = 1) {
        self.palette = palette; self.intensity = intensity; self.isAnimating = isAnimating
        self.motionSpeed = motionSpeed
    }

    // Animate light energy itself so the tag glass samples the fading field.
    public var animatableData: Double {
        get { intensity }
        set { intensity = newValue }
    }

    @Environment(\.colorScheme) private var colorScheme
    @State private var startedAt = Date()
    @State private var motionSeed = UInt64.random(in: .min ... .max)

    public var body: some View {
        Group {
            // Test the animated value so the full fade renders before releasing
            // the timeline and shader. Motion state survives in this outer view.
            if intensity > 0 {
                TimelineView(.animation(minimumInterval: NativeFrameRate.interval,
                                        paused: !isAnimating)) { timeline in
                    let time = timeline.date.timeIntervalSince(startedAt) * motionSpeed
                    GeometryReader { geometry in
                        let field = NativeCloudField(palette: palette, intensity: intensity,
                                                     time: time + palette.phase, seed: motionSeed)
                        NativeCloudMetalField(lights: field.lights(in: geometry.size, colorScheme: colorScheme))
                    }
                }
                .transition(.identity)
            } else {
                Color.clear
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct NativeCloudMetalField: View {
    let lights: NativeCloudLights
    // Retain the precompiled library so SwiftUI caches its compiled functions.
    static let libraryURL = NativeResources.bundle.url(forResource: "CloudLoading-\(NativeResources.platform)", withExtension: "metallib")!
    private static let library = ShaderLibrary(url: libraryURL)

    var body: some View {
        Canvas(opaque: false, colorMode: .linear, rendersAsynchronously: true) { context, size in
            let shader = Shader(function: ShaderFunction(library: Self.library, name: "cloudLoading"),
                                arguments: [.floatArray(lights.geometry), .colorArray(lights.colors)])
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .style(shader))
        }
    }
}
