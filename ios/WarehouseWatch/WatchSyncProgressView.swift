import SwiftUI

/// stands in for the whole app until there's a track list to show; only the
/// library is fetched here, so this is a short wait rather than a whole sync
struct WatchSyncProgressView: View {
    @Environment(WatchSettingsStore.self) private var settings
    @Environment(SyncStore.self) private var sync

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                content
            }
            .padding()
        }
    }

    @ViewBuilder
    private var content: some View {
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
        case .upToDate:
            // only visible when the synced playlists have no tracks
            Text("No tracks synced yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            retryButton("Check Again")
        case .error(let message):
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            retryButton("Retry")
        case .downloadingFiles, .storageFull:
            // tracks are fetched as they play, so the watch never gets here
            EmptyView()
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
