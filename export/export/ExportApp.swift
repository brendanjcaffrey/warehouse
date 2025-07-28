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

    var body: some Scene {
        WindowGroup {
            Spacer()

            if authStatus.authorized {
                Text("music library access authorized 🥳")
            } else {
                Text("music library authorization error: \(authStatus.error ?? "unknown")").foregroundStyle(.red)
                Button("request authorization", action: { Task { await requestAuth() } })
                Button("open system settings", action: MusicAuth.openSettings)
            }
            Button("refresh music library authorization status", action: checkAuth)

            Spacer()

            if let url = workspaceDirURL {
                Text("workspace is \(url.path)")
            }
            Button("update workspace dir", action: getWorkspaceDir).disabled(exportRunning)

            Spacer()

            Toggle(isOn: $fastExport) {
                Text("fast export (this will assume track music file and artwork file md5s have not changed)")
            }

            Spacer()

            if authStatus.authorized && workspaceDirURL != nil {
                Button("export library", action: { Task { await exportLibrary() } }).disabled(exportRunning)
            } else {
                Text("cannot export until music library access is granted and a workspace directory is selected")
            }
            if exportRunning {
                if exportProgress.status.totalTracks > 0 {
                    ProgressView(value: Double(exportProgress.status.processedTracks),
                                 total: Double(exportProgress.status.totalTracks),
                                 label: { Text("\(exportProgress.status.processedTracks)/\(exportProgress.status.totalTracks) tracks exported...") })
                    .frame(width: 300, height: 25)
                }
            }
            if let msg = exportMsg {
                Text(msg)
            }
            if let error = exportError {
                Text(error).foregroundStyle(.red)
            }

            Spacer()
        }
    }
}
