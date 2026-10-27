import Foundation
import ImageIO
import MokuseiPluginAPI
import UniformTypeIdentifiers

/// Independent ImageIO objects belong to this serial worker. AppKit capture and
/// pasteboard access stay on main; no NSImage/NSBitmapImageRep crosses the actor.
public actor NativeRasterPreparation {
    public static let shared = NativeRasterPreparation()

    public func png(_ image: CGImage) throws -> Data {
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PluginContractError("截图失败")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length > 0 else { throw PluginContractError("截图失败") }
        try Task.checkCancellation()
        return data as Data
    }

    func prepare(_ files: [NativeComposerFile]) throws -> [NativeComposerFile?] {
        try files.map { file in
            try Task.checkCancellation()
            guard file.clipboardTIFF, case .bytes(let data) = file.source else { return file }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                return nil
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            if (2...8).contains(orientation) {
                // NSBitmapImageRep applies TIFF orientation before its PNG
                // conversion. Apply that same transform at full pixel size;
                // this is not a display thumbnail or a resolution reduction.
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: max(image.width, image.height)
                ]
                guard let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                image = oriented
            }
            do { return NativeComposerFile(data: try png(image), name: "pasted-image.png", mimeType: "image/png") }
            catch is CancellationError { throw CancellationError() }
            catch { return nil }
        }
    }
}
