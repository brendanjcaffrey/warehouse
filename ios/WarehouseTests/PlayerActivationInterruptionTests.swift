import AVFoundation
import Foundation
import Testing
@testable import Warehouse

extension PlayerStoreTests {
    @MainActor
    final class PendingActivation {
        private var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
        private(set) var calls = 0
        private(set) var completed: Set<Int> = []
        private(set) var loadedURLs: [URL] = []
        private(set) var transport: AVQueuePlayer?

        func activate() async -> Bool {
            calls += 1
            let call = calls
            let result = await withCheckedContinuation { pending[call] = $0 }
            completed.insert(call)
            return result
        }

        func finish(_ call: Int, success: Bool = true) {
            pending.removeValue(forKey: call)?.resume(returning: success)
        }

        func cancel() {
            let continuations = Array(pending.values)
            pending.removeAll()
            continuations.forEach { $0.resume(returning: false) }
        }

        func observe(_ player: AVQueuePlayer, _ item: AVPlayerItem, _ receive: @escaping PlaybackObservation.Handler) -> () -> Void {
            transport = player
            if let url = (item.asset as? AVURLAsset)?.url { loadedURLs.append(url) }
            return PlaybackObservation.start(player: player, item: item, receive: receive)
        }
    }

    @MainActor
    static func activationPlayer() throws -> (PlayerStore, FileStore, PendingActivation) {
        let files = FileCacheTests.makeStore()
        for song in songs(2) { try files.write(.music, song.musicFilename, data: musicBytes) }
        let activation = PendingActivation()
        let player = PlayerStore(fileStore: files, musicPolicy: .downloadedOnly,
                                 activateSessionForTests: { await activation.activate() },
                                 observePlayback: activation.observe)
        return (player, files, activation)
    }

    @Test("bluetooth activation interruptions preserve downloaded and restored starts", arguments: [false, true])
    @MainActor
    func downloadedActivationKeepsIntent(restored: Bool) async throws {
        let (player, files, activation) = try Self.activationPlayer()
        defer { player.pause(); activation.cancel(); try? FileManager.default.removeItem(at: files.rootURL) }
        let song = Self.song(id: "1")
        if restored {
            let snapshot = PlaybackSnapshot(queue: PlayQueue(songs: [song]).snapshot, repeatMode: .off, currentTime: 60)
            player.restore(snapshot, songs: [song.id: song], token: nil, baseURL: nil)
            #expect(!player.isPlaying)
            #expect(activation.calls == 0)
            player.resume()
        } else {
            player.play([song], token: nil, baseURL: nil)
        }
        try await Self.waitFor { activation.calls == 1 }
        #expect(player.status == .ready)
        #expect(!player.hasLoadedTrack)
        for _ in 0..<2 { player.handleInterruption(Self.interruption(.began)) }
        #expect(player.isPlaying)
        player.handleInterruption(Self.interruption(.ended, options: .shouldResume))
        activation.finish(1)
        try await Self.waitFor { player.hasLoadedTrack }
        #expect(player.isPlaying)
        #expect(player.currentTime >= (restored ? 60 : 0))
        #expect(activation.calls == 1)
        #expect(activation.loadedURLs == [files.fileURL(.music, song.musicFilename)])
        try await Self.waitFor { player.isActuallyPlaying }
        #expect(activation.transport?.rate == 1)

        // once the pending start is consumed, genuine interruptions still pause.
        player.handleInterruption(Self.interruption(.began))
        #expect(!player.isPlaying)
        #expect(activation.transport?.rate == 0)
        player.handleInterruption(Self.interruption(.ended))
        #expect(!player.isPlaying)
    }

    @Test("user pause during downloaded activation remains authoritative", arguments: [false, true], [false, true])
    @MainActor
    func pausedDownloadedActivation(resumeBeforeCompletion: Bool, interruptionEndsFirst: Bool) async throws {
        let (player, files, activation) = try Self.activationPlayer()
        defer { player.pause(); activation.cancel(); try? FileManager.default.removeItem(at: files.rootURL) }
        player.play([Self.song(id: "1")], token: nil, baseURL: nil)
        try await Self.waitFor { activation.calls == 1 }
        player.handleInterruption(Self.interruption(.began))
        player.pause()
        player.handleInterruption(Self.interruption(.began))
        #expect(!player.isPlaying)
        if resumeBeforeCompletion { player.resume() }
        if interruptionEndsFirst {
            player.handleInterruption(Self.interruption(.ended, options: .shouldResume))
            #expect(player.isPlaying == resumeBeforeCompletion)
        }
        activation.finish(1)
        try await Self.waitFor { player.hasLoadedTrack }
        if !interruptionEndsFirst { player.handleInterruption(Self.interruption(.ended, options: .shouldResume)) }
        #expect(player.isPlaying == resumeBeforeCompletion)
        #expect(activation.calls == 1)
        #expect(activation.loadedURLs == [files.fileURL(.music, "1.wav")])
        if resumeBeforeCompletion {
            try await Self.waitFor { player.isActuallyPlaying }
        } else {
            #expect(activation.transport?.rate == 0)
        }
    }

    @Test("failed downloaded activation clears intent and can retry after an interruption")
    @MainActor
    func failedDownloadedActivation() async throws {
        let (player, files, activation) = try Self.activationPlayer()
        defer { player.pause(); activation.cancel(); try? FileManager.default.removeItem(at: files.rootURL) }
        player.play([Self.song(id: "1")], token: nil, baseURL: nil)
        try await Self.waitFor { activation.calls == 1 }
        player.handleInterruption(Self.interruption(.began))
        activation.finish(1, success: false)
        try await Self.waitFor { player.status == .needsOutput }
        #expect(!player.isPlaying)
        #expect(!player.hasLoadedTrack)
        #expect(player.pendingStartTime == nil)
        #expect(activation.loadedURLs.isEmpty)
        player.resume()
        try await Self.waitFor { activation.calls == 2 }
        player.handleInterruption(Self.interruption(.began))
        activation.finish(2)
        try await Self.waitFor { player.isActuallyPlaying }
        #expect(activation.loadedURLs == [files.fileURL(.music, "1.wav")])
    }

    @Test("skips fence old activation success and failure", arguments: [false, true], [false, true])
    @MainActor
    func skippedDownloadedActivation(oldSucceeds: Bool, oldFinishesFirst: Bool) async throws {
        let (player, files, activation) = try Self.activationPlayer()
        defer { player.pause(); activation.cancel(); try? FileManager.default.removeItem(at: files.rootURL) }
        player.play(Self.songs(2), token: nil, baseURL: nil)
        try await Self.waitFor { activation.calls == 1 }
        player.handleInterruption(Self.interruption(.began))
        player.skipToNext()
        try await Self.waitFor { activation.calls == 2 }
        player.handleInterruption(Self.interruption(.began))
        if oldFinishesFirst {
            activation.finish(1, success: oldSucceeds)
            try await Self.waitFor { activation.completed.contains(1) }
            #expect(!player.hasLoadedTrack)
            #expect(player.isPlaying)
        }
        activation.finish(2)
        try await Self.waitFor { player.isActuallyPlaying }
        if !oldFinishesFirst {
            activation.finish(1, success: oldSucceeds)
            try await Self.waitFor { activation.completed.contains(1) }
        }
        #expect(player.song?.id == "2")
        #expect(player.isPlaying)
        #expect(player.status == .ready)
        #expect(activation.loadedURLs == [files.fileURL(.music, "2.wav")])
        #expect(activation.calls == 2)
    }
}
