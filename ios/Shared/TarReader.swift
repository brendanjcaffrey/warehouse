import Foundation

enum TarError: Error, Equatable {
    case truncated
    case badHeader
    case unsafeName(String)
}

/// one 512-byte ustar header block; only the fields the bundle format uses
struct TarHeader: Equatable, Sendable {
    static let blockSize = 512

    let name: String
    let size: Int
    let typeflag: UInt8

    /// regular files are typeflag '0' (or nul in very old tars)
    var isRegularFile: Bool {
        typeflag == 0 || typeflag == UInt8(ascii: "0")
    }

    /// nil for the all-zero block that terminates an archive
    static func parse(_ block: Data) throws -> TarHeader? {
        guard block.count == blockSize else { throw TarError.truncated }
        guard block.contains(where: { $0 != 0 }) else { return nil }

        guard let name = field(block, offset: 0, length: 100), !name.isEmpty else { throw TarError.badHeader }
        guard let size = octal(field(block, offset: 124, length: 12)) else { throw TarError.badHeader }
        return TarHeader(name: name, size: size, typeflag: block[block.startIndex + 156])
    }

    /// a nul-terminated fixed-width string field
    private static func field(_ block: Data, offset: Int, length: Int) -> String? {
        let start = block.startIndex + offset
        let bytes = block[start..<start + length].prefix { $0 != 0 }
        return String(data: bytes, encoding: .utf8)
    }

    private static func octal(_ text: String?) -> Int? {
        guard let text else { return nil }
        return Int(text.trimmingCharacters(in: CharacterSet(charactersIn: " \0")), radix: 8)
    }
}

/// a minimal streaming reader for the plain ustar tars the server builds;
/// entries are handed to the callback one at a time so only a single file is
/// ever buffered in memory
enum TarReader {
    static func extract(from url: URL, write: (String, Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        while true {
            let block = try read(handle, count: TarHeader.blockSize)
            // a clean end of file where a header should be counts as done, so
            // an archive missing its terminator blocks still extracts
            if block.isEmpty { return }
            guard let header = try TarHeader.parse(block) else { return }

            let name = header.name
            if name.hasPrefix("/") || name.split(separator: "/").contains("..") {
                throw TarError.unsafeName(name)
            }

            let padding = (TarHeader.blockSize - header.size % TarHeader.blockSize) % TarHeader.blockSize
            if header.isRegularFile {
                let data = try read(handle, count: header.size)
                guard data.count == header.size else { throw TarError.truncated }
                try write(name, data)
                _ = try read(handle, count: padding)
            } else {
                // directories, pax headers etc. never come from the server;
                // skip over them defensively
                _ = try read(handle, count: header.size + padding)
            }
        }
    }

    private static func read(_ handle: FileHandle, count wanted: Int) throws -> Data {
        guard wanted > 0 else { return Data() }
        var data = Data()
        while data.count < wanted {
            guard let chunk = try handle.read(upToCount: wanted - data.count), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        // a header block that exists but is cut short is a mangled archive;
        // a partial data read surfaces as a size mismatch in the caller
        if !data.isEmpty && data.count < wanted && wanted == TarHeader.blockSize {
            throw TarError.truncated
        }
        return data
    }
}
