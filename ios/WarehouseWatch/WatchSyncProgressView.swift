import SwiftUI

struct WatchSyncProgressView: View {
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync
    @Environment(SyncActivityLog.self) private var activity

    var body: some View {
        // this view stands in for the whole app while a sync runs, so it owns
        // its own stack to push the detail view onto
        NavigationStack {
            ScrollView {
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 8) {
            switch sync.state {
            case .idle, .checkingForUpdates, .updateAvailable:
                ProgressView()
                Text("Checking for updates…")
                    .font(.footnote)
            case .fetchingLibrary:
                ProgressView()
                Text("Downloading library…")
                    .font(.footnote)
            case .savingLibrary:
                ProgressView()
                Text("Saving library…")
                    .font(.footnote)
            case .downloadingFiles(let progress):
                ProgressView(value: progress.fraction)
                if progress.music.total > 0 {
                    Text("Music \(progress.music.finished) of \(progress.music.total)")
                        .font(.footnote)
                }
                if progress.artwork.total > 0 {
                    Text("Artwork \(progress.artwork.finished) of \(progress.artwork.total)")
                        .font(.footnote)
                }
                heartbeat
                Text("Keep your iPhone nearby. Transfers are faster with the watch on its charger.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            case .upToDate(let failedDownloads):
                if failedDownloads > 0 {
                    Text("\(failedDownloads) downloads failed.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    retryButton("Retry")
                } else {
                    // only visible when the synced playlists have no tracks
                    Text("No tracks synced yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    retryButton("Sync Again")
                }
            case .storageFull:
                Text("Not enough storage on this watch. Sync fewer playlists.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                retryButton("Retry")
            case .error(let message):
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                retryButton("Retry")
            }
            NavigationLink {
                WatchSyncDetailView()
            } label: {
                Label("Details", systemImage: "list.bullet.rectangle")
                    .font(.footnote)
            }
        }
        .padding()
    }

    /// the counts above can sit unchanged for minutes while the phone works
    /// through its queue; this ticks every second so a slow sync still reads
    /// as a live one
    private var heartbeat: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let line = SyncActivityFormatting.heartbeat(activity.status(now: context.date)) {
                Text(line)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private func retryButton(_ title: String) -> some View {
        Button(title) {
            Task {
                await sync.sync(token: settings.token, baseURL: settings.baseURL())
            }
        }
    }
}
