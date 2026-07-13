import Foundation

/// timings the watch's relay downloader runs on. shared so the sync detail
/// view can count down to the next nudge without duplicating the constant
enum RelayTiming {
    /// how often the watch re-sends its missing list while awaiting a download
    static let nudgeInterval: TimeInterval = 60
    /// give up waiting after this long with no arrival or result at all;
    /// comfortably longer than the background refresh interval, so a quiet
    /// stretch while both apps are suspended isn't mistaken for a dead pipeline
    static let stallTimeout: TimeInterval = 35 * 60
    /// how long until the next background wake that keeps nudging
    static let backgroundRefreshInterval: TimeInterval = 15 * 60
    /// the system kills the watch app if a connectivity background task runs
    /// past 15s of wall clock, so let go comfortably inside that
    static let connectivityTaskDeadline: TimeInterval = 10
}
