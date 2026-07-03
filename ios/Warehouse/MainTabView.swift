import SwiftUI

struct MainTabView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncStore.self) private var sync

    var body: some View {
        TabView {
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .task {
            // only check whether there's anything to sync, downloading starts manually
            await sync.checkForUpdates(token: auth.token, baseURL: auth.baseURL())
        }
    }
}
