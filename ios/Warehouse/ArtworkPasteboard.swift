import UIKit
import UniformTypeIdentifiers

/// copy & paste between the edit form's artwork & the system pasteboard;
/// jpg & png bytes round trip untouched so the content addressed filename
/// stays stable when copying within the app
@MainActor
enum ArtworkPasteboard {
    static func copy(_ data: Data, to pasteboard: UIPasteboard = .general) {
        guard let (ext, encoded) = ArtworkFile.encode(data) else { return }
        let type = ext == "jpg" ? UTType.jpeg : UTType.png
        pasteboard.setData(encoded, forPasteboardType: type.identifier)
    }

    /// whether a paste would find an image; only looks at the advertised
    /// types so checking doesn't trigger the system paste prompt
    static func hasImage(_ pasteboard: UIPasteboard = .general) -> Bool {
        pasteboard.types.contains { UTType($0)?.conforms(to: .image) == true }
    }

    /// the pasted image's raw bytes: jpg & png are taken as is, while other
    /// formats another app put up (heic, webp, gif...) come back raw & get
    /// re-encoded by the artwork pipeline on save
    static func imageData(from pasteboard: UIPasteboard = .general) -> Data? {
        let preferred = [UTType.jpeg.identifier, UTType.png.identifier]
        let types = preferred + pasteboard.types.filter { !preferred.contains($0) }
        for type in types {
            if let data = pasteboard.data(forPasteboardType: type), UIImage(data: data) != nil {
                return data
            }
        }
        return nil
    }
}
