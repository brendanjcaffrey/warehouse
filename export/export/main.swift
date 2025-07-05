import Cocoa
import SwiftUI

let args = AppArguments(arguments: CommandLine.arguments)

func printToStderr(_ string: String) {
    FileHandle.standardError.write(string.data(using: .utf8)!)
    if string.last != "\n" {
        FileHandle.standardError.write("\n".data(using: .utf8)!)
    }
}

if args.headless {
    // suppress dock and menu bar
    NSApplication.shared.setActivationPolicy(.prohibited)

    let workspaceDirURL = FileSystem.tryGetPersisted(key: WORKSPACE_DIR_KEY)
    guard let workspaceDirURL = workspaceDirURL else {
        print("Workspace dir not found!")
        exit(1)
    }

    let exportLogURL = workspaceDirURL.appendingPathComponent("export.log")
    if freopen(exportLogURL.relativePath, "a+", stderr) == nil {
        print("Unable to redirect stderr to \(exportLogURL.relativePath)!")
        exit(1)
    }
    printToStderr("Logging to \(exportLogURL.absoluteString)")
    printToStderr("Fast mode: \(args.fast)")

    let configFileURL = workspaceDirURL.appendingPathComponent(CONFIG_FILE_NAME)
    printToStderr("Config file: \(configFileURL)")

    let music = Config.checkMusicPath(workspaceDirURL: workspaceDirURL, configFileURL: configFileURL)
    if !music.success {
        printToStderr("Error with music directory: \(music.errorMsg!)")
        exit(1)
    }

    let artwork = Config.checkArtworkPath(workspaceDirURL: workspaceDirURL, configFileURL: configFileURL)
    if !artwork.success {
        printToStderr("Error with artwork directory: \(artwork.errorMsg!)")
        exit(1)
    }

    let musicDirURL = workspaceDirURL.appendingPathComponent(music.subpath!)
    printToStderr("Music dir: \(musicDirURL)")
    let artworkDirURL = workspaceDirURL.appendingPathComponent(artwork.subpath!)
    printToStderr("Artwork dir: \(artworkDirURL)")

    let status = MusicAuth.getStatus()
    if !status.authorized {
        printToStderr("Failed to export: music access not authorized!")
        exit(1)
    }

    let pgConfig = try Config.getDatabaseConfig(configFileURL: configFileURL)
    let library = Library(pgConfig: pgConfig!, musicDirURL: musicDirURL, artworkDirURL: artworkDirURL)

    let exportProgress = ExportProgressModel()
    let progressReporter = Task {
        while !Task.isCancelled {
            if exportProgress.status.totalTracks > 0 {
                printToStderr("tracks processed: \(exportProgress.status.processedTracks)/\(exportProgress.status.totalTracks)")
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        }
    }

    let error = try await library.export(progress: exportProgress, fast: args.fast)
    progressReporter.cancel()
    if error != nil {
        printToStderr("Failed to export: export failed with \(error!)")
        exit(1)
    }

    printToStderr("Export finished successfully")
    printToStderr(exportProgress.status.toString())
} else {
    NSApplication.shared.setActivationPolicy(.regular)
    _ = NSApplication.shared
    ExportApp.main()
}
