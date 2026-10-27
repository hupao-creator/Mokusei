import CoreText
import SwiftUI

/// The font families used by the Electron renderer, registered from bundled,
/// uncompressed copies of the same Fontsource variable fonts.
public enum NativeTypography {
    static let monoSubsets = [
        (file: "cyrillic-ext", postScript: "MokuseiJetBrainsMonoCyrillicExt-Regular"),
        (file: "cyrillic", postScript: "MokuseiJetBrainsMonoCyrillic-Regular"),
        (file: "greek", postScript: "MokuseiJetBrainsMonoGreek-Regular"),
        (file: "vietnamese", postScript: "MokuseiJetBrainsMonoVietnamese-Regular"),
        (file: "latin-ext", postScript: "MokuseiJetBrainsMonoLatinExt-Regular"),
    ]

    private static let registration: Void = {
        let files = ["inter-latin-wght-normal", "jetbrains-mono-latin-wght-normal"]
            + monoSubsets.map { "jetbrains-mono-\($0.file)-wght-normal" }
        for filename in files {
            guard let url = NativeResources.bundle.url(forResource: filename, withExtension: "ttf")
                    ?? NativeResources.bundle.url(forResource: filename, withExtension: "ttf", subdirectory: "fonts") else {
                preconditionFailure("Missing bundled Mokusei font: \(filename).ttf")
            }
            var error: Unmanaged<CFError>?
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
                let registrationError = error?.takeRetainedValue()
                // Another Mokusei UI host in this process may already have
                // registered this exact bundled font.
                guard registrationError.map({ CFErrorGetCode($0) == CTFontManagerError.alreadyRegistered.rawValue }) == true else {
                    preconditionFailure("Cannot register Mokusei font \(filename): \(String(describing: registrationError))")
                }
            }
        }
    }()

    /// Safe to call repeatedly. Font creation also registers fonts on first use.
    public static func registerFonts() {
        _ = registration
    }

    private static let coreFonts = CoreFontCache()
    private static func variableFont(name: String, size: CGFloat, weight: CGFloat, cascade: [String] = []) -> CTFont {
        let key = "\(name)|\(size)|\(weight)" as NSString
        if let font = coreFonts.values.object(forKey: key) { return font }
        let variation = [0x77676874: weight] as CFDictionary
        var attributes: [CFString: Any] = [kCTFontNameAttribute: name, kCTFontVariationAttribute: variation]
        if !cascade.isEmpty {
            attributes[kCTFontCascadeListAttribute] = cascade.map {
                CTFontDescriptorCreateWithAttributes([kCTFontNameAttribute: $0, kCTFontVariationAttribute: variation] as CFDictionary)
            }
        }
        let font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateWithAttributes(attributes as CFDictionary), size, nil)
        coreFonts.values.setObject(font, forKey: key)
        return font
    }
    private static func swiftUIWeight(_ value: CGFloat) -> Font.Weight {
        switch value {
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
    public static func inter(size: CGFloat, weight: CGFloat = 400) -> Font {
        registerFonts()
        return Font(variableFont(name: "Inter-Regular", size: size, weight: min(900, max(100, weight))))
    }



    public static func mono(size: CGFloat, weight: CGFloat = 400) -> Font {
        registerFonts()
        return Font(variableFont(name: "JetBrainsMono-Regular", size: size, weight: min(800, max(100, weight)), cascade: monoSubsets.map(\.postScript)))
    }



    /// Settings explicitly use the macOS system family in the existing design.
    public static func settings(size: CGFloat, weight: CGFloat = 400) -> Font {
        Font.system(size: size, weight: swiftUIWeight(weight))
    }




}

private final class FontResourceAnchor: NSObject {}

/// SwiftPM's development accessor points beside the executable. A distributed
/// app relocates its resource bundles into Contents/Resources instead.
enum NativeResources {
    static let platform = "macosx"

    static let bundle: Bundle = {
        if let resourceURL = Bundle.main.resourceURL {
            let packagedURL = resourceURL.appendingPathComponent("MokuseiNative_MokuseiPluginUI.bundle", isDirectory: true)
            if let packaged = Bundle(url: packagedURL) {
                guard packaged.url(forResource: "inter-latin-wght-normal", withExtension: "ttf")
                        ?? packaged.url(forResource: "inter-latin-wght-normal", withExtension: "ttf", subdirectory: "fonts") != nil else {
                    preconditionFailure("Packaged Mokusei UI resource bundle is missing the Inter font: \(packagedURL.path)")
                }
                return packaged
            }
            if Bundle.main.bundleURL.pathExtension == "app" {
                preconditionFailure("Packaged Mokusei UI resource bundle is missing: \(packagedURL.path)")
            }
        }
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        return Bundle(for: FontResourceAnchor.self)
        #endif
    }()
}

private final class CoreFontCache: @unchecked Sendable {
    let values = NSCache<NSString, CTFont>()
    init() { values.countLimit = 512 }
}
