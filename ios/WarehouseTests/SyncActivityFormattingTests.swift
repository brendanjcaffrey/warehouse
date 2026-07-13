import Foundation
import Testing

@testable import Warehouse

@Suite("SyncActivityFormatting")
struct SyncActivityFormattingTests {
    private let now = Date(timeIntervalSince1970: 10_000)

    private func status(
        sinceLastFile: TimeInterval? = nil,
        isDownloading: Bool = false
    ) -> SyncActivityLog.Status {
        SyncActivityLog.Status(sinceLastFile: sinceLastFile, isDownloading: isDownloading)
    }

    @Test("elapsed reads as a short duration")
    func formatsElapsed() {
        #expect(SyncActivityFormatting.elapsed(0.4) == "just now")
        #expect(SyncActivityFormatting.elapsed(8) == "8s")
        #expect(SyncActivityFormatting.elapsed(60) == "1m")
        #expect(SyncActivityFormatting.elapsed(72) == "1m 12s")
        #expect(SyncActivityFormatting.elapsed(3_600) == "1h")
        #expect(SyncActivityFormatting.elapsed(3_660) == "1h 1m")
    }

    @Test("time since the last file is nil until one arrives")
    func sinceLastFile() {
        #expect(SyncActivityFormatting.sinceLastFile(lastArrivalAt: nil, now: now) == nil)
        #expect(SyncActivityFormatting.sinceLastFile(lastArrivalAt: now - 30, now: now) == 30)
        // a clock that jumped backwards shouldn't read as negative
        #expect(SyncActivityFormatting.sinceLastFile(lastArrivalAt: now + 5, now: now) == 0)
    }

    @Test("the heartbeat line degrades as parts go missing")
    func heartbeat() {
        #expect(SyncActivityFormatting.heartbeat(status(sinceLastFile: 72, isDownloading: true))
            == "Last file 1m 12s ago")
        #expect(SyncActivityFormatting.heartbeat(status(sinceLastFile: 240))
            == "Last file 4m ago")
        #expect(SyncActivityFormatting.heartbeat(status(isDownloading: true)) == "No files yet")
        #expect(SyncActivityFormatting.heartbeat(status()) == nil)
    }

    @Test("a music file is named by its track, an unknown one by its filename")
    func describesMusic() {
        let index = SyncActivityFormatting.nameIndex([song(name: "Karma Police", filename: "abc.mp3")])

        #expect(SyncActivityFormatting.describe(
            FileToDownload(type: .music, filename: "abc.mp3"), index: index) == "Karma Police")
        #expect(SyncActivityFormatting.describe(
            FileToDownload(type: .music, filename: "zzz.mp3"), index: index) == "zzz.mp3")
    }

    @Test("artwork is labelled rather than named")
    func describesArtwork() {
        let described = SyncActivityFormatting.describe(
            FileToDownload(type: .artwork, filename: "a91c7f2b.jpg"), index: [:])

        #expect(described == "artwork a91c7f")
    }

    @Test("storage reads as counts, size used & size free")
    func summarizesStorage() {
        let stats = DownloadStats(trackCount: 24, artworkCount: 6, totalBytes: 118_000_000)
        let summary = StorageSummary(
            stats: stats,
            storage: DeviceStorage(usedBytes: 5_000_000_000, totalBytes: 8_000_000_000))

        #expect(summary.trackCount == 24)
        #expect(summary.artworkCount == 6)
        #expect(summary.usedText == 118_000_000.formatted(.byteCount(style: .file)))
        #expect(summary.freeText == Int64(3_000_000_000).formatted(.byteCount(style: .file)))
    }

    @Test("free space is omitted when the device won't report its capacity")
    func summarizesStorageWithoutCapacity() {
        let summary = StorageSummary(stats: DownloadStats(), storage: nil)

        #expect(summary.freeText == nil)
        #expect(summary.trackCount == 0)
    }

    private func song(name: String, filename: String) -> Song {
        Song(
            id: "1", name: name, sortName: name, artistName: "", artistSortName: "",
            albumArtistName: "", albumArtistSortName: "", albumName: "", albumSortName: "",
            genre: "", year: 0, duration: 0, start: 0, finish: 0, discNumber: 0, trackNumber: 0,
            playCount: 0, rating: 0, musicFilename: filename, artworkFilename: nil)
    }
}
