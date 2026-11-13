import SwiftUI

public extension NativeCloudPalette {
    init(loop style: NativeCloudLoopStyle) {
        self.init(channels: style.channels.map { channel in
            let color = channel.light == channel.dark
                ? NativePalette.color(channel.light) : NativePalette.pair(channel.light, channel.dark)
            return .init(color: color.swiftUI, seed: channel.seed, energy: channel.energy)
        }, phase: style.phase, lobeScale: style.lobeScale, loopStyle: style)
    }
}
