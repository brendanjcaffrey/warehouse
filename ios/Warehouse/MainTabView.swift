import SwiftUI

struct MainTabView: View {
    private enum TabId {
        case library
        case settings
        case search
    }

    @Environment(AuthStore.self) private var auth
    @Environment(SyncStore.self) private var sync
    @Environment(PlayerStore.self) private var player

    @State private var selectedTab = TabId.library
    @State private var showingNowPlaying = false

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Library", systemImage: "music.note.list", value: TabId.library) {
                LibraryView()
            }
            Tab("Settings", systemImage: "gearshape", value: TabId.settings) {
                SettingsView()
            }
            Tab(value: TabId.search, role: .search) {
                SearchView()
            }
        }
        // isEnabled keeps the tab view's identity stable when the bar appears,
        // so it doesn't reset navigation state the way conditionally attaching
        // the accessory would
        .tabViewBottomAccessory(isEnabled: player.song != nil) {
            NowPlayingBar(showingNowPlaying: $showingNowPlaying)
        }
        .sheet(isPresented: $showingNowPlaying) {
            NowPlayingView()
        }
        .task {
            // only check whether there's anything to sync, downloading starts manually
            await sync.checkForUpdates(token: auth.token, baseURL: auth.baseURL())
        }
    }
}
