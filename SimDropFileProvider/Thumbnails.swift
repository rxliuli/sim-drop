import CoreGraphics
import FileProvider
import ImageIO
import UniformTypeIdentifiers

/// Photo previews for Finder's icon view without downloading the originals. (Finder only
/// asks File Providers for thumbnails of media types; it never asks for .app/.ipa/.zip.)
extension FileProviderExtension: NSFileProviderThumbnailing {
    func fetchThumbnails(
        for itemIdentifiers: [NSFileProviderItemIdentifier],
        requestedSize size: CGSize,
        perThumbnailCompletionHandler: @escaping (NSFileProviderItemIdentifier, Data?, Error?) -> Void,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: Int64(itemIdentifiers.count))
        DispatchQueue.global(qos: .userInitiated).async {
            for identifier in itemIdentifiers {
                var data: Data?
                if let id = ItemID(identifier), case .photo = id, let url = Resolver.url(for: id) {
                    data = PhotoThumbnail.jpeg(url, maxPixel: max(size.width, size.height))
                }
                perThumbnailCompletionHandler(identifier, data, nil)
                progress.completedUnitCount += 1
            }
            completionHandler(nil)
        }
        return progress
    }
}

enum PhotoThumbnail {
    /// A JPEG preview of an image file, without decoding it at full size.
    static func jpeg(_ url: URL, maxPixel: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, 1024),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, thumb, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
