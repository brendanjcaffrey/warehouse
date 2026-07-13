import Foundation
import Testing

@testable import Warehouse

@MainActor
@Suite("ConnectivityTaskHolder")
struct ConnectivityTaskHolderTests {
    @MainActor
    private final class Harness {
        var isIdle = false
        var completed: [Int] = []
        /// resumed by the test when it wants the deadline to expire
        var deadlineReached: (() -> Void)?

        func holder(deadline: TimeInterval = 10) -> ConnectivityTaskHolder<Int> {
            ConnectivityTaskHolder(
                deadline: deadline,
                isIdle: { self.isIdle },
                complete: { self.completed.append($0) },
                sleep: { _ in
                    await withCheckedContinuation { continuation in
                        self.deadlineReached = { continuation.resume() }
                    }
                })
        }

        /// lets the deadline task run to completion
        func expireDeadline() async {
            while deadlineReached == nil {
                await Task.yield()
            }
            deadlineReached?()
            deadlineReached = nil
            while completed.isEmpty {
                await Task.yield()
            }
        }
    }

    @Test("a task the session has nothing pending for is let go at once")
    func completesWhenAlreadyIdle() {
        let harness = Harness()
        harness.isIdle = true
        let holder = harness.holder()

        holder.hold(1)

        #expect(harness.completed == [1])
        #expect(holder.heldCount == 0)
    }

    @Test("a task is held while the session still has content pending")
    func holdsWhileContentPending() {
        let harness = Harness()
        let holder = harness.holder()

        holder.hold(1)

        #expect(harness.completed.isEmpty)
        #expect(holder.heldCount == 1)
    }

    @Test("every held task is let go once the session drains")
    func completesOnceDrained() {
        let harness = Harness()
        let holder = harness.holder()
        holder.hold(1)
        holder.hold(2)
        #expect(harness.completed.isEmpty)

        harness.isIdle = true
        holder.completeIfIdle()

        #expect(harness.completed == [1, 2])
        #expect(holder.heldCount == 0)
    }

    @Test("a session that never drains is let go on the deadline rather than killing the app")
    func completesOnDeadline() async {
        let harness = Harness()
        let holder = harness.holder()
        holder.hold(1)
        #expect(harness.completed.isEmpty)

        await harness.expireDeadline()

        #expect(harness.completed == [1])
        #expect(holder.heldCount == 0)
    }

    @Test("draining before the deadline lets the task go exactly once")
    func doesNotCompleteTwice() async {
        let harness = Harness()
        let holder = harness.holder()
        holder.hold(1)

        harness.isIdle = true
        holder.completeIfIdle()
        #expect(harness.completed == [1])

        // the deadline task was cancelled by the drain, so letting it run
        // through can't hand the same task back a second time
        harness.deadlineReached?()
        await Task.yield()

        #expect(harness.completed == [1])
    }

    @Test("completeIfIdle with nothing held does nothing")
    func ignoresIdleWithNothingHeld() {
        let harness = Harness()
        harness.isIdle = true
        let holder = harness.holder()

        holder.completeIfIdle()

        #expect(harness.completed.isEmpty)
    }
}
