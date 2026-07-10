import CryptoKit
import Testing
import UIKit
@testable import Warehouse

@Suite("ArtworkFile")
struct ArtworkFileTests {
    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test("jpg data passes through with a content addressed name")
    func jpgPassesThrough() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        let data = try #require(image.jpegData(compressionQuality: 0.9))

        let prepared = try #require(ArtworkFile.prepare(data))
        #expect(prepared.data == data)
        #expect(prepared.filename == "\(Self.md5(data)).jpg")
    }

    @Test("png data passes through with a content addressed name")
    func pngPassesThrough() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        let data = try #require(image.pngData())

        let prepared = try #require(ArtworkFile.prepare(data))
        #expect(prepared.data == data)
        #expect(prepared.filename == "\(Self.md5(data)).png")
    }

    @Test("other image formats are re-encoded as jpeg")
    func reencodesOtherFormats() throws {
        // tiff isn't accepted by the server so it must come back as a jpg
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
        let cgImage = try #require(image.cgImage)
        let tiff = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(tiff, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, nil)
        #expect(CGImageDestinationFinalize(destination))

        let prepared = try #require(ArtworkFile.prepare(tiff as Data))
        #expect(prepared.data.starts(with: [0xff, 0xd8]))
        #expect(prepared.filename == "\(Self.md5(prepared.data)).jpg")
    }

    @Test("undecodable data is rejected")
    func rejectsGarbage() {
        #expect(ArtworkFile.prepare(Data("not an image".utf8)) == nil)
        #expect(ArtworkFile.prepare(Data()) == nil)
    }
}
