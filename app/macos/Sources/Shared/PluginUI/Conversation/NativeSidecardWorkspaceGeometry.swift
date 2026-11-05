import SwiftUI

@MainActor
public struct NativeSidecardWorkspaceGeometry {
    public let size: CGSize
    public let stacked: Bool
    public let cardWidth: CGFloat
    public let maximumCardWidth: CGFloat
    public let mainWidth: CGFloat
    public let mainHeight: CGFloat
    public let surfaceWidth: CGFloat
    public let surfaceHeight: CGFloat
    public let surfaceX: CGFloat
    public let surfaceY: CGFloat

    public init(size: CGSize, open: Bool, preferredWidth: Double = 1 / 3, retainedWidth: CGFloat? = nil) {
        self.size = size; stacked = size.width > 0 && size.width < 760
        let usableWidth = max(0, size.width - 16)
        maximumCardWidth = max(320, usableWidth - 360)
        let fraction = preferredWidth.isFinite ? preferredWidth : 1 / 3
        cardWidth = min(maximumCardWidth, max(320, retainedWidth ?? (usableWidth * fraction).rounded()))
        mainWidth = max(0, size.width - (!stacked && open ? cardWidth + 16 : 0))
        mainHeight = max(0, stacked && open ? (size.height - 16) / 2 : size.height)
        surfaceWidth = max(0, stacked ? size.width : cardWidth)
        surfaceHeight = max(0, stacked ? (size.height - 16) / 2 : size.height)
        surfaceX = max(0, size.width - surfaceWidth)
        surfaceY = stacked ? (size.height + 16) / 2 : 0
    }
}
