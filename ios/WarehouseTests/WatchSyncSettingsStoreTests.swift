import Foundation
import Testing
@testable import Warehouse

@Suite("WatchSyncSettingsStore")
@MainActor
struct WatchSyncSettingsStoreTests {
    static func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "WatchSyncSettingsStoreTests-\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("toggling selects and deselects playlists")
    func togglingSelectsAndDeselects() {
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("toggle"))

        #expect(!store.isSelected("p1"))
        store.toggle("p1")
        store.toggle("p2")
        #expect(store.isSelected("p1"))
        #expect(store.playlistIds == ["p1", "p2"])

        store.toggle("p1")
        #expect(!store.isSelected("p1"))
        #expect(store.playlistIds == ["p2"])
    }

    @Test("the settings persist across instances")
    func settingsPersist() {
        let defaults = Self.makeDefaults("persist")
        let store = WatchSyncSettingsStore(defaults: defaults)
        store.toggle("p1")
        store.toggle("p2")

        let reloaded = WatchSyncSettingsStore(defaults: defaults)
        #expect(reloaded.playlistIds == ["p1", "p2"])
    }

    @Test("onChange fires after every change")
    func onChangeFires() {
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("onchange"))
        var changes = 0
        store.onChange = { changes += 1 }

        store.toggle("p1")
        store.toggle("p2")
        store.toggle("p1")
        #expect(changes == 3)
    }
}
