import Foundation

/// watch-side bookkeeping for one relayed bulk download: which files have
/// arrived, which the phone reported as unfetchable, and what's still worth
/// asking for again
@MainActor
final class RelayDownloadTracker {
    private let files: [FileToDownload]
    private let targets: Set<FileToDownload>
    private var arrived: Set<FileToDownload>
    private var failed: Set<FileToDownload> = []
    private(set) var outOfSpace = false

    init(files: [FileToDownload], isOnDisk: (FileToDownload) -> Bool) {
        self.files = files
        targets = Set(files)
        // arrivals delivered while no sync was running already count
        arrived = Set(files.filter(isOnDisk))
    }

    func fileArrived(_ file: FileToDownload) {
        guard targets.contains(file) else { return }
        arrived.insert(file)
        // it made it over after all; forget any earlier failure report
        failed.remove(file)
    }

    func filesFailed(_ files: [FileToDownload]) {
        for file in files where targets.contains(file) && !arrived.contains(file) {
            failed.insert(file)
        }
    }

    func markOutOfSpace() {
        outOfSpace = true
    }

    /// what the next request to the phone should ask for
    var missing: [FileToDownload] {
        files.filter { !arrived.contains($0) && !failed.contains($0) }
    }

    var isComplete: Bool {
        outOfSpace || arrived.count + failed.count >= targets.count
    }

    func progress() -> DownloadProgress {
        var progress = DownloadProgress(files: files)
        for file in arrived {
            progress[file.type].completed += 1
        }
        for file in failed {
            progress[file.type].failed += 1
        }
        if outOfSpace {
            progress.outOfSpace = true
            // whatever never resolved would only fail the same way
            for file in missing {
                progress[file.type].failed += 1
            }
        }
        return progress
    }
}
