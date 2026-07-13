import Foundation

/// counts & sizes of what's on the watch, shown at the top of the sync detail
struct StorageSummary: Equatable, Sendable {
    let trackCount: Int
    let artworkCount: Int
    let usedText: String
    /// nil when the device can't report its capacity
    let freeText: String?

    init(stats: DownloadStats, storage: DeviceStorage?) {
        trackCount = stats.trackCount
        artworkCount = stats.artworkCount
        usedText = stats.totalBytes.formatted(.byteCount(style: .file))
        if let storage {
            let free = max(0, storage.totalBytes - storage.usedBytes)
            freeText = free.formatted(.byteCount(style: .file))
        } else {
            freeText = nil
        }
    }
}

/// pure text & timing helpers behind the watch's sync detail view. kept out
/// of the views so they can be tested; nothing in the watch target is
enum SyncActivityFormatting {
    /// "just now", "8s", "1m 12s", "1h 4m"
    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded(.down))
        guard seconds >= 1 else { return "just now" }
        if seconds < 60 {
            return "\(seconds)s"
        }
        if seconds < 3600 {
            let minutes = seconds / 60
            let remainder = seconds % 60
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
    }

    static func sinceLastFile(lastArrivalAt: Date?, now: Date) -> TimeInterval? {
        guard let lastArrivalAt else { return nil }
        return max(0, now.timeIntervalSince(lastArrivalAt))
    }

    /// how long until the downloader re-sends its missing list; nil when
    /// nothing is downloading or nothing has been asked for yet
    static func untilNextNudge(
        lastRequestAt: Date?,
        isDownloading: Bool,
        interval: TimeInterval = RelayTiming.nudgeInterval,
        now: Date
    ) -> TimeInterval? {
        guard isDownloading, let lastRequestAt else { return nil }
        return max(0, interval - now.timeIntervalSince(lastRequestAt))
    }

    /// the proof-of-life line: "Last file 1m 12s ago · asking again in 23s"
    static func heartbeat(_ status: SyncActivityLog.Status) -> String? {
        var parts: [String] = []
        if let sinceLastFile = status.sinceLastFile {
            parts.append("Last file \(elapsed(sinceLastFile)) ago")
        } else if status.untilNextNudge != nil {
            parts.append("No files yet")
        }
        if let untilNextNudge = status.untilNextNudge {
            parts.append("asking again in \(elapsed(untilNextNudge))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// music filename -> track name, so arrivals read as songs not hashes
    static func nameIndex(_ songs: [Song]) -> [String: String] {
        var index = [String: String]()
        for song in songs {
            index[song.musicFilename] = song.name
        }
        return index
    }

    /// falls back to the filename when the songs list is empty or stale, which
    /// it is during a first-ever sync
    static func describe(_ file: FileToDownload, index: [String: String]) -> String {
        switch file.type {
        case .music:
            return index[file.filename] ?? file.filename
        case .artwork:
            return "artwork \(file.filename.prefix(6))"
        }
    }
}
