import SwiftUI

extension EnvironmentValues {
    /// nil outside the app (previews, a view built without the wiring), which
    /// just leaves the placeholder in place
    @Entry var artworkFetcher: WatchArtworkFetcher?
}

/// small square artwork image with a gray music note placeholder, like the
/// phone's ArtworkThumbnail but without its ios-only system colors. the watch
/// holds a bounded cache rather than a mirror, so the file usually isn't on
/// disk yet and the thumbnail fetches it before loading
struct WatchArtworkThumbnail: View {
    @Environment(\.artworkFetcher) private var fetcher

    let filename: String?
    var priority: WatchArtworkFetcher.Priority = .list
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
        // cancelled when the row scrolls away, which is what keeps a long list
        // from queueing a fetch for every song in it
        .task(id: filename) {
            image = nil
            guard let url = await fetcher?.artworkURL(filename, priority: priority) else { return }
            image = await ArtworkLoader.thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }
}
