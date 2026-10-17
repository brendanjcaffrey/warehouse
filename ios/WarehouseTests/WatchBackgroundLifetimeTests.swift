import Foundation
import Testing
@testable import Warehouse

@Suite("watch background settling", .serialized)
@MainActor
struct WatchBackgroundLifetimeTests {
    @Test("idle tasks settle once and a later wake gets its own window")
    func idleCompletion() async throws {
        let clock = Clock()
        defer { clock.releaseAll() }
        let lifetime = clock.lifetime()
        var completed = 0
        var batches = [Int]()
        lifetime.onCompleted = { batches.append($0) }
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        #expect(clock.delays.isEmpty)
        lifetime.hold { completed += 1 }
        lifetime.hold { completed += 1 }
        try await clock.waitForSleeps(1)
        clock.advance(.milliseconds(249))
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        #expect(completed == 0 && lifetime.heldTasks == 2)
        clock.advance(.milliseconds(1))
        try await PlayerStoreTests.waitFor { completed == 2 }
        #expect(batches == [2] && lifetime.heldTasks == 0)
        lifetime.finishIfIdle()
        lifetime.hold { completed += 1 }
        try await clock.waitForSleeps(2)
        #expect(clock.delays == [.milliseconds(250), .milliseconds(250)])
        #expect(completed == 2)
        clock.advance(.milliseconds(250))
        try await PlayerStoreTests.waitFor { completed == 3 }
        #expect(batches == [2, 1])
    }

    @Test("new activation, system or local work cancels settling", arguments: [0, 1, 2])
    func interruptedSettling(reason: Int) async throws {
        let clock = Clock()
        defer { clock.releaseAll() }
        let lifetime = clock.lifetime()
        var completed = 0
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        lifetime.hold { completed += 1 }
        try await clock.waitForSleeps(1)
        clock.advance(.milliseconds(100))
        lifetime.update(activated: reason != 0, contentPending: reason == 1, importsPending: reason == 2 ? 1 : 0)
        clock.advance(.milliseconds(200))
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        try await clock.waitForSleeps(2)
        try await PlayerStoreTests.waitFor { clock.returned == 1 }
        // the cancelled timer has also returned, but cannot release the replacement timer's task.
        #expect(completed == 0 && lifetime.heldTasks == 1)
        clock.advance(.milliseconds(249))
        #expect(completed == 0)
        clock.advance(.milliseconds(1))
        try await PlayerStoreTests.waitFor { completed == 1 }
        #expect(clock.delays == [.milliseconds(250), .milliseconds(250)])
    }

    @Test("delayed timer scheduling does not add another settling window")
    func delayedTimerStart() async throws {
        let clock = Clock()
        defer { clock.releaseAll() }
        let lifetime = clock.lifetime()
        var completed = false
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        lifetime.hold { completed = true }
        clock.advance(.seconds(2))
        try await clock.waitForSleeps(1)
        #expect(clock.delays == [.zero])
        clock.advance(.zero)
        try await PlayerStoreTests.waitFor { completed }
    }

    @Test("repeated work and additional holds cannot renew the settling allowance", arguments: [false, true])
    func boundedSettling(callbackOnly: Bool) async throws {
        let clock = Clock()
        defer { clock.releaseAll() }
        let lifetime = clock.lifetime()
        var completed = 0
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        lifetime.hold { completed += 1 }
        try await clock.waitForSleeps(1)
        for count in 2...5 {
            clock.advance(.milliseconds(200))
            if callbackOnly {
                lifetime.activityBegan()
            } else {
                lifetime.update(activated: true, contentPending: false, importsPending: 1)
            }
            lifetime.update(activated: true, contentPending: false, importsPending: 0)
            try await clock.waitForSleeps(count)
        }
        lifetime.hold { completed += 1 }
        #expect(clock.delays == [.milliseconds(250), .milliseconds(250), .milliseconds(250),
                                 .milliseconds(250), .milliseconds(200)])
        clock.advance(.milliseconds(199))
        #expect(completed == 0)
        clock.advance(.milliseconds(1))
        try await PlayerStoreTests.waitFor { completed == 2 }
        #expect(lifetime.heldTasks == 0)
    }

    @Test("the settling cap never forces completion while required work remains")
    func requiredWorkBeyondCap() async throws {
        let clock = Clock()
        defer { clock.releaseAll() }
        let lifetime = clock.lifetime()
        var completed = 0
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        lifetime.hold { completed += 1 }
        try await clock.waitForSleeps(1)
        clock.advance(.milliseconds(100))
        lifetime.update(activated: true, contentPending: false, importsPending: 1)
        clock.advance(.seconds(2))
        #expect(completed == 0 && lifetime.heldTasks == 1)
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        try await clock.waitForSleeps(2)
        #expect(clock.delays == [.milliseconds(250), .zero])
        clock.advance(.zero)
        try await PlayerStoreTests.waitFor { completed == 1 }
    }

    @Test("completion refreshes flags and raw work before releasing the task", arguments: [0, 1, 2])
    func refreshBeforeCompletion(reason: Int) async throws {
        let clock = Clock()
        defer { clock.releaseAll() }
        let lifetime = clock.lifetime()
        var completed = 0
        var pending = true
        var refreshes = 0
        lifetime.refreshState = {
            refreshes += 1
            lifetime.update(activated: !pending || reason != 0, contentPending: pending && reason == 1,
                            importsPending: pending && reason == 2 ? 1 : 0)
        }
        defer { lifetime.refreshState = {} }
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        lifetime.hold { completed += 1 }
        try await clock.waitForSleeps(1)
        clock.advance(.milliseconds(250))
        try await PlayerStoreTests.waitFor { refreshes == 1 }
        #expect(completed == 0 && lifetime.heldTasks == 1)
        pending = false
        lifetime.update(activated: true, contentPending: false, importsPending: 0)
        try await clock.waitForSleeps(2)
        clock.advance(.milliseconds(250))
        try await PlayerStoreTests.waitFor { completed == 1 }
        #expect(refreshes == 2)
    }

    @MainActor
    final class Clock {
        var now = ContinuousClock.now
        var delays = [Duration]()
        private(set) var returned = 0
        private var waits = [(deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Never>)]()

        func lifetime() -> WatchLibraryBackgroundLifetime {
            WatchLibraryBackgroundLifetime(now: { self.now }, sleep: { await self.sleep($0) })
        }

        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { continuation in
                delays.append(duration)
                waits.append((now.advanced(by: duration), continuation))
            }
            returned += 1
        }

        func waitForSleeps(_ count: Int) async throws {
            try await PlayerStoreTests.waitFor { self.delays.count == count }
        }

        func advance(_ duration: Duration) {
            now = now.advanced(by: duration)
            let ready = waits.filter { $0.deadline <= now }
            waits.removeAll { $0.deadline <= now }
            ready.forEach { $0.continuation.resume() }
        }

        func releaseAll() {
            let ready = waits
            waits.removeAll()
            ready.forEach { $0.continuation.resume() }
        }
    }
}
