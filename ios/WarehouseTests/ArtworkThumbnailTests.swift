import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Warehouse

@Suite("ArtworkThumbnail")
struct ArtworkThumbnailTests {
    static func makeImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    @Test("crops a landscape image to a centered square")
    func cropsLandscape() {
        let cropped = ArtworkLoader.cropToCenterSquare(Self.makeImage(width: 2400, height: 1350))
        #expect(cropped.width == 1350)
        #expect(cropped.height == 1350)
    }

    @Test("crops a portrait image to a centered square")
    func cropsPortrait() {
        let cropped = ArtworkLoader.cropToCenterSquare(Self.makeImage(width: 900, height: 1600))
        #expect(cropped.width == 900)
        #expect(cropped.height == 900)
    }

    @Test("leaves an already square image unchanged")
    func leavesSquareUntouched() {
        let cropped = ArtworkLoader.cropToCenterSquare(Self.makeImage(width: 500, height: 500))
        #expect(cropped.width == 500)
        #expect(cropped.height == 500)
    }

    @Test("replaced artwork at the same path loads the new image")
    @MainActor
    func replacedArtwork() async throws {
        let files = FileCacheTests.makeStore()
        defer { try? FileManager.default.removeItem(at: files.rootURL) }
        func bytes(_ color: UIColor) -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).pngData { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            }
        }
        let url = files.fileURL(.artwork, "cover.png")
        let cache = FileCache(fileStore: files)
        let fetcher = WatchArtworkFetcher(fileCache: cache)
        try files.write(.artwork, "cover.png", data: bytes(.red))
        let request = fetcher.request("cover.png", maxPixelSize: 132)
        let first = try #require(await ArtworkLoader.thumbnail(for: url, contentIdentity: request.contentIdentity))
        try files.write(.artwork, "cover.png", data: bytes(.blue))
        cache.noteFileStored(.artwork, "cover.png")
        let next = fetcher.request("cover.png", maxPixelSize: 132)
        let replacement = try #require(await ArtworkLoader.thumbnail(for: url, contentIdentity: next.contentIdentity))
        #expect(first.pngData() != replacement.pngData())
    }
}
