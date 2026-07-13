import WatchKit

/// handles the background url session refresh tasks watchos hands back when it
/// relaunches the app to advance downloads that completed while it was suspended
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let urlTask = task as? WKURLSessionRefreshBackgroundTask {
                WatchBundleDownloader.shared.reconnect(sessionIdentifier: urlTask.sessionIdentifier) {
                    urlTask.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
