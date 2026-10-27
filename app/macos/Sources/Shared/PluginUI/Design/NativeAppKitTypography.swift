import CoreText
import AppKit

public extension NativeTypography {
    private static let fonts = NativeFontCache()
    private static let weightAxis = 0x77676874
    static func interPlatformFont(size: CGFloat, weight: CGFloat = 400) -> NativePlatformFont {
        variableFont(postScriptName: "Inter-Regular", family: "Inter", size: size, weight: weight, range: 100...900)
    }

    static func monoPlatformFont(size: CGFloat, weight: CGFloat = 400) -> NativePlatformFont {
        variableFont(postScriptName: "JetBrainsMono-Regular", family: "JetBrains Mono", size: size,
                     weight: weight, range: 100...800, cascade: monoSubsets.map(\.postScript))
    }

    static func settingsPlatformFont(size: CGFloat, weight: CGFloat = 400) -> NativePlatformFont {
        let systemWeight: NativePlatformFont.Weight
        switch weight {
        case ..<150: systemWeight = .ultraLight
        case ..<250: systemWeight = .thin
        case ..<350: systemWeight = .light
        case ..<450: systemWeight = .regular
        case ..<550: systemWeight = .medium
        case ..<650: systemWeight = .semibold
        case ..<750: systemWeight = .bold
        case ..<850: systemWeight = .heavy
        default: systemWeight = .black
        }
        return NativePlatformFont.systemFont(ofSize: size, weight: systemWeight)
    }

    // Compatibility spellings keep existing shared components on one font path.
    static func interNSFont(size: CGFloat, weight: CGFloat = 400) -> NativePlatformFont {
        interPlatformFont(size: size, weight: weight)
    }
    static func monoNSFont(size: CGFloat, weight: CGFloat = 400) -> NativePlatformFont {
        monoPlatformFont(size: size, weight: weight)
    }
    static func settingsNSFont(size: CGFloat, weight: CGFloat = 400) -> NativePlatformFont {
        settingsPlatformFont(size: size, weight: weight)
    }

    private static func variableFont(
        postScriptName: String,
        family: String,
        size: CGFloat,
        weight: CGFloat,
        range: ClosedRange<CGFloat>,
        cascade: [String] = []
    ) -> NativePlatformFont {
        registerFonts()
        let normalizedWeight = min(max(weight, range.lowerBound), range.upperBound)
        let cacheKey = "\(postScriptName)|\(size)|\(normalizedWeight)|\(cascade.joined(separator: ","))" as NSString
        if let cached = fonts.values.object(forKey: cacheKey) { return cached }
        let variation = [NSNumber(value: weightAxis): NSNumber(value: Double(normalizedWeight))]
        typealias Descriptor = NSFontDescriptor
        let variationAttribute = Descriptor.AttributeName.variation
        var attributes: [Descriptor.AttributeName: Any] = [
            .name: postScriptName,
            variationAttribute: variation,
        ]
        if !cascade.isEmpty {
            attributes[.cascadeList] = cascade.map { Descriptor(fontAttributes: [.name: $0, variationAttribute: variation]) }
        }
        let descriptor = Descriptor(fontAttributes: attributes)
        // CoreText can assign a different PostScript instance name at a
        // non-default variable weight; the family must still be exact.
        guard let font = NativePlatformFont(descriptor: descriptor, size: size), font.familyName == family else {
            preconditionFailure("Bundled Mokusei font unavailable: \(postScriptName)")
        }
        fonts.values.setObject(font, forKey: cacheKey)
        return font
    }
}
private final class NativeFontCache: @unchecked Sendable {
    let values = NSCache<NSString, NativePlatformFont>()
    init() { values.countLimit = 512 }
}
