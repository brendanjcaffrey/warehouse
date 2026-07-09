import SwiftUI

/// small square artwork image with a gray music note placeholder,
/// downsampled off the main thread and cached
struct ArtworkThumbnail: View {
    let url: URL?
    var maxPixelSize = 132

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray5))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "music.note")
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(0.45)
                    .foregroundStyle(.secondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            image = await ArtworkLoader.thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }
}

enum ArtworkLoader {
    private static let cache = NSCache<NSString, UIImage>()

    static func thumbnail(for url: URL?, maxPixelSize: Int = 132) async -> UIImage? {
        guard let url else { return nil }
        // the size is part of the key so big & small requests don't collide
        let key = "\(url.path)#\(maxPixelSize)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let image = await Task.detached(priority: .utility) {
            downsample(url, maxPixelSize: maxPixelSize)
        }.value
        if let image {
            cache.setObject(image, forKey: key)
        }
        return image
    }

    private static func downsample(_ url: URL, maxPixelSize: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
