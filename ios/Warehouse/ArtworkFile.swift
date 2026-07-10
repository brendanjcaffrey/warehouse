import CryptoKit
import UIKit

/// turns picked image data into the server's content addressed artwork file,
/// named <md5>.<jpg|png>; jpg & png pass through untouched while anything
/// else the photo picker hands over (heic mostly) is re-encoded as jpeg
enum ArtworkFile {
    static func prepare(_ data: Data) -> (filename: String, data: Data)? {
        guard let (ext, encoded) = encode(data) else { return nil }
        let digest = Insecure.MD5.hash(data: encoded)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return ("\(hex).\(ext)", encoded)
    }

    static func encode(_ data: Data) -> (ext: String, data: Data)? {
        if data.starts(with: [0xff, 0xd8]) { return ("jpg", data) }
        if data.starts(with: [0x89, 0x50, 0x4e, 0x47]) { return ("png", data) }
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.9) else { return nil }
        return ("jpg", jpeg)
    }
}
