import Foundation

/// startup retries replace missing services without retaining a failed optional for the process lifetime.
@MainActor
final class PhoneWatchLibraryServices {
    private let settings: WatchSyncSettingsStore
    private let makeContent: (Bool) throws -> PhoneWatchContentQueue
    private let makePublisher: (Bool) throws -> PhoneWatchLibraryPublisher
    private(set) var content: PhoneWatchContentQueue?
    private(set) var publisher: PhoneWatchLibraryPublisher?
    private var identity: String?
    var onContentChanged: () -> Void = {}

    init(settings: WatchSyncSettingsStore, makeContent: @escaping (Bool) throws -> PhoneWatchContentQueue,
         makePublisher: @escaping (Bool) throws -> PhoneWatchLibraryPublisher) {
        self.settings = settings
        self.makeContent = makeContent
        self.makePublisher = makePublisher
        settings.onRetryDelivery = { [weak self] in self?.retry() }
        start(repairsDamage: false)
    }

    private func start(repairsDamage: Bool) {
        var failures = [String]()
        if content == nil {
            do {
                content = try makeContent(repairsDamage)
                settings.content = content
                if content?.recoveredState == true { settings.deliveryRecovered = true }
                onContentChanged()
            } catch { failures.append(error.localizedDescription) }
        }
        if publisher == nil {
            do {
                publisher = try makePublisher(repairsDamage)
                if publisher?.recoveredState == true { settings.deliveryRecovered = true }
                publisher?.onSnapshot = { [weak self] head, snapshot in self?.content?.update(head: head, snapshot: snapshot) }
                publisher?.onSelectionReconciled = { [weak settings] in settings?.reconcilePlaylistIds($0) }
            } catch { failures.append(error.localizedDescription) }
        }
        settings.deliveryStartupError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func publish(identity: String?, libraryRequest: WatchLibraryRequest? = nil) {
        self.identity = identity
        start(repairsDamage: false)
        publish(libraryRequest: libraryRequest)
    }

    func retry() {
        start(repairsDamage: true)
        publish()
    }

    func metadataFinished(key: String, error: Error?) {
        do {
            try publisher?.finished(key: key, error: error)
        } catch { settings.deliveryStartupError = error.localizedDescription }
    }

    private func publish(libraryRequest: WatchLibraryRequest? = nil) {
        guard settings.deliveryStartupError == nil else { return }
        do {
            try content?.invalidate(identity: identity, playlistIDs: settings.playlistIds)
            publisher?.publish(identity: identity, playlistIDs: settings.playlistIds, libraryRequest: libraryRequest)
        } catch {
            settings.deliveryStartupError = error.localizedDescription
        }
    }

    func waitForPublication() async { await publisher?.waitForPublication() }
}
