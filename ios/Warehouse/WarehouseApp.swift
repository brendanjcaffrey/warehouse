import SwiftUI

@main
struct WarehouseApp: App {
    @State private var auth = AuthStore()
    @State private var sync = SyncStore(
        database: LibraryDatabase(),
        fileStore: FileStore(rootURL: FileStore.defaultRootURL()))

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .environment(sync)
        }
    }
}
