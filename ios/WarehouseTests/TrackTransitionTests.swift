import AVFoundation
import MediaToolbox
import Testing
@testable import Warehouse

@Suite("downloaded track transitions", .serialized)
struct TrackTransitionTests {
    private final class BundleMarker: NSObject {}

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

    @Test("file-end transitions keep decoded audio moving forward", arguments: [0.0, 5.0, 60.0], [false, true])
    @MainActor
    func fileEnd(start: Double, skip: Bool) async throws {
        try await checkTransition(start: start, skip: skip, fileEnd: true)
    }

    @Test("compressed file-end transitions start without repeated audio", arguments: [0.0, 5.0, 60.0], [false, true])
    @MainActor
    func compressedFileEnd(start: Double, skip: Bool) async throws {
        try await checkTransition(start: start, skip: skip, fileEnd: true, compressed: true)
    }

    @Test("custom-start file-end transitions survive delayed app reconciliation", arguments: [0.0, 5.0, 60.0], [false, true])
    @MainActor
    func delayedFileEnd(start: Double, delayed: Bool) async throws {
        try await checkTransition(start: start, skip: false, fileEnd: true, compressed: true,
                                  firstStart: 70, delayed: delayed)
    }

    @Test("automatic transitions do not replay audio when the app catches up")
    @MainActor
    func lateAppReconciliation() async throws {
        try await checkTransition(start: 5, skip: false, fileEnd: true, delayed: true)
    }

    private func delayReconciliation() {
        Thread.sleep(forTimeInterval: 2)
    }

    @MainActor
    private func checkTransition(start: Double, skip: Bool, editedStart: Double? = nil,
                                 fileEnd: Bool = false, compressed: Bool = false,
                                 firstStart: Double = 0, delayed: Bool = false) async throws {
        let store = FileCacheTests.makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootURL) }
        try PlayerQueueTests.cacheSongs(store, ["1", "2"])
        if fileEnd {
            try store.write(.music, "1.wav", data: PlayerStoreTests.wav(seconds: 2))
        }
        let filename = compressed ? "2.mp3" : "2.wav"
        let firstFilename = firstStart > 0 ? "1.mp3" : "1.wav"
        if compressed {
            // synthetic 72-second stereo tone, encoded with ffmpeg's libmp3lame.
            let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "transition-tone", withExtension: "mp3"))
            let data = try Data(contentsOf: url)
            try store.write(.music, filename, data: data)
            if firstStart > 0 { try store.write(.music, firstFilename, data: data) }
        }
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
        player.play([PlayerStoreTests.edited(id: "1", start: firstStart,
                                            finish: fileEnd ? 0 : (skip ? 30 : 2),
                                            duration: fileEnd ? firstStart + 2 : 240, musicFilename: firstFilename),
                     PlayerStoreTests.edited(id: "2", start: start, finish: start + 10,
                                            duration: compressed ? 72 : 240, musicFilename: filename)],
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
        if delayed {
            try await PlayerStoreTests.waitFor { player.currentTime >= firstStart + 1 }
            // hold app callbacks across the file end while the daemon keeps playing.
            delayReconciliation()
        }
        try await PlayerStoreTests.waitFor { player.song?.id == "2" && probe.times.contains { $0 > start + (delayed ? 2 : 1) } }
        let times = probe.times.filter(\.isFinite)
        // the tap includes decoder preroll before the in point, up to 140 ms
        // for this fixture. it must not decode from the beginning of the file.
        #expect(times.allSatisfy { $0 >= start - 0.2 }, "unexpected decoded buffer starts: \(times)")
        let playback = times.filter { $0 >= start + 0.05 }
        #expect(zip(playback, playback.dropFirst()).allSatisfy { $1 > $0 }, "decoded audio repeated: \(times)")
        #expect(player.advancedOntoEnqueuedItem)
        #expect(player.isPlaying)
        #expect(next.currentTime().seconds >= start)
        #expect(player.currentItemURL == store.fileURL(.music, filename))
        #expect(next.forwardPlaybackEndTime.seconds == finish)
    }
}
