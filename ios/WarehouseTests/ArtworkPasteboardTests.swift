import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Warehouse

@Suite("ArtworkPasteboard")
@MainActor
struct ArtworkPasteboardTests {
    /// named pasteboards keep the tests away from the simulator's general one
    static func makePasteboard(_ name: String) -> UIPasteboard {
        let pasteboard = UIPasteboard(name: UIPasteboard.Name("artwork-tests-\(name)"), create: true)!
        pasteboard.items = []
        return pasteboard
    }

    static func onePixelImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }

    static func tiffData() throws -> Data {
        let cgImage = try #require(onePixelImage().cgImage)
        let tiff = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(tiff, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))
        return tiff as Data
    }

    @Test("copied jpg bytes round trip untouched")
    func jpgRoundTrip() throws {
        let pasteboard = Self.makePasteboard("jpg")
        let data = try #require(Self.onePixelImage().jpegData(compressionQuality: 0.9))

        ArtworkPasteboard.copy(data, to: pasteboard)
        #expect(pasteboard.data(forPasteboardType: UTType.jpeg.identifier) == data)
        #expect(ArtworkPasteboard.hasImage(pasteboard))
        #expect(ArtworkPasteboard.imageData(from: pasteboard) == data)
    }

    @Test("copied png bytes round trip untouched")
    func pngRoundTrip() throws {
        let pasteboard = Self.makePasteboard("png")
        let data = try #require(Self.onePixelImage().pngData())

        ArtworkPasteboard.copy(data, to: pasteboard)
        #expect(pasteboard.data(forPasteboardType: UTType.png.identifier) == data)
        #expect(ArtworkPasteboard.imageData(from: pasteboard) == data)
    }

    @Test("copying another format normalizes it to jpeg")
    func copyNormalizesOtherFormats() throws {
        let pasteboard = Self.makePasteboard("normalize")
        ArtworkPasteboard.copy(try Self.tiffData(), to: pasteboard)

        let data = try #require(pasteboard.data(forPasteboardType: UTType.jpeg.identifier))
        #expect(data.starts(with: [0xff, 0xd8]))
    }

    @Test("copying garbage leaves the pasteboard empty")
    func copyRejectsGarbage() {
        let pasteboard = Self.makePasteboard("garbage")
        ArtworkPasteboard.copy(Data("not an image".utf8), to: pasteboard)
        #expect(!ArtworkPasteboard.hasImage(pasteboard))
        #expect(ArtworkPasteboard.imageData(from: pasteboard) == nil)
    }

    @Test("a paste from an app that put up another image format still works")
    func pasteOtherFormats() throws {
        let pasteboard = Self.makePasteboard("tiff")
        let tiff = try Self.tiffData()
        pasteboard.setData(tiff, forPasteboardType: UTType.tiff.identifier)

        #expect(ArtworkPasteboard.hasImage(pasteboard))
        let data = try #require(ArtworkPasteboard.imageData(from: pasteboard))
        #expect(data == tiff)
        #expect(UIImage(data: data) != nil)
    }

    @Test("non-image pasteboard contents are ignored")
    func ignoresNonImages() {
        let pasteboard = Self.makePasteboard("text")
        #expect(!ArtworkPasteboard.hasImage(pasteboard))
        #expect(ArtworkPasteboard.imageData(from: pasteboard) == nil)

        pasteboard.string = "hello"
        #expect(!ArtworkPasteboard.hasImage(pasteboard))
        #expect(ArtworkPasteboard.imageData(from: pasteboard) == nil)
    }
}
