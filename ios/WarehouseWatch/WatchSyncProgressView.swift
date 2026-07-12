import SwiftUI

struct WatchSyncProgressView: View {
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync

    var body: some View {
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
                Text("Downloading \(progress.finished) of \(progress.total)")
                    .font(.footnote)
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
        }
        .padding()
    }

    private func retryButton(_ title: String) -> some View {
        Button(title) {
            Task {
                await sync.sync(token: settings.token, baseURL: settings.baseURL())
            }
        }
    }
}
