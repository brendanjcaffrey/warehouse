import Foundation

enum JWT {
    /// the server puts exp in the jwt header rather than the payload claims, see shared/jwt.rb
    static func expiry(of token: String) -> Date? {
        let segments = token.components(separatedBy: ".")
        guard segments.count == 3,
              let data = base64URLDecode(segments[0]),
              let header = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = header["exp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    /// anything we can't parse is treated as unexpired: the server is the judge of a
    /// token's validity, we'd rather refresh in the background than lock the user out
    static func isExpired(_ token: String, now: Date = .now) -> Bool {
        guard let expiry = expiry(of: token) else { return false }
        return expiry <= now
    }

    private static func base64URLDecode(_ segment: String) -> Data? {
        var base64 = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // base64url drops the padding, put it back
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}
