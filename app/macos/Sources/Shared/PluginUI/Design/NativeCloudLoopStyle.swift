import Foundation

// Shared by the offline baker and the palette constructor. Palette changes must
// regenerate their assets, rather than silently playing an old color scheme.
extension NativeCloudLoopStyle {
    struct Channel {
        let light: UInt32
        let dark: UInt32
        let seed: Int
        let energy: Double
        init(_ light: UInt32, dark: UInt32? = nil, seed: Int, energy: Double) {
            self.light = light; self.dark = dark ?? light; self.seed = seed; self.energy = energy
        }
    }
    var channels: [Channel] {
        switch self {
        case .blueIndigo: [
            .init(0x799dff, seed: 136, energy: 0.42), .init(0x3941ff, seed: 73, energy: 0.31),
            .init(0xb1a7ff, seed: 211, energy: 0.34)]
        case .coral: [
            .init(0xf6ad71, seed: 136, energy: 0.36), .init(0xd97757, seed: 73, energy: 0.43),
            .init(0xefb7a2, seed: 211, energy: 0.28)]
        case .spectrum: [
            .init(0xff525e, seed: 19, energy: 0.25), .init(0xffb52e, seed: 53, energy: 0.23),
            .init(0x53dd83, seed: 87, energy: 0.25), .init(0x27cbf4, seed: 121, energy: 0.27),
            .init(0x5967ff, seed: 155, energy: 0.25), .init(0xdb57ef, seed: 189, energy: 0.25)]
        case .neutral: [
            .init(0x969898, dark: 0xe7e4df, seed: 136, energy: 0.42),
            .init(0x62676e, dark: 0xa6acb4, seed: 73, energy: 0.31),
            .init(0xc3beb6, dark: 0xcfcecd, seed: 211, energy: 0.34)]
        }
    }
    var phase: Double {
        switch self { case .blueIndigo: 1.2; case .coral: 4.6; case .spectrum: 2.8; case .neutral: 6.4 }
    }
    var lobeScale: CGSize {
        self == .spectrum ? CGSize(width: 0.86, height: 0.90) : CGSize(width: 1, height: 1)
    }
}
