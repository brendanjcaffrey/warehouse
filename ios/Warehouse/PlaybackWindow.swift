import Foundation

/// the playable slice of a track within its file; start & finish come from
/// itunes' custom start/stop times and are zero when unset
struct PlaybackWindow: Equatable, Sendable {
    let start: TimeInterval
    let end: TimeInterval
    let duration: TimeInterval

    init(duration: TimeInterval = 0, start: TimeInterval = 0, finish: TimeInterval = 0) {
        var end = finish > 0 ? finish : duration
        if duration > 0 {
            end = min(end, duration)
        }
        self.start = max(0, start)
        // degenerate data can't make a negative window or one past the file
        self.end = max(self.start, end)
        self.duration = max(duration, self.end)
    }

    /// whether the track starts after the beginning of the file
    var startsLate: Bool { start > 1.0 }

    /// whether the track normally stops before the end of the file
    var stopsEarly: Bool { end < (duration-1.0) }

    /// progress through the file as 0-1 for the scrubber
    func fraction(atTime time: TimeInterval) -> Double {
        guard duration > 0 else { return 0 }
        return min(max(0, time / duration), 1)
    }

    /// a 0-1 scrubber position back to a time in the file
    func time(atFraction fraction: Double) -> TimeInterval {
        duration * min(max(0, fraction), 1)
    }
}

/// m:ss labels for the progress bar
enum PlaybackTime {
    static func label(_ time: TimeInterval) -> String {
        let total = max(0, Int(time.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
