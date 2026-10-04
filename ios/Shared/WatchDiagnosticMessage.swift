import Foundation

/// live messages carry bounded pieces; exports retain the complete capture.
struct WatchDiagnosticMessage: Codable {
    static let chunkBytes = 24_000
    static let maximumReportBytes = 1_024_000
    static let saved = Data("saved".utf8)
    static let more = Data("more".utf8)

    let kind: String
    let id: UUID
    let index: Int
    let count: Int
    let payload: Data

    static func messages(_ data: Data) throws -> [Data] {
        guard data.count <= maximumReportBytes else { throw WatchDiagnosticSendError.reportTooLarge }
        if data.count <= chunkBytes { return [data] }
        let id = UUID()
        let count = (data.count + chunkBytes - 1) / chunkBytes
        return try (0..<count).map { index in
            let start = index * chunkBytes
            let payload = data.subdata(in: start..<min(start + chunkBytes, data.count))
            return try JSONEncoder().encode(Self(kind: "watchDiagnosticsChunk", id: id,
                                               index: index, count: count, payload: payload))
        }
    }

    static func decode(_ data: Data) -> Self? {
        guard data.count <= chunkBytes * 2,
              let message = try? JSONDecoder().decode(Self.self, from: data),
              message.kind == "watchDiagnosticsChunk" else { return nil }
        return message
    }
}

enum WatchDiagnosticSendError: Error, Equatable {
    case encoding, reportTooLarge, phoneRejected
    case connectivity(code: Int?)

    var message: String {
        switch self {
        case .encoding: "Couldn’t prepare the capture."
        case .reportTooLarge: "The capture exceeds the report size limit."
        case .phoneRejected: "The iPhone couldn’t save the capture. Check that both apps are updated and try again."
        case .connectivity(let code):
            if let code { "Couldn’t send. Watch Connectivity error \(code)." } else { "Couldn’t send. iPhone connection unavailable." }
        }
    }
}
