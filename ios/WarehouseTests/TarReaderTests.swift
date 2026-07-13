import Foundation
import Testing

@testable import Warehouse

@Suite("TarReader")
struct TarReaderTests {
    /// hand-writes a plain ustar archive, matching what the server's minitar
    /// produces: 512-byte headers, octal sizes, zero-padded entries and two
    /// zero blocks at the end
    private func tarBytes(entries: [(name: String, data: Data, typeflag: UInt8)], terminated: Bool = true) -> Data {
        var bytes = Data()
        for entry in entries {
            bytes.append(header(name: entry.name, size: entry.data.count, typeflag: entry.typeflag))
            bytes.append(entry.data)
            let padding = (512 - entry.data.count % 512) % 512
            bytes.append(Data(count: padding))
        }
        if terminated {
            bytes.append(Data(count: 1024))
        }
        return bytes
    }

    private func header(name: String, size: Int, typeflag: UInt8) -> Data {
        var block = Data(count: 512)
        block.replaceSubrange(0..<name.utf8.count, with: Data(name.utf8))
        let sizeField = String(format: "%011o", size) + "\0"
        block.replaceSubrange(124..<124 + sizeField.utf8.count, with: Data(sizeField.utf8))
        block[156] = typeflag
        // checksum is computed with its own field as spaces
        block.replaceSubrange(148..<156, with: Data("        ".utf8))
        let checksum = block.reduce(0) { $0 + Int($1) }
        let checksumField = String(format: "%06o", checksum) + "\0 "
        block.replaceSubrange(148..<148 + checksumField.utf8.count, with: Data(checksumField.utf8))
        return block
    }

    private func extract(_ bytes: Data) throws -> [(String, Data)] {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var extracted: [(String, Data)] = []
        try TarReader.extract(from: url) { name, data in
            extracted.append((name, data))
        }
        return extracted
    }

    @Test("a single entry round-trips")
    func roundTrips() throws {
        let contents = Data("fake mp3 contents".utf8)
        let extracted = try extract(tarBytes(entries: [("music/abc.mp3", contents, UInt8(ascii: "0"))]))

        #expect(extracted.count == 1)
        #expect(extracted[0].0 == "music/abc.mp3")
        #expect(extracted[0].1 == contents)
    }

    @Test("multiple entries extract in order, sizes padded to blocks")
    func multipleEntries() throws {
        let first = Data(repeating: 0xab, count: 513)
        let second = Data(repeating: 0xcd, count: 512)
        let third = Data("x".utf8)
        let extracted = try extract(tarBytes(entries: [
            ("music/a.mp3", first, UInt8(ascii: "0")),
            ("music/b.mp3", second, UInt8(ascii: "0")),
            ("artwork/c.jpg", third, UInt8(ascii: "0"))
        ]))

        #expect(extracted.map(\.0) == ["music/a.mp3", "music/b.mp3", "artwork/c.jpg"])
        #expect(extracted.map(\.1) == [first, second, third])
    }

    @Test("an empty file extracts as empty")
    func emptyFile() throws {
        let extracted = try extract(tarBytes(entries: [("music/empty.mp3", Data(), UInt8(ascii: "0"))]))

        #expect(extracted.count == 1)
        #expect(extracted[0].1.isEmpty)
    }

    @Test("a nul typeflag counts as a regular file")
    func nulTypeflag() throws {
        let extracted = try extract(tarBytes(entries: [("music/old.mp3", Data("old".utf8), 0)]))

        #expect(extracted.count == 1)
    }

    @Test("non-file entries are skipped over")
    func skipsNonFiles() throws {
        let contents = Data("real".utf8)
        let extracted = try extract(tarBytes(entries: [
            ("music/", Data(), UInt8(ascii: "5")),
            ("pax", Data("junk".utf8), UInt8(ascii: "x")),
            ("music/real.mp3", contents, UInt8(ascii: "0"))
        ]))

        #expect(extracted.count == 1)
        #expect(extracted[0].0 == "music/real.mp3")
        #expect(extracted[0].1 == contents)
    }

    @Test("a missing terminator still extracts cleanly")
    func toleratesMissingTerminator() throws {
        let contents = Data("abc".utf8)
        let extracted = try extract(tarBytes(
            entries: [("music/a.mp3", contents, UInt8(ascii: "0"))], terminated: false))

        #expect(extracted.count == 1)
    }

    @Test("truncated data throws")
    func truncatedThrows() throws {
        var bytes = tarBytes(entries: [("music/a.mp3", Data(repeating: 1, count: 600), UInt8(ascii: "0"))])
        bytes = bytes.prefix(700)

        #expect(throws: TarError.truncated) {
            _ = try extract(bytes)
        }
    }

    @Test("a truncated header throws")
    func truncatedHeaderThrows() throws {
        let bytes = header(name: "music/a.mp3", size: 0, typeflag: UInt8(ascii: "0")).prefix(100)

        #expect(throws: TarError.truncated) {
            _ = try extract(Data(bytes))
        }
    }

    @Test("unsafe entry names are rejected")
    func rejectsUnsafeNames() throws {
        #expect(throws: TarError.unsafeName("../../evil.mp3")) {
            _ = try extract(tarBytes(entries: [("../../evil.mp3", Data(), UInt8(ascii: "0"))]))
        }
        #expect(throws: TarError.unsafeName("/etc/passwd")) {
            _ = try extract(tarBytes(entries: [("/etc/passwd", Data(), UInt8(ascii: "0"))]))
        }
    }

    @Test("a header block parses its fields")
    func parsesHeader() throws {
        let block = header(name: "artwork/x.jpg", size: 1234, typeflag: UInt8(ascii: "0"))
        let parsed = try TarHeader.parse(block)

        #expect(parsed?.name == "artwork/x.jpg")
        #expect(parsed?.size == 1234)
        #expect(parsed?.isRegularFile == true)
    }

    @Test("the all-zero terminator block parses as nil")
    func parsesTerminator() throws {
        #expect(try TarHeader.parse(Data(count: 512)) == nil)
    }

    @Test("a garbage size field is a bad header")
    func badSizeThrows() throws {
        var block = header(name: "music/a.mp3", size: 0, typeflag: UInt8(ascii: "0"))
        block.replaceSubrange(124..<136, with: Data("not a number".utf8))

        #expect(throws: TarError.badHeader) {
            _ = try TarHeader.parse(block)
        }
    }
}
