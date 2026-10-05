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

    @State private var thumbnail = WatchArtworkThumbnailState()

    var body: some View {
        let request = fetcher?.request(filename, maxPixelSize: maxPixelSize)
            ?? WatchArtworkRequest(filename: filename, maxPixelSize: maxPixelSize)
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
            if let image = thumbnail.image {
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
        .task(id: request) {
            await thumbnail.load(request)
        }
    }
}
