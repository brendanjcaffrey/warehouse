import SwiftUI

struct SettingsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncStore.self) private var sync

    @State private var downloads: DownloadStats?
    @State private var storage: DeviceStorage?
    @State private var confirmingLogOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("URL", value: auth.serverURL)
                }

                Section("Library") {
                    libraryRows
                }

                Section("Downloads") {
                    downloadRows
                }

                Section {
                    Button(role: .destructive) {
                        confirmingLogOut = true
                    } label: {
                        Label {
                            Text("Log Out")
                        } icon: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                        }
                    }
                    .confirmationDialog(
                        "Are you sure you want to log out?",
                        isPresented: $confirmingLogOut,
                        titleVisibility: .visible
                    ) {
                        Button("Log Out", role: .destructive) {
                            auth.logOut()
                        }
                    } message: {
                        Text("Your library and downloads will stay on this device.")
                    }
                }
            }
            .navigationTitle("Settings")
            .task(id: [sync.completedSyncs, sync.downloadRefreshTicks]) {
                // rescan after syncs and periodically while files download
                downloads = await Task.detached(priority: .utility) { [sync] in
                    sync.downloadStats()
                }.value
                storage = FileStore.deviceStorage()
            }
        }
    }

    @ViewBuilder
    private var downloadRows: some View {
        if let downloads {
            LabeledContent("Tracks", value: downloads.trackCount.formatted())
            LabeledContent("Artwork", value: downloads.artworkCount.formatted())
            LabeledContent("Size", value: downloads.totalBytes.formatted(.byteCount(style: .file)))
        } else {
            progressRow("Calculating…")
        }
        if let storage {
            LabeledContent("Device Storage", value: storageDetail(storage))
        }
    }

    @ViewBuilder
    private var libraryRows: some View {
        switch sync.state {
        case .idle:
            HStack {
                Text("Waiting to sync")
                    .foregroundStyle(.secondary)
                Spacer()
                checkButton
            }
        case .checkingForUpdates:
            progressRow("Checking for updates…")
        case .updateAvailable(let newLibraryData, let missingFiles):
            HStack {
                Label(
                    newLibraryData ? "New data available" : "\(missingFiles) files to download",
                    systemImage: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                Spacer()
                syncButton("Sync Now")
            }
        case .fetchingLibrary:
            progressRow("Downloading new library data…")
        case .savingLibrary:
            progressRow("Saving library data…")
        case .downloadingFiles(let progress):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading files")
                ProgressView(value: progress.fraction)
                Text(downloadDetail(progress))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .upToDate(let failedDownloads):
            if failedDownloads > 0 {
                HStack {
                    Label("\(failedDownloads) files failed to download", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    syncButton("Retry")
                }
            } else {
                HStack {
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    checkButton
                }
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            syncButton("Retry Sync")
        }
    }

    private var checkButton: some View {
        Button("Check for Updates") {
            Task {
                await sync.checkForUpdates(token: auth.token, baseURL: auth.baseURL())
            }
        }
        .buttonStyle(.borderless)
    }

    private func syncButton(_ title: String) -> some View {
        Button(title) {
            Task {
                await sync.sync(token: auth.token, baseURL: auth.baseURL())
            }
        }
        .buttonStyle(.borderless)
    }

    private func progressRow(_ text: String) -> some View {
        HStack {
            Text(text)
            Spacer()
            ProgressView()
        }
    }

    private func storageDetail(_ storage: DeviceStorage) -> String {
        let used = storage.usedBytes.formatted(.byteCount(style: .file))
        let total = storage.totalBytes.formatted(.byteCount(style: .file))
        return "\(used) of \(total) used"
    }

    private func downloadDetail(_ progress: DownloadProgress) -> String {
        var detail = "\(progress.finished) of \(progress.total)"
        if progress.failed > 0 {
            detail += " · \(progress.failed) failed"
        }
        return detail
    }
}
