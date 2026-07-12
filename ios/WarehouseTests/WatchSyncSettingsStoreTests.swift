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
        store.setServerURLOverride("funnel.example.com:8443")

        let reloaded = WatchSyncSettingsStore(defaults: defaults)
        #expect(reloaded.playlistIds == ["p1", "p2"])
        #expect(reloaded.serverURLOverride == "funnel.example.com:8443")
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

        store.setServerURLOverride("funnel.example.com:8443")
        #expect(changes == 4)

        // setting the same value again shouldn't ping the watch
        store.setServerURLOverride("funnel.example.com:8443")
        #expect(changes == 4)
    }

    @Test("the override wins over the phone's server url when set")
    func effectiveServerURL() {
        let store = WatchSyncSettingsStore(defaults: Self.makeDefaults("effective"))
        #expect(store.effectiveServerURL(phoneServerURL: "phone.example.com") == "phone.example.com")

        store.setServerURLOverride("   ")
        #expect(store.effectiveServerURL(phoneServerURL: "phone.example.com") == "phone.example.com")

        store.setServerURLOverride(" https://funnel.example.com:8443 ")
        #expect(store.effectiveServerURL(phoneServerURL: "phone.example.com")
            == "https://funnel.example.com:8443")
    }
}
