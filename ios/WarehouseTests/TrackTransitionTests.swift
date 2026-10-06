import AVFoundation
import MediaToolbox
import Testing
@testable import Warehouse

@Suite("downloaded track transitions", .serialized)
struct TrackTransitionTests {
    private final class AudioProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var starts: [Double] = []

        func append(_ time: Double) {
            lock.lock()
            defer { lock.unlock() }
            starts.append(time)
        }

        var times: [Double] {
            lock.lock()
            defer { lock.unlock() }
            return starts
        }

        func attach(to item: AVPlayerItem) async throws {
            let track = try #require(try await item.asset.loadTracks(withMediaType: .audio).first)
            var callbacks = MTAudioProcessingTapCallbacks(
                version: kMTAudioProcessingTapCallbacksVersion_0,
                clientInfo: Unmanaged.passUnretained(self).toOpaque(),
                init: { _, info, storage in
                    storage.pointee = Unmanaged<AudioProbe>.fromOpaque(info!).retain().toOpaque()
                },
                finalize: { tap in
                    Unmanaged<AudioProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
                }, prepare: nil, unprepare: nil,
                process: { tap, frames, _, buffers, framesOut, flagsOut in
                    var range = CMTimeRange.invalid
                    let result = MTAudioProcessingTapGetSourceAudio(
                        tap, frames, buffers, flagsOut, &range, framesOut)
                    if result == noErr, framesOut.pointee > 0 {
                        let probe = Unmanaged<AudioProbe>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                        probe.append(range.start.seconds)
                    }
                })
            var tap: MTAudioProcessingTap?
            let result = MTAudioProcessingTapCreate(
                kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
            try #require(result == noErr)
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = try #require(tap)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    @Test("downloaded transitions decode audio from the custom start", arguments: [0.0, 5.0, 60.0], [false, true])
    @MainActor
    func customStart(start: Double, skip: Bool) async throws {
        try await checkTransition(start: start, skip: skip)
    }

    @Test("editing a queued start prepares the new in point", arguments: [0.0, 5.0], [false, true])
    @MainActor
    func editedStart(start: Double, skip: Bool) async throws {
        try await checkTransition(start: 60, skip: skip, editedStart: start)
    }

    @MainActor
    private func checkTransition(start: Double, skip: Bool, editedStart: Double? = nil) async throws {
        let store = FileCacheTests.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try PlayerQueueTests.cacheSongs(store, ["1", "2"])
        var transport: AVQueuePlayer?
        let player = PlayerStore(
            fileStore: store, musicPolicy: .downloadedOnly,
            activateSessionForTests: { true },
            observePlayback: { queue, item, receive in
                transport = queue
                return PlaybackObservation.start(player: queue, item: item, receive: receive)
            }, diagnostics: WatchDiagnostics(logEvents: false))
        defer { player.pause() }
        let probe = AudioProbe()
        let finish = (editedStart ?? start) + 10
        player.play([PlayerStoreTests.edited(id: "1", finish: skip ? 30 : 2),
                     PlayerStoreTests.edited(id: "2", start: start, finish: start + 10)],
                    token: nil, baseURL: nil)
        try await PlayerStoreTests.waitFor { player.nextItemURL != nil }
        if let editedStart {
            player.trackUpdated(PlayerStoreTests.edited(id: "2", start: editedStart, finish: finish))
        }
        let start = editedStart ?? start
        let next = try #require(transport?.items().last)
        #expect(next !== transport?.currentItem)
        #expect(next.forwardPlaybackEndTime.seconds == finish)
        try await probe.attach(to: next)
        if skip { player.skipToNext() }
        try await PlayerStoreTests.waitFor { player.song?.id == "2" && probe.times.contains { $0 > start + 0.1 } }
        let times = probe.times.filter(\.isFinite)
        // the tap includes decoder preroll before the in point, up to 140 ms
        // for this fixture. it must not decode from the beginning of the file.
        #expect(times.allSatisfy { $0 >= start - 0.2 }, "unexpected decoded buffer starts: \(times)")
        #expect(player.advancedOntoEnqueuedItem)
        #expect(player.isPlaying)
        #expect(next.currentTime().seconds >= start)
        #expect(player.currentItemURL == store.fileURL(.music, "2.wav"))
        #expect(next.forwardPlaybackEndTime.seconds == finish)
    }
}
