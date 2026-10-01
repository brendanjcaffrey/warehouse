import Foundation
import SwiftUI

/// one presentation boundary for phone receipts and the watch's actual stored music.
struct WatchLibraryProgress: Codable, Equatable {
    enum State: String, Codable, Equatable {
        case preparing, waiting, needsPhoneSync, storageFull, failed, ready, empty, setup, refreshFailed
    }

    struct Counts: Codable, Equatable {
        var total = 0
        var downloaded = 0
        var failed = 0
        var missingOnPhone = 0
        var storageFull = 0

        init(statuses: [WatchContentStatus] = []) {
            total = statuses.count
            downloaded = statuses.filter { $0 == .delivered }.count
            failed = statuses.filter { $0 == .failed }.count
            missingOnPhone = statuses.filter { $0 == .missingOnPhone }.count
            storageFull = statuses.filter { $0 == .storageFull }.count
        }

        var text: String { "\(downloaded.formatted()) of \(total.formatted()) downloaded" }
    }

    var state: State = .preparing
    var music = Counts()
    var artwork = Counts()

    var title: String {
        switch state {
        case .preparing: "Preparing"
        case .waiting: "Waiting for delivery"
        case .needsPhoneSync: "Sync iPhone library"
        case .storageFull: "Storage Full"
        case .failed: "Music delivery failed"
        case .ready: "Ready"
        case .empty: "No songs selected"
        case .setup: "Set up on iPhone"
        case .refreshFailed: "Library refresh failed"
        }
    }

    var detail: String {
        switch state {
        case .preparing: "Preparing the selected playlists. Saved music remains available."
        case .waiting: "Delivery continues when the devices can connect and the system allows."
        case .needsPhoneSync: "Sync the library in the iPhone app to download missing files."
        case .storageFull: "Free space on the watch or deselect playlists on iPhone. Downloaded songs remain playable."
        case .failed: "Some files could not be delivered. Downloaded songs remain playable."
        case .ready: "All selected music is downloaded on the watch."
        case .empty: "Choose playlists in the iPhone app's Apple Watch settings."
        case .setup: "Sign in and sync the library on iPhone, then select Apple Watch playlists."
        case .refreshFailed: "Saved music remains available. Sync the library on iPhone to try again."
        }
    }

    static func make(head: WatchLibraryHead?, snapshot: WatchLibrarySnapshot?, playlistID: String? = nil,
                     status: (LibraryFileType, String) -> WatchContentStatus) -> Self {
        guard let snapshot, let library = try? snapshot.validatedLibrary() else {
            return Self(state: head?.failed == true ? .refreshFailed : head?.libraryID == nil ? .setup : .preparing)
        }
        let tracks: [Track]
        if let playlistID {
            guard let playlist = library.playlists.first(where: { $0.id == playlistID }) else { return Self(state: .preparing) }
            let ids = Set(playlist.trackIds)
            tracks = library.tracks.filter { ids.contains($0.id) }
        } else {
            tracks = library.tracks
        }
        let music = Counts(statuses: tracks.map { status(.music, $0.musicFilename) })
        let artwork = Counts(statuses: Set(tracks.map(\.artworkFilename).filter { !$0.isEmpty }).sorted().map { status(.artwork, $0) })
        let state: State
        if head?.failed == true { state = .refreshFailed
        } else if head?.libraryID == nil { state = .setup
        } else if head != snapshot.head { state = .preparing
        } else if music.total == 0 { state = .empty
        } else if music.downloaded == music.total { state = .ready
        } else if music.storageFull > 0 { state = .storageFull
        } else if music.failed > 0 { state = .failed
        } else if music.missingOnPhone > 0 { state = .needsPhoneSync
        } else { state = .waiting }
        return Self(state: state, music: music, artwork: artwork)
    }
}

struct WatchLibraryProgressView: View {
    let progress: WatchLibraryProgress
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(progress.title)
            if progress.music.total > 0 {
                Text(progress.music.text)
                    .font(.footnote)
                ProgressView(value: Double(progress.music.downloaded), total: Double(progress.music.total))
            }
            if !compact {
                Text(progress.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if progress.artwork.total > 0 {
                    Text("Artwork: \(progress.artwork.text)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if progress.artwork.missingOnPhone > 0 {
                        Text("Sync the iPhone library to download missing artwork.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if progress.artwork.storageFull > 0 {
                        Text("Artwork is waiting for space on the watch.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if progress.artwork.failed > 0 {
                        Text("\(progress.artwork.failed.formatted()) artwork files failed. Music is still playable.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// phone preparation status augments local counts and never establishes watch readiness.
struct WatchLibraryDeliveryReport: Codable, Equatable {
    let head: WatchLibraryHead
    let sequence: Int64
    let overall: WatchLibraryProgress
    let playlists: [String: WatchLibraryProgress]

    func encode() throws -> [String: Any] {
        ["kind": "watchLibraryDeliveryReport", "report": try JSONEncoder().encode(self)]
    }

    init(head: WatchLibraryHead, sequence: Int64, overall: WatchLibraryProgress, playlists: [String: WatchLibraryProgress]) {
        self.head = head
        self.sequence = sequence
        self.overall = overall
        self.playlists = playlists
    }

    init?(dictionary: [String: Any]) {
        guard dictionary["kind"] as? String == "watchLibraryDeliveryReport", let data = dictionary["report"] as? Data,
              let report = try? JSONDecoder().decode(Self.self, from: data), report.head.version == 1,
              report.head.metadataReady, report.sequence > 0 else { return nil }
        self = report
    }
}
