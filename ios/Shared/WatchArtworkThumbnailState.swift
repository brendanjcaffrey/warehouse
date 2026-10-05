import Foundation
import Observation
import UIKit

struct WatchArtworkRequest: Hashable, Sendable {
    let filename: String?
    let maxPixelSize: Int
    var url: URL?
    var contentIdentity: UUID?
}

/// fences asynchronous decoding when a row is reused or its task is cancelled.
@Observable
@MainActor
final class WatchArtworkThumbnailState {
    private(set) var image: UIImage?
    @ObservationIgnored private var generation = UUID()
    private let decode: (WatchArtworkRequest) async -> UIImage?

    init(decode: @escaping (WatchArtworkRequest) async -> UIImage? = {
        await ArtworkLoader.thumbnail(for: $0.url, maxPixelSize: $0.maxPixelSize, contentIdentity: $0.contentIdentity)
    }) {
        self.decode = decode
    }

    func load(_ request: WatchArtworkRequest) async {
        guard !Task.isCancelled else { return }
        let current = UUID()
        generation = current
        image = nil
        guard request.url != nil else { return }
        let decoded = await decode(request)
        guard generation == current, !Task.isCancelled else { return }
        image = decoded
    }
}
