import SwiftUI

struct SettingsView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncStore.self) private var sync

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent("URL", value: auth.serverURL)
                }

                Section("Library") {
                    libraryRows
                }

                Section {
                    Button(role: .destructive) {
                        auth.logOut()
                    } label: {
                        Label {
                            Text("Log Out")
                        } icon: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
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

    private func downloadDetail(_ progress: DownloadProgress) -> String {
        var detail = "\(progress.finished) of \(progress.total)"
        if progress.failed > 0 {
            detail += " · \(progress.failed) failed"
        }
        return detail
    }
}
