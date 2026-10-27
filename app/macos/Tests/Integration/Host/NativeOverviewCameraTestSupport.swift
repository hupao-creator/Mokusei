import Foundation
import Testing
@testable import MokuseiUI

/// Assert the shared center of the region between controls. Fresh fits and
/// retained filter framing use the same anchor, so both suites share one check.
func expectCameraAnchored(_ content: NativeOverviewContentRect, in transform: NativeOverviewTransform,
                          viewport: NativeOverviewViewport,
                          sourceLocation: SourceLocation = #_sourceLocation) {
    let region = NativeOverviewCameraGeometry.framingRegion(viewport)
    let expectedY = region.top + region.height / 2
    #expect(abs(transform.x + (content.left + content.width / 2) * transform.scale
        - (region.left + region.width / 2)) < 1, sourceLocation: sourceLocation)
    #expect(abs(transform.y + (content.top + content.height / 2) * transform.scale - expectedY) < 1,
            sourceLocation: sourceLocation)
}
