import Foundation
import Testing
@testable import Warehouse

@Suite("WatchSettingsStore")
@MainActor
struct WatchSettingsStoreTests {
    final class TokenBox {
        var token: String?
    }

    static func makeStore(_ name: String) -> (store: WatchSettingsStore, defaults: UserDefaults, tokens: TokenBox) {
        let suiteName = "WatchSettingsStoreTests-\(name)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let tokens = TokenBox()
        let store = WatchSettingsStore(
            defaults: defaults,
            readToken: { tokens.token },
            writeToken: { tokens.token = $0 })
        return (store, defaults, tokens)
    }

    @Test("applying a payload stores everything and configures the store")
    func applyStoresEverything() {
        let (store, _, tokens) = Self.makeStore("apply")
        #expect(!store.isConfigured)

        store.apply(WatchPayload(serverURL: "example.com", token: "tok", playlistIds: ["p1"]))

        #expect(store.isConfigured)
        #expect(store.serverURL == "example.com")
        #expect(store.token == "tok")
        #expect(store.playlistIds == ["p1"])
        #expect(tokens.token == "tok")
        #expect(store.baseURL() == URL(string: "https://example.com"))
    }

    @Test("settings persist across instances")
    func settingsPersist() {
        let (store, defaults, tokens) = Self.makeStore("persist")
        store.apply(WatchPayload(serverURL: "example.com", token: "tok", playlistIds: ["p1", "p2"]))

        let reloaded = WatchSettingsStore(
            defaults: defaults,
            readToken: { tokens.token },
            writeToken: { tokens.token = $0 })
        #expect(reloaded.isConfigured)
        #expect(reloaded.serverURL == "example.com")
        #expect(reloaded.token == "tok")
        #expect(reloaded.playlistIds == ["p1", "p2"])
    }

    @Test("a selection change resets the sync watermark and bumps the counter")
    func selectionChangeForcesResync() {
        let (store, defaults, _) = Self.makeStore("selection")
        let metadata = LibraryMetadata(defaults: defaults)

        store.apply(WatchPayload(serverURL: "example.com", token: "tok", playlistIds: ["p1"]))
        #expect(store.selectionChanges == 1)

        // as if a sync already ran
        metadata.updateTimeNs = 43

        // same selection: nothing forced
        store.apply(WatchPayload(serverURL: "example.com", token: "tok2", playlistIds: ["p1"]))
        #expect(store.selectionChanges == 1)
        #expect(metadata.updateTimeNs == 43)

        // new selection: refetch forced
        store.apply(WatchPayload(serverURL: "example.com", token: "tok2", playlistIds: ["p1", "p2"]))
        #expect(store.selectionChanges == 2)
        #expect(metadata.updateTimeNs == 0)
    }

    @Test("an empty token logs the watch out")
    func emptyTokenLogsOut() {
        let (store, _, tokens) = Self.makeStore("logout")
        store.apply(WatchPayload(serverURL: "example.com", token: "tok", playlistIds: ["p1"]))

        store.apply(WatchPayload(serverURL: "example.com", token: "", playlistIds: ["p1"]))
        #expect(store.token == nil)
        #expect(tokens.token == nil)
        #expect(!store.isConfigured)
    }

    @Test("baseURL normalizes like the phone")
    func baseURLNormalizes() {
        let (store, _, _) = Self.makeStore("baseurl")
        #expect(store.baseURL() == nil)

        store.apply(WatchPayload(serverURL: " music.example.com ", token: "tok", playlistIds: ["p1"]))
        #expect(store.baseURL() == URL(string: "https://music.example.com"))

        store.apply(WatchPayload(serverURL: "http://local.test", token: "tok", playlistIds: ["p1"]))
        #expect(store.baseURL() == URL(string: "http://local.test"))
    }
}
