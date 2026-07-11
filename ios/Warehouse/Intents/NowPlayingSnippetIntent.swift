import AppIntents
import SwiftUI
import UIKit

/// renders the interactive now playing card shown after a play intent runs;
/// the system re-performs this intent to refresh the card after any of its
/// buttons fire
struct NowPlayingSnippetIntent: SnippetIntent {
    static let title: LocalizedStringResource = "Now Playing"
    static let description = IntentDescription("Shows the song that's playing.")
    /// only ever shown as a snippet, never offered as a standalone action
    static let isDiscoverable = false

    @Dependency private var service: IntentPlaybackService
    @Dependency private var player: PlayerStore

    @MainActor
    func perform() async throws -> some IntentResult & ShowsSnippetView {
        // snippets render out of process, so artwork is loaded here instead
        // of handing the view a file url
        let song = player.song
        let artwork = song?.artworkFilename
            .flatMap { service.artworkURL(filename: $0) }
            .flatMap { UIImage(contentsOfFile: $0.path) }
        return .result(view: NowPlayingSnippetView(
            songName: song?.name,
            artistName: song?.artistName ?? "",
            artwork: artwork,
            isPlaying: player.isPlaying))
    }
}

struct NowPlayingSnippetView: View {
    let songName: String?
    let artistName: String
    let artwork: UIImage?
    let isPlaying: Bool

    var body: some View {
        HStack(spacing: 12) {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "music.note")
                            .foregroundStyle(.secondary)
                    }
            }

            VStack(alignment: .leading) {
                Text(songName ?? "Nothing Playing")
                    .font(.headline)
                    .lineLimit(1)
                if !artistName.isEmpty {
                    Text(artistName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if songName != nil {
                HStack(spacing: 16) {
                    Button(intent: SkipToPreviousIntent()) {
                        Image(systemName: "backward.fill")
                    }
                    Button(intent: TogglePlayPauseIntent()) {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    }
                    Button(intent: SkipToNextIntent()) {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.plain)
                .font(.title3)
            }
        }
        .padding()
    }
}
