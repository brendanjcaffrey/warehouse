import Foundation
import Testing
@testable import Warehouse

@Suite("PlaybackWindow")
struct PlaybackWindowTests {
    @Test("zero start & finish play the whole file")
    func wholeTrack() {
        let window = PlaybackWindow(duration: 200)
        #expect(window.start == 0)
        #expect(window.end == 200)
        #expect(window.duration == 200)
        #expect(!window.startsLate)
        #expect(!window.stopsEarly)
    }

    @Test("custom start & stop times trim the window inside the file")
    func customTimes() {
        let window = PlaybackWindow(duration: 200, start: 10, finish: 190)
        #expect(window.start == 10)
        #expect(window.end == 190)
        #expect(window.duration == 200)
        #expect(window.startsLate)
        #expect(window.stopsEarly)
    }

    @Test("a zero finish means play to the end")
    func zeroFinish() {
        let window = PlaybackWindow(duration: 200, start: 30)
        #expect(window.end == 200)
        #expect(!window.stopsEarly)
    }

    @Test("a finish past the duration clamps to the duration")
    func finishPastDuration() {
        let window = PlaybackWindow(duration: 200, start: 0, finish: 250)
        #expect(window.end == 200)
        #expect(window.duration == 200)
        #expect(!window.stopsEarly)
    }

    @Test("degenerate data can't produce a negative window")
    func degenerateData() {
        let window = PlaybackWindow(duration: 200, start: 50, finish: 20)
        #expect(window.start == 50)
        #expect(window.end == 50)
        #expect(window.duration == 200)

        let negative = PlaybackWindow(duration: 100, start: -5)
        #expect(negative.start == 0)

        let noDuration = PlaybackWindow(duration: 0, start: 0, finish: 100)
        #expect(noDuration.end == 100)
        #expect(noDuration.duration == 100)
    }

    @Test("fractions convert between scrubber positions & file times")
    func fractions() {
        let window = PlaybackWindow(duration: 200, start: 10, finish: 190)
        #expect(window.fraction(atTime: 0) == 0)
        #expect(window.fraction(atTime: 50) == 0.25)
        #expect(window.fraction(atTime: 999) == 1)
        #expect(window.time(atFraction: 0.5) == 100)
        #expect(window.time(atFraction: -1) == 0)
        #expect(window.time(atFraction: 2) == 200)

        let empty = PlaybackWindow()
        #expect(empty.fraction(atTime: 10) == 0)
    }

    @Test("time labels format as minutes & zero padded seconds")
    func timeLabels() {
        #expect(PlaybackTime.label(0) == "0:00")
        #expect(PlaybackTime.label(7) == "0:07")
        #expect(PlaybackTime.label(59.6) == "1:00")
        #expect(PlaybackTime.label(187) == "3:07")
        #expect(PlaybackTime.label(3600) == "60:00")
        #expect(PlaybackTime.label(-3) == "0:00")
    }
}
