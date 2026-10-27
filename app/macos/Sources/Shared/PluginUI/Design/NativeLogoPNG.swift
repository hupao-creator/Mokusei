import ImageIO
import SwiftUI

/// Export a plugin's SwiftUI logo without constructing a platform image or bitmap view.
@MainActor public func nativeLogoPNG<Content: View>(@ViewBuilder content: () -> Content) -> String {
    let renderer = ImageRenderer(content: content())
    renderer.scale = 3
    guard let image = renderer.cgImage else { return "" }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) else { return "" }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return "" }
    return "data:image/png;base64," + (data as Data).base64EncodedString()
}
