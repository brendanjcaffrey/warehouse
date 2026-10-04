import SwiftUI
import WatchKit
import WatchConnectivity

@main
struct WarehouseWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchBackgroundDelegate.self) private var backgroundDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let services: WatchLibraryServices
    private let phone: WatchPhoneSession
    private let plays: PlayReportQueue
    @State private var remote: WatchRemoteStore

    init() {
        Keychain.setToken(nil)
        let database = LibraryDatabase()
        let fileStore = FileStore(rootURL: FileStore.defaultRootURL())
        var session: WatchPhoneSession?
        var reports: PlayReportQueue?
        services = WatchLibraryServices(database: database, fileStore: fileStore, sendReceipt: { receipt in
            guard session?.canSend == true, let info = try? receipt.encode() else { return }
            let alreadyQueued = WCSession.default.outstandingUserInfoTransfers.contains {
                WatchContentReceipt(dictionary: $0.userInfo) == receipt
            }
            if !alreadyQueued { WCSession.default.transferUserInfo(info) }
        }, onTrackPlayed: { reports?.add($0) })
        let phone = WatchPhoneSession(library: services.receiver)
        session = phone
        phone.content = services.content
        services.requestLibrary = { phone.requestLibrary() }
        services.onContentChanged = { [weak services, weak phone] in
            guard let services else { return }
            phone?.content = services.content
            services.content?.sendInventory = { report in
                guard phone?.canSend == true, let info = try? report.encode() else { return false }
                let alreadyQueued = WCSession.default.outstandingUserInfoTransfers.contains {
                    WatchInventoryReport(dictionary: $0.userInfo) == report
                }
                if !alreadyQueued { WCSession.default.transferUserInfo(info) }
                return true
            }
        }
        services.onContentChanged()
        let plays = PlayReportQueue(canSend: { phone.canSend }, outstandingIds: { phone.outstandingPlayIds }, send: { phone.send($0) })
        reports = plays
        phone.onActivated = { plays.drain() }
        phone.onPlayReceipt = { plays.acknowledge($0) }
        phone.onPlayTransferFinished = { plays.finished($0) }
        let remote = WatchRemoteStore(send: { phone.send($0) })
        phone.remote = remote
        _remote = State(initialValue: remote)
        self.phone = phone
        self.plays = plays
        WatchBackgroundDelegate.phone = phone
        // background delivery initializes before a scene is needed.
        phone.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(services.library)
                .environment(services.receiver)
                .environment(services.songs)
                .environment(services.playlists)
                .environment(services.player)
                .environment(remote)
                .environment(\.artworkFetcher, services.artwork)
                .environment(\.diagnosticSender, phone)
                .environment(\.watchLibraryRefresh, { await services.refresh() })
                .task { await services.launch() }
                .onChange(of: scenePhase, initial: true) {
                    if scenePhase == .active {
                        Task { await services.refresh() }
                        plays.drain()
                        remote.requestState()
                    }
                }
        }
    }
}

@MainActor
final class WatchBackgroundDelegate: NSObject, WKApplicationDelegate {
    static var phone: WatchPhoneSession?

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            guard let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask, let phone = Self.phone else {
                task.setTaskCompletedWithSnapshot(false)
                continue
            }
            phone.library.resume()
            phone.content?.resume()
            phone.updateBackgroundLifetime()
            phone.lifetime.hold { connectivity.setTaskCompletedWithSnapshot(false) }
        }
    }
}
