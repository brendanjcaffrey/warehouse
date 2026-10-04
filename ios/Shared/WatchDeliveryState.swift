import Foundation

/// unreadable state is retried intact; only decoding failures can be rebuilt from independent authority.
struct WatchDeliveryState {
    var repairsDamage = false
    var read: (URL) throws -> Data = { try Data(contentsOf: $0) }
    var write: (Data, URL) throws -> Void = { data, url in
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func load<T: Decodable>(_ type: T.Type, from url: URL, empty: @autoclosure () -> T) throws -> (value: T, repaired: Bool) {
        let data: Data
        do {
            data = try read(url)
        } catch {
            guard Self.isMissing(error) else { throw error }
            return (empty(), false)
        }
        do {
            return (try JSONDecoder().decode(type, from: data), false)
        } catch is DecodingError {
            guard repairsDamage else { throw WatchDeliveryStartupError.damaged }
            // copy before replacement so an interrupted rebuild still leaves the original journal recoverable.
            let archive = url.deletingLastPathComponent().appending(path: "recovery")
                .appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
            try write(data, archive)
            return (empty(), true)
        }
    }

    static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code)
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try write(JSONEncoder().encode(value), url)
    }
}

enum WatchDeliveryStartupError: LocalizedError {
    case damaged

    var errorDescription: String? {
        "Saved delivery state could not be read. Retry delivery to recover it. Downloaded music remains available."
    }
}
