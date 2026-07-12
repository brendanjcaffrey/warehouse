import SwiftUI
import Yams
import PostgresNIO

struct ExportApp: App {
    @State private var authStatus: AuthStatus = MusicAuth.getStatus()
    func checkAuth() {
        authStatus = MusicAuth.getStatus()
    }
    func requestAuth() async {
        authStatus = await MusicAuth.request()
    }

    @State private var workspaceDirURL: Optional<URL> = FileSystem.tryGetPersisted(key: WORKSPACE_DIR_KEY)
    func getWorkspaceDir() {
        workspaceDirURL = FileSystem.getUserSelectedFolder()
        FileSystem.storeInBookmark(url: workspaceDirURL, key: WORKSPACE_DIR_KEY)
        exportError = nil
        validateConfig()
        checkArtworkDir()
    }

    func getConfigFileURL() -> URL? {
        guard let workspaceDirURL = workspaceDirURL else { return nil }
        return workspaceDirURL.appendingPathComponent(CONFIG_FILE_NAME)
    }

    @discardableResult
    func validateConfig() -> Bool {
        guard workspaceDirURL != nil else { return false }

        let configFileURL = getConfigFileURL()!
        do {
            let _ = try Config.readLocalConfig(configFileURL: configFileURL)
            return true
        } catch {
            exportError = "Failed to read config file in workspace \(configFileURL.relativeString) \(error.localizedDescription)"
            self.workspaceDirURL = nil
            FileSystem.storeInBookmark(url: nil, key: WORKSPACE_DIR_KEY)
            return false
        }
    }

    @discardableResult
    func checkMusicDir() -> SubpathCheck? {
        guard let workspaceDirURL = workspaceDirURL else { return nil }
        guard let configFileURL = getConfigFileURL() else { return nil }
        let music = Config.checkMusicPath(workspaceDirURL: workspaceDirURL, configFileURL: configFileURL)
        if music.success {
            return music
        } else {
            exportError = music.errorMsg
            return nil
        }
    }

    @discardableResult
    func checkArtworkDir() -> SubpathCheck? {
        guard let workspaceDirURL = workspaceDirURL else { return nil }
        guard let configFileURL = getConfigFileURL() else { return nil }
        let artwork = Config.checkArtworkPath(workspaceDirURL: workspaceDirURL, configFileURL: configFileURL)
        if artwork.success {
            return artwork
        } else {
            exportError = artwork.errorMsg
            return nil
        }
    }

    @State private var fastExport: Bool = false

    @State private var exportRunning: Bool = false
    @State private var exportMsg: Optional<String> = nil
    @State private var exportError: Optional<String> = nil
    @StateObject var exportProgress = ExportProgressModel()
    func exportLibrary() async {
        exportError = nil
        exportMsg = nil

        if !validateConfig() { return }

        let music = checkMusicDir()
        guard let music = music, music.success else { return }
        let artwork = checkArtworkDir()
        guard let artwork = artwork, artwork.success else { return }

        exportRunning = true
        let configFileURL = getConfigFileURL()!
        let musicDirURL = workspaceDirURL!.appending(path: music.subpath!)
        let artworkDirURL = workspaceDirURL!.appending(path: artwork.subpath!)

        let databaseConfig = try! Config.getDatabaseConfig(configFileURL: configFileURL)
        let library = Library(pgConfig: databaseConfig!, musicDirURL: musicDirURL, artworkDirURL: artworkDirURL)
        do {
            let error = try await library.export(progress: exportProgress, fast: fastExport)
            exportError = error
            if exportError == nil {
                exportMsg = exportProgress.status.toString()
            }
        } catch {
            exportError = error.localizedDescription
        }
        exportRunning = false
    }

    private var canExport: Bool {
        authStatus.authorized && workspaceDirURL != nil
    }

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header

                    ExportCard(title: "Music Library Access", systemImage: "music.note.house") {
                        authSection
                    }

                    ExportCard(title: "Workspace", systemImage: "folder") {
                        workspaceSection
                    }

                    ExportCard(title: "Options", systemImage: "slider.horizontal.3") {
                        Toggle(isOn: $fastExport) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Fast export").fontWeight(.medium)
                                Text("Assume track and artwork file checksums haven't changed.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(exportRunning)
                    }

                    exportSection
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 520, minHeight: 620)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .windowResizability(.contentMinSize)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Warehouse Export")
                .font(.largeTitle.bold())
            Text("Export your Apple Music library into Postgres.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var authSection: some View {
        if authStatus.authorized {
            StatusRow(systemImage: "checkmark.circle.fill",
                      tint: .green,
                      text: "Music library access granted.")
            HStack {
                Spacer()
                Button("Refresh Status", action: checkAuth)
                    .controlSize(.small)
            }
        } else {
            StatusRow(systemImage: "exclamationmark.triangle.fill",
                      tint: .orange,
                      text: "Not authorized: \(authStatus.error ?? "unknown error").")
            HStack {
                Button("Request Authorization") { Task { await requestAuth() } }
                    .buttonStyle(.borderedProminent)
                Button("Open System Settings", action: MusicAuth.openSettings)
                Spacer()
                Button("Refresh", action: checkAuth)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var workspaceSection: some View {
        if let url = workspaceDirURL {
            StatusRow(systemImage: "checkmark.circle.fill",
                      tint: .green,
                      text: url.path,
                      monospaced: true)
        } else {
            StatusRow(systemImage: "questionmark.circle.fill",
                      tint: .secondary,
                      text: "No workspace directory selected.")
        }
        HStack {
            Button(workspaceDirURL == nil ? "Choose Workspace…" : "Change Workspace…",
                   action: getWorkspaceDir)
                .disabled(exportRunning)
            Spacer()
        }
    }

    @ViewBuilder
    private var exportSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button {
                    Task { await exportLibrary() }
                } label: {
                    Label(exportRunning ? "Exporting…" : "Export Library",
                          systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canExport || exportRunning)
            }

            if !canExport {
                Text("Grant music library access and select a workspace directory to enable export.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if exportRunning && exportProgress.status.totalTracks > 0 {
                ProgressView(value: Double(exportProgress.status.processedTracks),
                             total: Double(exportProgress.status.totalTracks)) {
                    Text("Exporting tracks…")
                } currentValueLabel: {
                    Text("\(exportProgress.status.processedTracks) / \(exportProgress.status.totalTracks)")
                        .monospacedDigit()
                }
            }

            if let msg = exportMsg {
                Text(msg)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: 8))
            }

            if let error = exportError {
                StatusRow(systemImage: "xmark.octagon.fill",
                          tint: .red,
                          text: error)
            }
        }
    }
}

/// A titled container that groups related controls into a bordered card.
private struct ExportCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

/// An icon + message row used for status lines inside cards.
private struct StatusRow: View {
    let systemImage: String
    let tint: Color
    let text: String
    var monospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
