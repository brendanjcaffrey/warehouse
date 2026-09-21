import Foundation

/// small library-wide values that live alongside the core data store,
/// mirroring the web app's localStorage metadata
struct LibraryMetadata {
    private let defaults: UserDefaults

    private static let updateTimeNsKey = "libraryUpdateTimeNs"
    private static let totalFileSizeKey = "libraryTotalFileSize"
    private static let trackUserChangesKey = "libraryTrackUserChanges"
    private static let hasSavedLibraryKey = "libraryHasSavedLibrary"

    // the parameter is here for tests
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// the server's export timestamp from the last successful sync, 0 if never synced
    var updateTimeNs: Int64 {
        get { (defaults.object(forKey: Self.updateTimeNsKey) as? NSNumber)?.int64Value ?? 0 }
        nonmutating set {
            // preserve saved-library evidence from versions before the separate flag
            if updateTimeNs != 0 {
                defaults.set(true, forKey: Self.hasSavedLibraryKey)
            }
            defaults.set(NSNumber(value: newValue), forKey: Self.updateTimeNsKey)
        }
    }

    var totalFileSize: UInt64 {
        get { (defaults.object(forKey: Self.totalFileSizeKey) as? NSNumber)?.uint64Value ?? 0 }
        nonmutating set { defaults.set(NSNumber(value: newValue), forKey: Self.totalFileSizeKey) }
    }

    /// unlike the refresh watermark, this survives playlist selection changes
    var hasSavedLibrary: Bool {
        defaults.bool(forKey: Self.hasSavedLibraryKey) || updateTimeNs != 0
    }

    var trackUserChanges: Bool {
        get { defaults.bool(forKey: Self.trackUserChangesKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.trackUserChangesKey) }
    }

    func update(from library: Library) {
        defaults.set(true, forKey: Self.hasSavedLibraryKey)
        updateTimeNs = library.updateTimeNs
        totalFileSize = library.totalFileSize
        trackUserChanges = library.trackUserChanges
    }

    func clear() {
        defaults.removeObject(forKey: Self.hasSavedLibraryKey)
        defaults.removeObject(forKey: Self.updateTimeNsKey)
        defaults.removeObject(forKey: Self.totalFileSizeKey)
        defaults.removeObject(forKey: Self.trackUserChangesKey)
    }
}
