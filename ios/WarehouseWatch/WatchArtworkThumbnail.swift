import SwiftUI

/// small square artwork image with a gray music note placeholder, like the
/// phone's ArtworkThumbnail but without its ios-only system colors
struct WatchArtworkThumbnail: View {
    let url: URL?
    var maxPixelSize = 56

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
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
