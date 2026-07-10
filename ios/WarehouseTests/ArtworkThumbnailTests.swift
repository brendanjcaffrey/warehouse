import CoreGraphics
import Testing
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
}
