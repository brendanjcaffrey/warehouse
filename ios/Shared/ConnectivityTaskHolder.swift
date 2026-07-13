import Foundation

/// holds the watch's connectivity background tasks open while the session
/// still has content to deliver, but never past the system's wall-clock
/// allowance: an unfinished task is a hard kill, and anything still pending
/// just wakes the app again later. generic over the task so it can be tested
/// without watchkit, which the watch target can't be
@MainActor
final class ConnectivityTaskHolder<Held> {
    private var held: [Held] = []
    private var deadlineTask: Task<Void, Never>?

    private let deadline: TimeInterval
    private let isIdle: () -> Bool
    private let complete: (Held) -> Void
    private let sleep: (TimeInterval) async -> Void

    var heldCount: Int { held.count }

    init(
        deadline: TimeInterval = RelayTiming.connectivityTaskDeadline,
        isIdle: @escaping () -> Bool,
        complete: @escaping (Held) -> Void,
        sleep: @escaping (TimeInterval) async -> Void = { _ = try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.deadline = deadline
        self.isIdle = isIdle
        self.complete = complete
        self.sleep = sleep
    }

    /// takes a task the system handed us; it's let go as soon as the session
    /// goes idle, or when the deadline runs out, whichever comes first
    func hold(_ task: Held) {
        held.append(task)
        completeIfIdle()
        startDeadline()
    }

    func completeIfIdle() {
        guard !held.isEmpty, isIdle() else { return }
        completeAll()
    }

    private func startDeadline() {
        guard !held.isEmpty, deadlineTask == nil else { return }
        let deadline = deadline
        let sleep = sleep
        deadlineTask = Task { [weak self] in
            await sleep(deadline)
            guard !Task.isCancelled else { return }
            // the transfers keep going without us: the system's queue owns
            // them, and it wakes us again when the next one lands
            self?.completeAll()
        }
    }

    private func completeAll() {
        deadlineTask?.cancel()
        deadlineTask = nil
        let tasks = held
        held.removeAll()
        for task in tasks {
            complete(task)
        }
    }
}
