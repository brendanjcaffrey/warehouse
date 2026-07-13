import WatchKit

/// handles the background tasks watchos hands back while relayed downloads
/// are in flight: connectivity tasks deliver the files & messages that
/// arrived while the app was suspended, and periodic app refreshes keep
/// nudging the phone while files are still missing
@MainActor
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// wired up by the app at launch, since the adaptor owns this instance
    static var onConnectivityTask: ((WKWatchConnectivityRefreshBackgroundTask) -> Void)?
    static var onAppRefresh: ((@escaping @MainActor () -> Void) -> Void)?

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask,
               let handler = Self.onConnectivityTask {
                handler(connectivityTask)
            } else if task is WKApplicationRefreshBackgroundTask, let handler = Self.onAppRefresh {
                handler {
                    task.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
