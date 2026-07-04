import SwiftUI

struct MainTabView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncStore.self) private var sync

    var body: some View {
        TabView {
            Tab("Library", systemImage: "music.note.list") {
                LibraryView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
            Tab(role: .search) {
                SearchView()
            }
        }
        .task {
            // only check whether there's anything to sync, downloading starts manually
            await sync.checkForUpdates(token: auth.token, baseURL: auth.baseURL())
        }
    }
}
