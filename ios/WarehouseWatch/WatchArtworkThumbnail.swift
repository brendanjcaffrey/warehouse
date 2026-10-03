import SwiftUI

extension EnvironmentValues {
    /// nil outside the app (previews, a view built without the wiring), which
    /// just leaves the placeholder in place
    @Entry var artworkFetcher: WatchArtworkFetcher?
}

/// reads delivered artwork, keeping a placeholder until local bytes arrive.
struct WatchArtworkThumbnail: View {
    @Environment(\.artworkFetcher) private var fetcher

    let filename: String?
    var maxPixelSize = 56

    @Environment(WatchLibraryStore.self) private var library

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
        .task(id: "\(filename ?? "")-\(library.progress().artwork.downloaded)") {
            image = nil
            guard let url = fetcher?.artworkURL(filename) else { return }
            image = await ArtworkLoader.thumbnail(for: url, maxPixelSize: maxPixelSize)
        }
    }
}
